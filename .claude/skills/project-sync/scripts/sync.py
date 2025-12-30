#!/usr/bin/env python3
"""
Project Sync - Synchronize GameGen projects to Godot.

This module orchestrates the sync process:
1. Fetch project data and Game Design responses from DynamoDB
2. Parse AI responses to extract scene hierarchies
3. Merge with existing SceneLayout data
4. Generate .tscn files for the Godot project

Can be used as a library (called by Claude with MCP-fetched data) or
as a standalone CLI for testing.
"""

import json
import sys
import argparse
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Any, Optional, Tuple

from models import SceneNode, ParsedScene, reset_id_counter
from parser import AIResponseParser, parse_game_design_response
from generator import TscnGenerator, generate_tscn, generate_project_godot


class ProjectSyncer:
    """Synchronize a GameGen project to Godot."""

    def __init__(self, project_id: int, project_name: str, godot_path: str):
        """
        Initialize the syncer.

        Args:
            project_id: The project ID
            project_name: The project name
            godot_path: Path to the Godot project directory
        """
        self.project_id = project_id
        self.project_name = project_name
        self.godot_path = Path(godot_path)
        self.generator = TscnGenerator()
        self.parser = AIResponseParser()

    def sync_from_game_design(
        self,
        game_design_response: str,
        existing_scene_root: Optional[Dict[str, Any]] = None,
        dry_run: bool = False
    ) -> Dict[str, Any]:
        """
        Sync project from a Game Design AI response.

        Args:
            game_design_response: The AI-generated game design document
            existing_scene_root: Existing SceneLayout data (if any)
            dry_run: If True, don't write files

        Returns:
            Dict with sync results including generated files and updated scene
        """
        results = {
            'success': False,
            'files_generated': [],
            'scene_root': None,
            'errors': []
        }

        # Reset ID counter for fresh scene generation
        reset_id_counter(1)

        # Parse the AI response to extract scene hierarchy
        parsed_root = parse_game_design_response(game_design_response)

        if not parsed_root:
            results['errors'].append("Could not extract scene hierarchy from AI response")
            return results

        # Merge with existing scene if provided
        if existing_scene_root:
            existing_node = SceneNode.from_dict(existing_scene_root)
            merged_root = self._merge_scenes(parsed_root, existing_node)
        else:
            merged_root = parsed_root

        results['scene_root'] = merged_root.to_dict()

        # Collect all Scene nodes for separate export
        scenes = self._collect_scenes(merged_root)

        if not scenes:
            # No explicit scenes, export root as single scene
            scenes = [ParsedScene(root=merged_root, scene_path="Scenes/Main.tscn")]

        # Generate files
        for scene in scenes:
            try:
                tscn_content = self.generator.generate(scene.root, Path(scene.scene_path).stem)
                output_path = self.godot_path / scene.scene_path

                if dry_run:
                    print(f"\n--- {scene.scene_path} ---")
                    print(tscn_content)
                    print(f"--- End {scene.scene_path} ---")
                else:
                    output_path.parent.mkdir(parents=True, exist_ok=True)
                    output_path.write_text(tscn_content, encoding='utf-8')
                    print(f"✓ Generated: {scene.scene_path}")

                results['files_generated'].append({
                    'path': scene.scene_path,
                    'content': tscn_content
                })

            except Exception as e:
                results['errors'].append(f"Failed to generate {scene.scene_path}: {e}")

        # Ensure project.godot exists
        if not dry_run and scenes:
            self._ensure_project_file(scenes[0].scene_path)

        results['success'] = len(results['errors']) == 0
        return results

    def sync_from_scene_layout(
        self,
        scene_root: Dict[str, Any],
        dry_run: bool = False
    ) -> Dict[str, Any]:
        """
        Sync project from existing SceneLayout data.

        Args:
            scene_root: The sceneRoot dict from DynamoDB
            dry_run: If True, don't write files

        Returns:
            Dict with sync results
        """
        results = {
            'success': False,
            'files_generated': [],
            'errors': []
        }

        root_node = SceneNode.from_dict(scene_root)
        scenes = self._collect_scenes(root_node)

        if not scenes:
            scenes = [ParsedScene(root=root_node, scene_path="Scenes/Main.tscn")]

        for scene in scenes:
            try:
                tscn_content = self.generator.generate(scene.root, Path(scene.scene_path).stem)
                output_path = self.godot_path / scene.scene_path

                if dry_run:
                    print(f"\n--- {scene.scene_path} ---")
                    print(tscn_content)
                else:
                    output_path.parent.mkdir(parents=True, exist_ok=True)
                    output_path.write_text(tscn_content, encoding='utf-8')
                    print(f"✓ Generated: {scene.scene_path}")

                results['files_generated'].append({
                    'path': scene.scene_path,
                    'content': tscn_content
                })

            except Exception as e:
                results['errors'].append(f"Failed to generate {scene.scene_path}: {e}")

        if not dry_run and scenes:
            self._ensure_project_file(scenes[0].scene_path)

        results['success'] = len(results['errors']) == 0
        return results

    def _merge_scenes(self, new_root: SceneNode, existing_root: SceneNode) -> SceneNode:
        """
        Merge a new scene structure with existing data.

        Preserves user-set properties from existing while adopting
        the new structure from AI.
        """
        # For now, prefer the new structure but preserve position/size from existing
        self._copy_layout_properties(new_root, existing_root)
        return new_root

    def _copy_layout_properties(self, target: SceneNode, source: SceneNode) -> None:
        """Copy layout properties from source to target for matching nodes."""
        # Find matching node in source by name
        source_node = source.find_node(target.name)

        if source_node:
            # Copy position/size properties
            if source_node.properties.position_x != 0:
                target.properties.position_x = source_node.properties.position_x
            if source_node.properties.position_y != 0:
                target.properties.position_y = source_node.properties.position_y
            if source_node.properties.size_x != 0:
                target.properties.size_x = source_node.properties.size_x
            if source_node.properties.size_y != 0:
                target.properties.size_y = source_node.properties.size_y

        # Recurse to children
        for child in target.children:
            self._copy_layout_properties(child, source)
        for widget in target.widgets:
            self._copy_layout_properties(widget, source)

    def _collect_scenes(self, root: SceneNode) -> List[ParsedScene]:
        """Collect all Scene nodes for separate export."""
        scenes = []
        self._collect_scenes_recursive(root, scenes)
        return scenes

    def _collect_scenes_recursive(self, node: SceneNode, scenes: List[ParsedScene]) -> None:
        """Recursively collect Scene nodes."""
        if node.type == 'Scene' and node.scene_path:
            scenes.append(ParsedScene(root=node, scene_path=node.scene_path))

        for child in node.children:
            self._collect_scenes_recursive(child, scenes)

    def _ensure_project_file(self, main_scene_path: str) -> None:
        """Create project.godot if it doesn't exist."""
        project_file = self.godot_path / "project.godot"

        if project_file.exists():
            # Update main scene path
            import re
            content = project_file.read_text(encoding='utf-8')
            res_path = f'res://{main_scene_path}'

            if 'run/main_scene=' in content:
                content = re.sub(
                    r'run/main_scene="[^"]*"',
                    f'run/main_scene="{res_path}"',
                    content
                )
            else:
                content = re.sub(
                    r'(config/name="[^"]*")',
                    f'\\1\nrun/main_scene="{res_path}"',
                    content
                )
            project_file.write_text(content, encoding='utf-8')
            print(f"✓ Updated project.godot: main_scene = {res_path}")
        else:
            content = generate_project_godot(self.project_name, main_scene_path)
            self.godot_path.mkdir(parents=True, exist_ok=True)
            project_file.write_text(content, encoding='utf-8')
            print(f"✓ Created project.godot")


