#!/usr/bin/env python3
"""
Import Godot .tscn scene files and convert to GameGen format for DynamoDB.

Usage:
    python import_godot_scene.py <scene_path> --project-id <id> [--project-name <name>]
    python import_godot_scene.py <directory> --project-id <id> --recursive
"""

import json
import re
import sys
import argparse
import urllib.request
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Any, Optional


class TscnParser:
    """Parse Godot .tscn scene files"""

    # 2D node types
    NODE_2D_TYPES = {
        'Node2D', 'Sprite2D', 'AnimatedSprite2D'
    }

    CONTAINER_TYPES = {
        'VBoxContainer', 'HBoxContainer', 'GridContainer',
        'HFlowContainer', 'VFlowContainer', 'FlowContainer',
        'TabContainer', 'PanelContainer', 'MarginContainer',
        'CenterContainer', 'AspectRatioContainer',
        'HSplitContainer', 'VSplitContainer', 'SplitContainer',
        'SubViewportContainer', 'ScrollContainer',
        'Panel', 'Control'
    }

    PARENT_TYPES = {
        'Node2D', 'Node', 'CanvasLayer', 'Control'
    }

    WIDGET_TYPES = {
        'Button', 'Label', 'LineEdit', 'TextEdit',
        'CheckBox', 'CheckButton', 'OptionButton',
        'SpinBox', 'HSlider', 'VSlider',
        'ProgressBar', 'ColorRect', 'TextureRect',
        'ColorPickerButton', 'RichTextLabel',
        'ItemList', 'Tree', 'GraphEdit'
    }

    ANIMATION_TYPES = {
        'AnimationPlayer'
    }

    def __init__(self, file_path: str):
        self.file_path = Path(file_path)
        self.nodes: Dict[str, Dict[str, Any]] = {}
        self.root_node: Optional[str] = None
        self.id_counter = 0
        self.ext_resources: Dict[str, str] = {}  # id -> path mapping

    def parse(self) -> Dict[str, Any]:
        """Parse the .tscn file and return hierarchical scene structure"""
        if not self.file_path.exists():
            raise FileNotFoundError(f"Scene file not found: {self.file_path}")

        with open(self.file_path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Split into sections
        sections = re.split(r'\n(?=\[)', content)

        for section in sections:
            section = section.strip()
            if not section:
                continue

            # Parse ext_resource declarations (textures, scripts, etc.)
            # Format can be: [ext_resource type="..." path="..." id="..."]
            # or: [ext_resource type="..." uid="..." path="..." id="..."]
            ext_match = re.match(r'\[ext_resource type="([^"]+)"(?:\s+uid="[^"]+")?\s+path="([^"]+)"\s+id="([^"]+)"\]', section)
            if ext_match:
                res_type = ext_match.group(1)
                res_path = ext_match.group(2)
                res_id = ext_match.group(3)
                self.ext_resources[res_id] = res_path
                continue

            # Parse node declarations
            node_match = re.match(r'\[node name="([^"]+)" type="([^"]+)"(.*?)\]', section, re.DOTALL)
            if node_match:
                name = node_match.group(1)
                node_type = node_match.group(2)
                attributes = node_match.group(3)

                # Extract parent
                parent_match = re.search(r'parent="([^"]*)"', attributes)
                parent = parent_match.group(1) if parent_match else None

                # Parse properties
                props = self._parse_properties(section)

                self.nodes[name] = {
                    'node_name': name,
                    'node_type': node_type,
                    'parent': parent,
                    'properties': props,
                    'children': [],
                    'is_container': node_type in self.CONTAINER_TYPES,
                    'is_widget': node_type in self.WIDGET_TYPES,
                    'is_2d_node': node_type in self.NODE_2D_TYPES,
                    'is_animation': node_type in self.ANIMATION_TYPES
                }

                # Track root node
                if parent is None or parent == '.':
                    self.root_node = name

        return self._build_scene_tree()

    def _parse_properties(self, section: str) -> Dict[str, Any]:
        """Extract properties from a section"""
        properties = {}
        lines = section.split('\n')[1:]

        for line in lines:
            line = line.strip()
            if not line or line.startswith('['):
                continue
            if '=' in line:
                key, value = line.split('=', 1)
                key = key.strip()
                value = value.strip()
                properties[key] = self._parse_value(value)

        return properties

    def _parse_value(self, value: str) -> Any:
        """Parse a property value to appropriate Python type"""
        value = value.strip()

        if value.lower() == 'true':
            return True
        elif value.lower() == 'false':
            return False
        elif value.startswith('"') and value.endswith('"'):
            return value[1:-1]
        elif value.startswith('ExtResource('):
            # Resolve external resource reference to actual path
            match = re.match(r'ExtResource\(\s*"([^"]+)"\s*\)', value)
            if match:
                res_id = match.group(1)
                return self.ext_resources.get(res_id, f"unresolved:{res_id}")
            return value
        elif value.startswith('Vector2('):
            match = re.match(r'Vector2\(\s*([^,]+)\s*,\s*([^)]+)\s*\)', value)
            if match:
                return {'x': float(match.group(1)), 'y': float(match.group(2))}
        elif value.startswith('Color('):
            match = re.match(r'Color\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*([^,]+)\s*,?\s*([^)]*)\s*\)', value)
            if match:
                r, g, b = float(match.group(1)), float(match.group(2)), float(match.group(3))
                a = float(match.group(4)) if match.group(4) else 1.0
                return f"#{int(r*255):02x}{int(g*255):02x}{int(b*255):02x}"
        else:
            try:
                return float(value) if '.' in value else int(value)
            except ValueError:
                return value

        return value

    def _build_scene_tree(self) -> Dict[str, Any]:
        """Build hierarchical scene tree structure"""
        if not self.root_node:
            return {}

        # Build parent-child relationships
        for name, node in self.nodes.items():
            if name == self.root_node:
                continue
            parent_path = node['parent']
            if parent_path:
                if parent_path == '.':
                    if self.root_node and self.root_node in self.nodes:
                        self.nodes[self.root_node]['children'].append(name)
                else:
                    parent_name = parent_path.split('/')[-1] if '/' in parent_path else parent_path
                    if parent_name in self.nodes and parent_name != name:
                        self.nodes[parent_name]['children'].append(name)

        # Build the scene tree starting from root
        self.id_counter = 0
        return self._convert_node_to_tree(self.root_node)

    def _convert_node_to_tree(self, node_name: str) -> Dict[str, Any]:
        """Convert a node and its children to scene tree format"""
        node = self.nodes[node_name]
        self.id_counter += 1

        # Determine node category
        node_type = node['node_type']
        if node['is_2d_node']:
            mapped_type = node_type
        elif node['is_animation']:
            mapped_type = node_type
        elif node['is_container']:
            mapped_type = self._map_container_type(node_type)
        elif node['is_widget']:
            mapped_type = node_type
        else:
            # Default to Node2D for unknown parent types
            mapped_type = 'Node2D' if node_type in self.PARENT_TYPES else node_type

        tree_node = {
            'id': self.id_counter,
            'type': mapped_type,
            'name': node['node_name'],
            'children': [],
            'widgets': [],
            'properties': self._extract_properties(node)
        }

        # Process children
        for child_name in node['children']:
            if child_name not in self.nodes:
                continue
            child_node = self.nodes[child_name]

            if child_node['is_widget'] and not child_node['is_container']:
                # Add as widget with ID
                self.id_counter += 1
                widget = {
                    'id': self.id_counter,
                    'type': child_node['node_type'],
                    'name': child_node['node_name'],
                    'properties': self._extract_widget_properties(child_node)
                }
                tree_node['widgets'].append(widget)
            else:
                # Recursively add as child node
                child_tree = self._convert_node_to_tree(child_name)
                tree_node['children'].append(child_tree)

        return tree_node

    def _map_container_type(self, godot_type: str) -> str:
        """Map Godot container type to GameGen type"""
        type_map = {
            'HFlowContainer': 'FlowContainer',
            'VFlowContainer': 'FlowContainer',
            'Control': 'PanelContainer',
            'Panel': 'PanelContainer',
        }
        return type_map.get(godot_type, godot_type)

    def _extract_properties(self, node: Dict) -> Dict[str, Any]:
        """Extract properties for a node"""
        props = node['properties']
        result = {}

        # Position
        if 'position' in props and isinstance(props['position'], dict):
            result['positionX'] = props['position'].get('x', 0)
            result['positionY'] = props['position'].get('y', 0)
        else:
            result['positionX'] = props.get('offset_left', 0)
            result['positionY'] = props.get('offset_top', 0)

        # Size
        if 'size' in props and isinstance(props['size'], dict):
            result['sizeX'] = props['size'].get('x', 200)
            result['sizeY'] = props['size'].get('y', 150)
        elif 'offset_right' in props and 'offset_left' in props:
            result['sizeX'] = props['offset_right'] - props.get('offset_left', 0)
            result['sizeY'] = props.get('offset_bottom', 150) - props.get('offset_top', 0)

        # Layout properties
        if node['node_type'] == 'GridContainer' and 'columns' in props:
            result['columns'] = props['columns']
        if 'alignment' in props:
            result['alignment'] = props['alignment']

        # Texture for Sprite2D
        if node['is_2d_node'] and 'texture' in props:
            result['texture'] = props['texture']

        return result

    def _extract_widget_properties(self, node: Dict) -> Dict[str, Any]:
        """Extract properties for a widget"""
        props = node['properties']
        result = {}

        # Common properties
        if 'text' in props:
            result['text'] = props['text']
        if 'placeholder_text' in props:
            result['placeholder_text'] = props['placeholder_text']
        if 'value' in props:
            result['value'] = props['value']
        if 'min_value' in props:
            result['min_value'] = props['min_value']
        if 'max_value' in props:
            result['max_value'] = props['max_value']
        if 'step' in props:
            result['step'] = props['step']
        if 'color' in props:
            result['color'] = props['color']
        if 'button_pressed' in props:
            result['button_pressed'] = props['button_pressed']

        # Size properties
        if 'custom_minimum_size' in props and isinstance(props['custom_minimum_size'], dict):
            result['minSizeX'] = props['custom_minimum_size'].get('x', 0)
            result['minSizeY'] = props['custom_minimum_size'].get('y', 0)

        return result


class DynamoDBUploader:
    """Upload to DynamoDB via HTTP endpoint using native Map types"""

    def __init__(self, endpoint: str = "http://zycroft.duckdns.org:8001"):
        self.endpoint = endpoint

    def _to_dynamodb_attr(self, value: Any) -> Dict[str, Any]:
        """Convert Python value to DynamoDB attribute format"""
        if value is None:
            return {"NULL": True}
        elif isinstance(value, bool):
            return {"BOOL": value}
        elif isinstance(value, (int, float)):
            return {"N": str(value)}
        elif isinstance(value, str):
            return {"S": value}
        elif isinstance(value, list):
            return {"L": [self._to_dynamodb_attr(item) for item in value]}
        elif isinstance(value, dict):
            return {"M": {str(k): self._to_dynamodb_attr(v) for k, v in value.items()}}
        else:
            return {"S": str(value)}

    def upload(self, project_id: int, project_name: str, scene_root: Dict) -> bool:
        """Upload scene layout to DynamoDB using Map type"""

        # Build DynamoDB item with native types
        item = {
            "projectID": {"N": str(project_id)},
            "projectName": {"S": project_name},
            "sceneRoot": self._to_dynamodb_attr(scene_root),
            "savedAt": {"S": datetime.now().isoformat()}
        }

        body = json.dumps({
            "TableName": "SceneLayout",
            "Item": item
        }).encode('utf-8')

        headers = {
            "Content-Type": "application/x-amz-json-1.0",
            "X-Amz-Target": "DynamoDB_20120810.PutItem",
            "Authorization": "AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
            "X-Amz-Date": "20250101T000000Z"
        }

        try:
            req = urllib.request.Request(self.endpoint, data=body, headers=headers, method='POST')
            with urllib.request.urlopen(req) as response:
                if response.status == 200:
                    print(f"Successfully uploaded to DynamoDB SceneLayout (project ID: {project_id})")
                    return True
                else:
                    print(f"Upload failed with status: {response.status}")
                    return False
        except Exception as e:
            print(f"Error uploading to DynamoDB: {e}")
            return False


def find_tscn_files(directory: str, recursive: bool = False) -> List[Path]:
    """Find all .tscn files in a directory"""
    path = Path(directory)
    if recursive:
        return list(path.rglob("*.tscn"))
    return list(path.glob("*.tscn"))


def merge_scene_trees(trees: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Merge multiple scene trees under a common root"""
    if len(trees) == 1:
        return trees[0]

    # Create a root node containing all trees
    root = {
        'id': 1,
        'type': 'Node2D',
        'name': 'Root',
        'children': [],
        'widgets': [],
        'properties': {}
    }

    # Re-number IDs and add trees as children
    next_id = 2
    for tree in trees:
        tree, next_id = _renumber_ids(tree, next_id)
        root['children'].append(tree)

    return root


def _renumber_ids(node: Dict[str, Any], start_id: int) -> tuple:
    """Renumber node IDs starting from start_id"""
    node['id'] = start_id
    next_id = start_id + 1

    for widget in node.get('widgets', []):
        widget['id'] = next_id
        next_id += 1

    for child in node.get('children', []):
        child, next_id = _renumber_ids(child, next_id)

    return node, next_id


def main():
    parser = argparse.ArgumentParser(description="Import Godot scenes to GameGen DynamoDB")
    parser.add_argument("path", help="Path to .tscn file or directory")
    parser.add_argument("--project-id", type=int, required=True, help="Project ID for DynamoDB")
    parser.add_argument("--project-name", default="Imported Project", help="Project name")
    parser.add_argument("--recursive", action="store_true", help="Search directories recursively")
    parser.add_argument("--dry-run", action="store_true", help="Parse only, don't upload")
    parser.add_argument("--output", help="Output JSON to file instead of uploading")

    args = parser.parse_args()

    path = Path(args.path)

    # Find files to process
    if path.is_file():
        files = [path]
    elif path.is_dir():
        files = find_tscn_files(path, args.recursive)
        if not files:
            print(f"No .tscn files found in {path}")
            sys.exit(1)
        print(f"Found {len(files)} .tscn file(s)")
    else:
        print(f"Path not found: {path}")
        sys.exit(1)

    # Parse all files into scene trees
    scene_trees = []
    for file_path in files:
        print(f"Parsing: {file_path}")
        try:
            parser_obj = TscnParser(str(file_path))
            scene_tree = parser_obj.parse()
            if scene_tree:
                scene_trees.append(scene_tree)
                print(f"  Parsed scene: {scene_tree.get('name', 'Unknown')}")
        except Exception as e:
            print(f"  Error parsing {file_path}: {e}")

    if not scene_trees:
        print("No scenes found in any files")
        sys.exit(1)

    # Merge trees if multiple files
    scene_root = merge_scene_trees(scene_trees)

    print(f"\nScene tree built with root: {scene_root.get('name', 'Root')}")

    # Output or upload
    if args.output:
        output_data = {
            "projectID": args.project_id,
            "projectName": args.project_name,
            "sceneRoot": scene_root,
            "savedAt": datetime.now().isoformat()
        }
        with open(args.output, 'w') as f:
            json.dump(output_data, f, indent=2)
        print(f"Output written to: {args.output}")
    elif args.dry_run:
        print("\nDry run - scene tree:")
        print(json.dumps(scene_root, indent=2))
    else:
        uploader = DynamoDBUploader()
        if uploader.upload(args.project_id, args.project_name, scene_root):
            print("Import complete!")
        else:
            sys.exit(1)


if __name__ == '__main__':
    main()
