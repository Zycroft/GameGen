#!/usr/bin/env python3
"""
Import Godot projects and convert to GameGen format for DynamoDB.

Scans entire Godot projects including:
- All .tscn scene files
- Associated .gd script files for programmatic position/size detection

Usage:
    python import_godot_scene.py <project_path> --project-id <id> [--project-name <name>]
    python import_godot_scene.py <scene.tscn> --project-id <id>  # Single scene
"""

import json
import re
import sys
import argparse
import urllib.request
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Any, Optional, Set, Tuple


class GDScriptAnalyzer:
    """Analyze GDScript files for programmatic position/size assignments"""

    # Patterns for detecting position/size assignments
    POSITION_PATTERNS = [
        # Direct position assignments
        r'\.position\s*=\s*Vector2\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)',
        r'\.global_position\s*=\s*Vector2\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)',
        r'position\s*=\s*Vector2\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)',
        r'global_position\s*=\s*Vector2\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)',
        # Offset assignments (Control nodes)
        r'\.offset_left\s*=\s*([^#\n]+)',
        r'\.offset_top\s*=\s*([^#\n]+)',
        r'offset_left\s*=\s*([^#\n]+)',
        r'offset_top\s*=\s*([^#\n]+)',
    ]

    SIZE_PATTERNS = [
        # Direct size assignments
        r'\.size\s*=\s*Vector2\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)',
        r'\.size\s*=\s*Vector2i\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)',
        r'size\s*=\s*Vector2\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)',
        r'size\s*=\s*Vector2i\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)',
        # Custom minimum size
        r'\.custom_minimum_size\s*=\s*Vector2\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)',
        r'custom_minimum_size\s*=\s*Vector2\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)',
        # Offset-based size
        r'\.offset_right\s*=\s*([^#\n]+)',
        r'\.offset_bottom\s*=\s*([^#\n]+)',
        r'offset_right\s*=\s*([^#\n]+)',
        r'offset_bottom\s*=\s*([^#\n]+)',
    ]

    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.script_cache: Dict[str, str] = {}  # path -> content
        self.node_assignments: Dict[str, Dict[str, Any]] = {}  # node_path -> assignments

    def analyze_script(self, script_path: str) -> Dict[str, Any]:
        """Analyze a GDScript file for programmatic assignments"""
        # Resolve path relative to project
        if script_path.startswith("res://"):
            script_path = script_path[6:]  # Remove res://

        full_path = self.project_root / script_path
        if not full_path.exists():
            return {}

        # Cache script content
        if str(full_path) not in self.script_cache:
            try:
                with open(full_path, 'r', encoding='utf-8') as f:
                    self.script_cache[str(full_path)] = f.read()
            except Exception:
                return {}

        content = self.script_cache[str(full_path)]
        return self._extract_assignments(content, script_path)

    def _extract_assignments(self, content: str, script_path: str) -> Dict[str, Any]:
        """Extract position/size assignments from script content"""
        result = {
            'has_position_code': False,
            'has_size_code': False,
            'position_approximation': None,
            'size_approximation': None,
            'node_assignments': {}  # node_name -> {position, size}
        }

        # Check for position patterns
        for pattern in self.POSITION_PATTERNS:
            matches = re.findall(pattern, content)
            if matches:
                result['has_position_code'] = True
                # Try to extract numeric values
                for match in matches:
                    pos = self._try_parse_vector(match)
                    if pos and result['position_approximation'] is None:
                        result['position_approximation'] = pos

        # Check for size patterns
        for pattern in self.SIZE_PATTERNS:
            matches = re.findall(pattern, content)
            if matches:
                result['has_size_code'] = True
                # Try to extract numeric values
                for match in matches:
                    size = self._try_parse_vector(match)
                    if size and result['size_approximation'] is None:
                        result['size_approximation'] = size

        # Find node-specific assignments (e.g., $NodeName.position = ...)
        result['node_assignments'] = self._find_node_assignments(content)

        return result

    def _try_parse_vector(self, match) -> Optional[Dict[str, float]]:
        """Try to parse a Vector2 match into x, y values"""
        try:
            if isinstance(match, tuple) and len(match) >= 2:
                x_str, y_str = match[0].strip(), match[1].strip()
                # Try to evaluate simple numeric expressions
                x = self._eval_numeric(x_str)
                y = self._eval_numeric(y_str)
                if x is not None and y is not None:
                    return {'x': x, 'y': y}
            elif isinstance(match, str):
                # Single value (offset)
                val = self._eval_numeric(match.strip())
                if val is not None:
                    return {'value': val}
        except Exception:
            pass
        return None

    def _eval_numeric(self, expr: str) -> Optional[float]:
        """Safely evaluate a numeric expression"""
        expr = expr.strip()
        # Direct number
        try:
            return float(expr)
        except ValueError:
            pass

        # Simple arithmetic (e.g., "100 + 30")
        try:
            # Only allow digits, operators, spaces, and decimal points
            if re.match(r'^[\d\s\+\-\*\/\.\(\)]+$', expr):
                return float(eval(expr))
        except Exception:
            pass

        return None

    def _find_node_assignments(self, content: str) -> Dict[str, Dict[str, Any]]:
        """Find assignments to specific nodes like $NodeName.position"""
        assignments = {}

        # Pattern: $NodeName.position = Vector2(x, y)
        node_pos_pattern = r'\$(\w+)\.(?:global_)?position\s*=\s*Vector2\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)'
        for match in re.finditer(node_pos_pattern, content):
            node_name = match.group(1)
            pos = self._try_parse_vector((match.group(2), match.group(3)))
            if node_name not in assignments:
                assignments[node_name] = {}
            assignments[node_name]['position'] = pos
            assignments[node_name]['position_programmatic'] = True

        # Pattern: $NodeName.size = Vector2(x, y)
        node_size_pattern = r'\$(\w+)\.size\s*=\s*Vector2i?\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)'
        for match in re.finditer(node_size_pattern, content):
            node_name = match.group(1)
            size = self._try_parse_vector((match.group(2), match.group(3)))
            if node_name not in assignments:
                assignments[node_name] = {}
            assignments[node_name]['size'] = size
            assignments[node_name]['size_programmatic'] = True

        return assignments