# ============================================================================
# Standalone CLI for testing (uses HTTP client directly)
# ============================================================================

class DynamoDBClient:
    """Simple HTTP client for DynamoDB (for standalone testing)."""

    def __init__(self, endpoint: str = "http://zycroft.duckdns.org:8001"):
        self.endpoint = endpoint

    def _request(self, target: str, body: dict) -> Optional[dict]:
        """Make a DynamoDB API request."""
        import urllib.request

        headers = {
            "Content-Type": "application/x-amz-json-1.0",
            "X-Amz-Target": f"DynamoDB_20120810.{target}",
            "Authorization": "AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
            "X-Amz-Date": "20250101T000000Z"
        }

        try:
            req = urllib.request.Request(
                self.endpoint,
                data=json.dumps(body).encode('utf-8'),
                headers=headers,
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                if response.status == 200:
                    return json.loads(response.read().decode('utf-8'))
        except Exception as e:
            print(f"DynamoDB request error: {e}")
        return None

    def _from_dynamodb_attr(self, attr: Any) -> Any:
        """Convert DynamoDB attribute format to Python value."""
        if not isinstance(attr, dict):
            return attr

        if 'NULL' in attr:
            return None
        elif 'BOOL' in attr:
            return attr['BOOL']
        elif 'N' in attr:
            num = attr['N']
            return float(num) if '.' in str(num) else int(num)
        elif 'S' in attr:
            return attr['S']
        elif 'L' in attr:
            return [self._from_dynamodb_attr(item) for item in attr['L']]
        elif 'M' in attr:
            return {k: self._from_dynamodb_attr(v) for k, v in attr['M'].items()}
        return attr

    def get_project(self, project_id: int) -> Optional[Dict[str, Any]]:
        """Fetch project info."""
        result = self._request('GetItem', {
            "TableName": "Projects",
            "Key": {"ID": {"N": str(project_id)}}
        })
        if result and 'Item' in result:
            return {k: self._from_dynamodb_attr(v) for k, v in result['Item'].items()}
        return None

    def get_scene_layout(self, project_id: int) -> Optional[Dict[str, Any]]:
        """Fetch scene layout."""
        result = self._request('GetItem', {
            "TableName": "SceneLayout",
            "Key": {"projectID": {"N": str(project_id)}}
        })
        if result and 'Item' in result:
            return {k: self._from_dynamodb_attr(v) for k, v in result['Item'].items()}
        return None

    def get_game_design_prompt(self, project_id: int) -> Optional[Dict[str, Any]]:
        """Fetch the latest Game Design prompt for a project."""
        result = self._request('Query', {
            "TableName": "AIPrompts",
            "KeyConditionExpression": "projectObjectID = :pid",
            "FilterExpression": "title = :title",
            "ExpressionAttributeValues": {
                ":pid": {"S": f"{project_id}_0"},
                ":title": {"S": "Game Design"}
            },
            "ScanIndexForward": False,
            "Limit": 1
        })
        if result and result.get('Items'):
            item = result['Items'][0]
            return {k: self._from_dynamodb_attr(v) for k, v in item.items()}
        return None

    def _to_dynamodb_attr(self, value: Any) -> Dict[str, Any]:
        """Convert Python value to DynamoDB attribute format."""
        if value is None:
            return {"NULL": True}
        elif isinstance(value, bool):
            return {"BOOL": value}
        elif isinstance(value, int) or isinstance(value, float):
            return {"N": str(value)}
        elif isinstance(value, str):
            return {"S": value}
        elif isinstance(value, list):
            return {"L": [self._to_dynamodb_attr(item) for item in value]}
        elif isinstance(value, dict):
            return {"M": {k: self._to_dynamodb_attr(v) for k, v in value.items()}}
        else:
            return {"S": str(value)}

    def put_scene_layout(self, project_id: int, project_name: str, scene_root: Dict[str, Any]) -> bool:
        """Save scene layout to DynamoDB."""
        item = {
            "projectID": {"N": str(project_id)},
            "projectName": {"S": project_name},
            "sceneRoot": self._to_dynamodb_attr(scene_root),
            "savedAt": {"S": datetime.now().strftime("%Y-%m-%dT%H:%M:%S")}
        }
        result = self._request('PutItem', {
            "TableName": "SceneLayout",
            "Item": item
        })
        return result is not None


def main():
    """CLI entry point for testing."""
    parser = argparse.ArgumentParser(
        description="Sync GameGen project to Godot"
    )
    parser.add_argument(
        "--project-id", type=int, required=True,
        help="Project ID to sync"
    )
    parser.add_argument(
        "--output-dir", type=Path,
        help="Output directory (overrides GodotProjectPath)"
    )
    parser.add_argument(
        "--from-game-design", action="store_true",
        help="Parse Game Design AI response to build scene"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print output instead of writing files"
    )
    parser.add_argument(
        "--endpoint", default="http://zycroft.duckdns.org:8001",
        help="DynamoDB endpoint"
    )

    args = parser.parse_args()

    # Fetch project data
    db = DynamoDBClient(args.endpoint)
    project = db.get_project(args.project_id)

    if not project:
        print(f"Project {args.project_id} not found")
        sys.exit(1)

    project_name = project.get('Name', 'Unknown')
    godot_path = args.output_dir or project.get('GodotProjectPath')

    if not godot_path:
        print("No GodotProjectPath set. Use --output-dir")
        sys.exit(1)

    print(f"Project: {project_name} (ID: {args.project_id})")
    print(f"Target: {godot_path}")
    print("-" * 50)

    syncer = ProjectSyncer(args.project_id, project_name, str(godot_path))

    if args.from_game_design:
        # Use Game Design AI response
        prompt = db.get_game_design_prompt(args.project_id)
        if not prompt or not prompt.get('response'):
            print("No Game Design response found")
            sys.exit(1)

        print(f"Using Game Design prompt: {prompt.get('promptID', 'unknown')}")

        # Get existing scene layout if any
        layout = db.get_scene_layout(args.project_id)
        existing_root = layout.get('sceneRoot') if layout else None

        results = syncer.sync_from_game_design(
            prompt['response'],
            existing_root,
            dry_run=args.dry_run
        )

        # Save parsed scene to SceneLayout
        if results['success'] and results.get('scene_root') and not args.dry_run:
            if db.put_scene_layout(args.project_id, project_name, results['scene_root']):
                print(f"✓ Saved scene hierarchy to SceneLayout")
            else:
                print(f"⚠ Failed to save SceneLayout to DynamoDB")
    else:
        # Use existing SceneLayout
        layout = db.get_scene_layout(args.project_id)
        if not layout or not layout.get('sceneRoot'):
            print("No scene layout found")
            sys.exit(1)

        print(f"Using SceneLayout (saved: {layout.get('savedAt', 'unknown')})")

        results = syncer.sync_from_scene_layout(
            layout['sceneRoot'],
            dry_run=args.dry_run
        )

    print("-" * 50)
    if results['success']:
        print(f"Sync complete: {len(results['files_generated'])} file(s)")
    else:
        print(f"Sync failed with {len(results['errors'])} error(s):")
        for err in results['errors']:
            print(f"  - {err}")
        sys.exit(1)


if __name__ == '__main__':
    main()
