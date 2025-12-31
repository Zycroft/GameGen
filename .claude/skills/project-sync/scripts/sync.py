#!/usr/bin/env python3
"""
Project Sync - Export GameGen SceneLayout from DynamoDB to Godot .tscn files.

This is the frequent sync operation for development. For initial project setup
from AI Game Design responses, use push-design instead.
"""

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Dict, Any, Optional
from urllib.request import Request, urlopen
from urllib.error import URLError

# Add push-design scripts to path for shared modules
SKILLS_DIR = Path(__file__).parent.parent.parent
PUSH_DESIGN_SCRIPTS = SKILLS_DIR / "push-design" / "scripts"
sys.path.insert(0, str(PUSH_DESIGN_SCRIPTS))

from models import SceneNode, reset_id_counter
from generator import TscnGenerator

# DynamoDB configuration
DYNAMODB_ENDPOINT = os.environ.get("DYNAMODB_ENDPOINT", "http://zycroft.duckdns.org:8001")


def dynamodb_request(operation: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    """Make a DynamoDB HTTP request."""
    headers = {
        "Content-Type": "application/x-amz-json-1.0",
        "X-Amz-Target": f"DynamoDB_20120810.{operation}",
        "Authorization": "AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
        "X-Amz-Date": "20250101T000000Z"
    }

    data = json.dumps(payload).encode('utf-8')
    request = Request(DYNAMODB_ENDPOINT, data=data, headers=headers, method='POST')

    try:
        with urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode('utf-8'))
    except URLError as e:
        print(f"DynamoDB request failed: {e}")
        raise


def parse_dynamodb_value(value: Dict[str, Any]) -> Any:
    """Parse a DynamoDB typed value to Python."""
    if "S" in value:
        return value["S"]
    elif "N" in value:
        return float(value["N"]) if "." in value["N"] else int(value["N"])
    elif "BOOL" in value:
        return value["BOOL"]
    elif "NULL" in value:
        return None
    elif "M" in value:
        return {k: parse_dynamodb_value(v) for k, v in value["M"].items()}
    elif "L" in value:
        return [parse_dynamodb_value(item) for item in value["L"]]
    return value


def get_project(project_id: int) -> Optional[Dict[str, Any]]:
    """Get project info from DynamoDB."""
    result = dynamodb_request("GetItem", {
        "TableName": "Projects",
        "Key": {"ID": {"N": str(project_id)}}
    })

    if "Item" not in result:
        return None

    return {k: parse_dynamodb_value(v) for k, v in result["Item"].items()}


def get_scene_layout(project_id: int) -> Optional[Dict[str, Any]]:
    """Get scene layout from DynamoDB."""
    result = dynamodb_request("GetItem", {
        "TableName": "SceneLayout",
        "Key": {"projectID": {"N": str(project_id)}}
    })

    if "Item" not in result:
        return None

    return {k: parse_dynamodb_value(v) for k, v in result["Item"].items()}


def sync_project(project_id: int, output_dir: Optional[str] = None, dry_run: bool = False) -> bool:
    """
    Sync a project from DynamoDB to Godot .tscn files.

    Args:
        project_id: The project ID in DynamoDB
        output_dir: Override output directory (defaults to project's GodotProjectPath)
        dry_run: If True, print output instead of writing files

    Returns:
        True if successful, False otherwise
    """
    # Get project info
    project = get_project(project_id)
    if not project:
        print(f"Project {project_id} not found")
        return False

    project_name = project.get("name", f"Project{project_id}")
    godot_path = output_dir or project.get("GodotProjectPath")

    if not godot_path:
        print(f"No GodotProjectPath configured for project {project_id}")
        print("Use --output-dir to specify output location")
        return False

    print(f"Syncing project: {project_name}")
    print(f"Output path: {godot_path}")

    # Get scene layout
    layout = get_scene_layout(project_id)
    if not layout:
        print(f"No scene layout found for project {project_id}")
        return False

    scene_root = layout.get("sceneRoot")
    if not scene_root:
        print("Scene layout has no sceneRoot")
        return False

    # Convert to SceneNode tree
    reset_id_counter()
    root_node = SceneNode.from_dict(scene_root)

    # Determine scene path
    scene_path = scene_root.get("_scenePath", "Scenes/Main.tscn")
    if not scene_path.endswith(".tscn"):
        scene_path = f"Scenes/{scene_path}.tscn"

    # Generate .tscn content
    generator = TscnGenerator()
    tscn_content = generator.generate(root_node)

    if dry_run:
        print(f"\n=== {scene_path} ===")
        print(tscn_content)
        return True

    # Write files
    godot_path = Path(godot_path)
    scene_file = godot_path / scene_path

    # Ensure directory exists
    scene_file.parent.mkdir(parents=True, exist_ok=True)

    # Write scene file
    scene_file.write_text(tscn_content)
    print(f"Written: {scene_file}")

    # Update project.godot
    project_godot = godot_path / "project.godot"
    update_project_godot(project_godot, project_name, f"res://{scene_path}")

    print(f"Sync complete!")
    return True


def update_project_godot(path: Path, project_name: str, main_scene: str) -> None:
    """Update or create project.godot file."""
    content = f"""; Engine configuration file.
; It's best edited using the editor UI and not directly,
; since the parameters that go here are not all obvious.
;
; Format:
;   [section] ; section goes between []
;   param=value ; assign values to parameters

config_version=5

[application]

config/name="{project_name}"
run/main_scene="{main_scene}"
config/features=PackedStringArray("4.5")

[display]

window/size/viewport_width=1152
window/size/viewport_height=648
"""

    path.write_text(content)
    print(f"Updated: {path}")


def main():
    parser = argparse.ArgumentParser(
        description="Sync GameGen SceneLayout from DynamoDB to Godot .tscn files"
    )
    parser.add_argument(
        "--project-id", "-p",
        type=int,
        required=True,
        help="Project ID to sync"
    )
    parser.add_argument(
        "--output-dir", "-o",
        help="Output directory (overrides project's GodotProjectPath)"
    )
    parser.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="Print output without writing files"
    )

    args = parser.parse_args()

    success = sync_project(
        project_id=args.project_id,
        output_dir=args.output_dir,
        dry_run=args.dry_run
    )

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
