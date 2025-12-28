---
name: godot-scene-importer
description: Import Godot .tscn scene files and convert them to GameGen's container/widget format for storage in DynamoDB. Use when importing existing Godot UI scenes into GameGen.
allowed-tools: Read, Bash(python:*), Glob, Grep, mcp__dynamodb__put_item, mcp__dynamodb__scan_table
---

# Godot Scene Importer Skill

Converts Godot .tscn scene files to GameGen's scene hierarchy format and stores them in DynamoDB.

## What this Skill does

1. Reads Godot .tscn scene files from a project
2. Parses the node hierarchy to identify containers, widgets, and 2D nodes
3. Converts to GameGen's hierarchical scene format (matching SceneLayout table schema)
4. Uploads to DynamoDB using native Map types for efficient storage

## Usage

Ask Claude to:
- "Import the Godot scene main.tscn into GameGen"
- "Parse all UI scenes from /path/to/project and upload to DynamoDB"
- "Convert scene.tscn to GameGen format"
- "Import Godot project scenes for project ID 1"

## Supported Node Types

### 2D Nodes
- Node2D, Sprite2D, AnimatedSprite2D

### Container Types
- VBoxContainer, HBoxContainer
- GridContainer, FlowContainer (HFlowContainer, VFlowContainer)
- MarginContainer, PanelContainer
- CenterContainer, AspectRatioContainer
- HSplitContainer, VSplitContainer
- TabContainer

### Widget Types
- Button, Label, LineEdit, TextEdit
- CheckBox, CheckButton, OptionButton
- SpinBox, HSlider, VSlider
- ProgressBar, ColorRect, TextureRect
- ColorPickerButton, RichTextLabel

### Animation
- AnimationPlayer

## Output Format

The converter produces a hierarchical scene tree matching GameGen's SceneLayout schema:

```json
{
  "projectID": 1,
  "projectName": "Imported Project",
  "sceneRoot": {
    "id": 1,
    "type": "Node2D",
    "name": "Root",
    "children": [
      {
        "id": 2,
        "type": "VBoxContainer",
        "name": "MainContainer",
        "children": [],
        "widgets": [
          {
            "id": 3,
            "type": "Button",
            "name": "Button",
            "properties": {
              "text": "Click Me"
            }
          }
        ],
        "properties": {
          "positionX": 0,
          "positionY": 0,
          "sizeX": 200,
          "sizeY": 150
        }
      }
    ],
    "properties": {}
  },
  "savedAt": "2025-12-27T10:30:00"
}
```

## DynamoDB Storage

Uses the GameGen DynamoDB endpoint: http://zycroft.duckdns.org:8001
Table: SceneLayout

Data is stored using native DynamoDB types:
- Numbers (N) for numeric values
- Strings (S) for text
- Maps (M) for nested objects like sceneRoot
- Lists (L) for arrays like children and widgets
- Booleans (BOOL) for true/false values

## Implementation Steps

1. Find all .tscn files in the target directory
2. Parse each scene to extract node hierarchy
3. Map Godot nodes to GameGen node types
4. Build hierarchical scene tree with unique IDs
5. Convert to DynamoDB Map format
6. Upload to DynamoDB SceneLayout table

## Helper Script

Run the import script:
```bash
python .claude/skills/godot-scene-importer/scripts/import_godot_scene.py /path/to/scene.tscn --project-id 1
```