class TscnParser:
    """Parse Godot .tscn scene files"""

    # 2D node types
    NODE_2D_TYPES = {
        'Node2D', 'Sprite2D', 'AnimatedSprite2D', 'CharacterBody2D',
        'RigidBody2D', 'StaticBody2D', 'Area2D', 'Camera2D',
        'TileMap', 'TileMapLayer', 'Polygon2D', 'Line2D'
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
        'Node2D', 'Node', 'CanvasLayer', 'Control', 'Node3D'
    }

    WIDGET_TYPES = {
        'Button', 'Label', 'LineEdit', 'TextEdit',
        'CheckBox', 'CheckButton', 'OptionButton',
        'SpinBox', 'HSlider', 'VSlider',
        'ProgressBar', 'ColorRect', 'TextureRect',
        'ColorPickerButton', 'RichTextLabel',
        'ItemList', 'Tree', 'GraphEdit', 'MenuButton',
        'LinkButton', 'TextureButton'
    }

    ANIMATION_TYPES = {
        'AnimationPlayer', 'AnimationTree'
    }

    def __init__(self, file_path: str, project_root: Path = None):
        self.file_path = Path(file_path)
        self.project_root = project_root or self.file_path.parent
        self.nodes: Dict[str, Dict[str, Any]] = {}
        self.root_node: Optional[str] = None
        self.id_counter = 0
        self.ext_resources: Dict[str, Dict[str, str]] = {}  # id -> {type, path}
        self.script_path: Optional[str] = None
        self.gdscript_analyzer: Optional[GDScriptAnalyzer] = None

    def set_gdscript_analyzer(self, analyzer: GDScriptAnalyzer):
        """Set the GDScript analyzer for programmatic detection"""
        self.gdscript_analyzer = analyzer

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

            # Parse ext_resource declarations
            ext_match = re.match(
                r'\[ext_resource type="([^"]+)"(?:\s+uid="[^"]+")?\s+path="([^"]+)"\s+id="([^"]+)"\]',
                section
            )
            if ext_match:
                res_type = ext_match.group(1)
                res_path = ext_match.group(2)
                res_id = ext_match.group(3)
                self.ext_resources[res_id] = {'type': res_type, 'path': res_path}
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

                # Check for script reference
                script_ref = None
                if 'script' in props:
                    script_ref = props.get('script')
                    if parent is None:  # Root node's script
                        self.script_path = script_ref

                self.nodes[name] = {
                    'node_name': name,
                    'node_type': node_type,
                    'parent': parent,
                    'properties': props,
                    'children': [],
                    'is_container': node_type in self.CONTAINER_TYPES,
                    'is_widget': node_type in self.WIDGET_TYPES,
                    'is_2d_node': node_type in self.NODE_2D_TYPES,
                    'is_animation': node_type in self.ANIMATION_TYPES,
                    'script': script_ref
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
            # Resolve external resource reference
            match = re.match(r'ExtResource\(\s*"([^"]+)"\s*\)', value)
            if match:
                res_id = match.group(1)
                res_info = self.ext_resources.get(res_id, {})
                return res_info.get('path', f"unresolved:{res_id}")
            return value
        elif value.startswith('Vector2('):
            match = re.match(r'Vector2\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)', value)
            if match:
                return {'x': float(match.group(1)), 'y': float(match.group(2))}
        elif value.startswith('Vector2i('):
            match = re.match(r'Vector2i\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)', value)
            if match:
                return {'x': int(match.group(1)), 'y': int(match.group(2))}
        elif value.startswith('Color('):
            match = re.match(r'Color\s*\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*([^,]+)\s*,?\s*([^)]*)\s*\)', value)
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

        # Analyze associated script if available
        script_analysis = {}
        if self.script_path and self.gdscript_analyzer:
            script_analysis = self.gdscript_analyzer.analyze_script(self.script_path)

        # Build the scene tree starting from root
        self.id_counter = 0
        return self._convert_node_to_tree(self.root_node, script_analysis)

    def _convert_node_to_tree(self, node_name: str, script_analysis: Dict = None) -> Dict[str, Any]:
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
            mapped_type = 'Node2D' if node_type in self.PARENT_TYPES else node_type

        # Extract properties with programmatic detection
        props, programmatic_flags = self._extract_properties_with_flags(
            node, node_name, script_analysis or {}
        )

        tree_node = {
            'id': self.id_counter,
            'type': mapped_type,
            'name': node['node_name'],
            'children': [],
            'widgets': [],
            'properties': props,
            **programmatic_flags
        }

        # Add script reference if present
        if node.get('script'):
            tree_node['script'] = node['script']

        # Process children
        for child_name in node['children']:
            if child_name not in self.nodes:
                continue
            child_node = self.nodes[child_name]

            if child_node['is_widget'] and not child_node['is_container']:
                # Add as widget with ID
                self.id_counter += 1
                widget_props, widget_flags = self._extract_widget_properties_with_flags(
                    child_node, child_name, script_analysis or {}
                )
                widget = {
                    'id': self.id_counter,
                    'type': child_node['node_type'],
                    'name': child_node['node_name'],
                    'properties': widget_props,
                    **widget_flags
                }
                tree_node['widgets'].append(widget)
            else:
                # Recursively add as child node
                child_tree = self._convert_node_to_tree(child_name, script_analysis)
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

    def _extract_properties_with_flags(
        self, node: Dict, node_name: str, script_analysis: Dict
    ) -> Tuple[Dict[str, Any], Dict[str, bool]]:
        """Extract properties and determine programmatic flags"""
        props = node['properties']
        result = {}
        flags = {
            'positionProgrammatic': False,
            'sizeProgrammatic': False
        }

        # Check if this node has programmatic assignments
        node_assignments = script_analysis.get('node_assignments', {})
        node_specific = node_assignments.get(node_name, {})

        # Position
        if 'position' in props and isinstance(props['position'], dict):
            result['positionX'] = props['position'].get('x', 0)
            result['positionY'] = props['position'].get('y', 0)
        else:
            result['positionX'] = props.get('offset_left', 0)
            result['positionY'] = props.get('offset_top', 0)

        # Check for programmatic position
        if node_specific.get('position_programmatic'):
            flags['positionProgrammatic'] = True
            if node_specific.get('position'):
                result['positionX'] = node_specific['position'].get('x', result['positionX'])
                result['positionY'] = node_specific['position'].get('y', result['positionY'])
        elif script_analysis.get('has_position_code') and node_name == self.root_node:
            # Root node with position code in its script
            flags['positionProgrammatic'] = True
            if script_analysis.get('position_approximation'):
                approx = script_analysis['position_approximation']
                if 'x' in approx:
                    result['positionX'] = approx['x']
                    result['positionY'] = approx['y']

        # Size
        if 'size' in props and isinstance(props['size'], dict):
            result['sizeX'] = props['size'].get('x', 200)
            result['sizeY'] = props['size'].get('y', 150)
        elif 'offset_right' in props and 'offset_left' in props:
            result['sizeX'] = props['offset_right'] - props.get('offset_left', 0)
            result['sizeY'] = props.get('offset_bottom', 150) - props.get('offset_top', 0)

        # Check for programmatic size
        if node_specific.get('size_programmatic'):
            flags['sizeProgrammatic'] = True
            if node_specific.get('size'):
                result['sizeX'] = node_specific['size'].get('x', result.get('sizeX', 200))
                result['sizeY'] = node_specific['size'].get('y', result.get('sizeY', 150))
        elif script_analysis.get('has_size_code') and node_name == self.root_node:
            flags['sizeProgrammatic'] = True
            if script_analysis.get('size_approximation'):
                approx = script_analysis['size_approximation']
                if 'x' in approx:
                    result['sizeX'] = approx['x']
                    result['sizeY'] = approx['y']

        # Layout properties
        if node['node_type'] == 'GridContainer' and 'columns' in props:
            result['columns'] = props['columns']
        if 'alignment' in props:
            result['alignment'] = props['alignment']

        # Texture for Sprite2D
        if node['is_2d_node'] and 'texture' in props:
            result['texture'] = props['texture']

        return result, flags

    def _extract_widget_properties_with_flags(
        self, node: Dict, node_name: str, script_analysis: Dict
    ) -> Tuple[Dict[str, Any], Dict[str, bool]]:
        """Extract widget properties with programmatic flags"""
        props = node['properties']
        result = {}
        flags = {
            'positionProgrammatic': False,
            'sizeProgrammatic': False
        }

        # Check node-specific assignments
        node_assignments = script_analysis.get('node_assignments', {})
        node_specific = node_assignments.get(node_name, {})

        if node_specific.get('position_programmatic'):
            flags['positionProgrammatic'] = True
        if node_specific.get('size_programmatic'):
            flags['sizeProgrammatic'] = True

        # Position properties
        if 'position' in props and isinstance(props['position'], dict):
            result['positionX'] = props['position'].get('x', 0)
            result['positionY'] = props['position'].get('y', 0)
        elif 'offset_left' in props or 'offset_top' in props:
            result['positionX'] = props.get('offset_left', 0)
            result['positionY'] = props.get('offset_top', 0)

        # Size properties
        if 'size' in props and isinstance(props['size'], dict):
            result['sizeX'] = props['size'].get('x', 0)
            result['sizeY'] = props['size'].get('y', 0)
        elif 'offset_right' in props and 'offset_left' in props:
            result['sizeX'] = props['offset_right'] - props.get('offset_left', 0)
            result['sizeY'] = props.get('offset_bottom', 0) - props.get('offset_top', 0)

        if 'custom_minimum_size' in props and isinstance(props['custom_minimum_size'], dict):
            result['minSizeX'] = props['custom_minimum_size'].get('x', 0)
            result['minSizeY'] = props['custom_minimum_size'].get('y', 0)

        # Texture for TextureRect, Sprite2D
        if 'texture' in props:
            result['texture'] = props['texture']

        # Common text/value properties
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

        # Sprite properties
        if 'hframes' in props:
            result['hframes'] = props['hframes']
        if 'vframes' in props:
            result['vframes'] = props['vframes']
        if 'frame' in props:
            result['frame'] = props['frame']

        # Scale
        if 'scale' in props and isinstance(props['scale'], dict):
            result['scaleX'] = props['scale'].get('x', 1)
            result['scaleY'] = props['scale'].get('y', 1)

        return result, flags


class GodotProjectScanner:
    """Scan entire Godot projects for scenes and scripts"""

    def __init__(self, project_path: str):
        self.project_path = Path(project_path)
        self.scenes: List[Path] = []
        self.scripts: List[Path] = []
        self.project_name: str = "Unknown Project"
        self.gdscript_analyzer: Optional[GDScriptAnalyzer] = None

    def scan(self) -> bool:
        """Scan the project directory"""
        # Check for project.godot file
        project_file = self.project_path / "project.godot"
        if project_file.exists():
            self._parse_project_file(project_file)
        elif not self.project_path.is_dir():
            # Single file mode
            if self.project_path.suffix == '.tscn':
                self.scenes = [self.project_path]
                self.project_path = self.project_path.parent
                return True
            return False

        # Find all .tscn files
        self.scenes = list(self.project_path.rglob("*.tscn"))

        # Find all .gd files
        self.scripts = list(self.project_path.rglob("*.gd"))

        # Initialize GDScript analyzer
        self.gdscript_analyzer = GDScriptAnalyzer(self.project_path)

        print(f"Found {len(self.scenes)} scene(s) and {len(self.scripts)} script(s)")
        return len(self.scenes) > 0

    def _parse_project_file(self, project_file: Path):
        """Parse project.godot for project name"""
        try:
            with open(project_file, 'r', encoding='utf-8') as f:
                content = f.read()
            match = re.search(r'config/name\s*=\s*"([^"]+)"', content)
            if match:
                self.project_name = match.group(1)
        except Exception:
            pass

    def get_scene_files(self) -> List[Path]:
        """Get list of scene files, excluding .godot directory"""
        return [s for s in self.scenes if '.godot' not in str(s)]

    def parse_all_scenes(self) -> List[Dict[str, Any]]:
        """Parse all scenes in the project"""
        scene_trees = []

        for scene_path in self.get_scene_files():
            print(f"Parsing: {scene_path.relative_to(self.project_path)}")
            try:
                parser = TscnParser(str(scene_path), self.project_path)
                if self.gdscript_analyzer:
                    parser.set_gdscript_analyzer(self.gdscript_analyzer)

                scene_tree = parser.parse()
                if scene_tree:
                    # Add scene file path for reference
                    scene_tree['_scenePath'] = str(scene_path.relative_to(self.project_path))
                    scene_trees.append(scene_tree)
                    print(f"  ✓ Parsed: {scene_tree.get('name', 'Unknown')}")
            except Exception as e:
                print(f"  ✗ Error: {e}")

        return scene_trees


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

    def upload(self, project_id: int, project_name: str, scenes: List[Dict]) -> bool:
        """Upload project with all scenes to DynamoDB"""

        # Build scene root containing all scenes
        if len(scenes) == 1:
            scene_root = scenes[0]
        else:
            scene_root = self._merge_scenes(scenes)

        # Build DynamoDB item with native types
        item = {
            "projectID": {"N": str(project_id)},
            "projectName": {"S": project_name},
            "sceneRoot": self._to_dynamodb_attr(scene_root),
            "sceneCount": {"N": str(len(scenes))},
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
                    print(f"✓ Uploaded to DynamoDB (project ID: {project_id}, {len(scenes)} scene(s))")
                    return True
                else:
                    print(f"✗ Upload failed: {response.status}")
                    return False
        except Exception as e:
            print(f"✗ Error uploading: {e}")
            return False

    def _merge_scenes(self, scenes: List[Dict]) -> Dict[str, Any]:
        """Merge multiple scenes under a project root"""
        root = {
            'id': 1,
            'type': 'Node2D',
            'name': 'ProjectRoot',
            'children': [],
            'widgets': [],
            'properties': {},
            'positionProgrammatic': False,
            'sizeProgrammatic': False
        }

        next_id = 2
        for scene in scenes:
            scene, next_id = self._renumber_ids(scene, next_id)
            root['children'].append(scene)

        return root

    def _renumber_ids(self, node: Dict[str, Any], start_id: int) -> Tuple[Dict, int]:
        """Renumber node IDs starting from start_id"""
        node['id'] = start_id
        next_id = start_id + 1

        for widget in node.get('widgets', []):
            widget['id'] = next_id
            next_id += 1

        for child in node.get('children', []):
            child, next_id = self._renumber_ids(child, next_id)

        return node, next_id


def main():
    parser = argparse.ArgumentParser(description="Import Godot projects to GameGen DynamoDB")
    parser.add_argument("path", help="Path to Godot project directory or .tscn file")
    parser.add_argument("--project-id", type=int, required=True, help="Project ID for DynamoDB")
    parser.add_argument("--project-name", default=None, help="Project name (auto-detected if not specified)")
    parser.add_argument("--dry-run", action="store_true", help="Parse only, don't upload")
    parser.add_argument("--output", help="Output JSON to file instead of uploading")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")

    args = parser.parse_args()

    # Scan project
    scanner = GodotProjectScanner(args.path)
    if not scanner.scan():
        print(f"No valid Godot project or scenes found at: {args.path}")
        sys.exit(1)

    # Use provided name or auto-detected
    project_name = args.project_name or scanner.project_name

    print(f"\nProject: {project_name}")
    print(f"Location: {scanner.project_path}")
    print("-" * 50)

    # Parse all scenes
    scene_trees = scanner.parse_all_scenes()

    if not scene_trees:
        print("No scenes parsed successfully")
        sys.exit(1)

    print("-" * 50)
    print(f"Successfully parsed {len(scene_trees)} scene(s)")

    # Count programmatic flags
    pos_prog_count = sum(1 for s in scene_trees if s.get('positionProgrammatic'))
    size_prog_count = sum(1 for s in scene_trees if s.get('sizeProgrammatic'))
    if pos_prog_count or size_prog_count:
        print(f"Detected programmatic: {pos_prog_count} position(s), {size_prog_count} size(s)")

    # Output or upload
    if args.output:
        output_data = {
            "projectID": args.project_id,
            "projectName": project_name,
            "scenes": scene_trees,
            "sceneCount": len(scene_trees),
            "savedAt": datetime.now().isoformat()
        }
        with open(args.output, 'w') as f:
            json.dump(output_data, f, indent=2)
        print(f"\nOutput written to: {args.output}")
    elif args.dry_run:
        print("\nDry run - scene summary:")
        for scene in scene_trees:
            path = scene.get('_scenePath', 'unknown')
            name = scene.get('name', 'Unknown')
            pos_prog = "⚡" if scene.get('positionProgrammatic') else ""
            size_prog = "📐" if scene.get('sizeProgrammatic') else ""
            print(f"  • {path}: {name} {pos_prog}{size_prog}")

        if args.verbose:
            print("\nFull output:")
            print(json.dumps(scene_trees, indent=2))
    else:
        uploader = DynamoDBUploader()
        if uploader.upload(args.project_id, project_name, scene_trees):
            print("\n✓ Import complete!")
        else:
            sys.exit(1)


if __name__ == '__main__':
    main()
