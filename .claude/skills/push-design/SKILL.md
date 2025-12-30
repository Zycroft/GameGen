---
name: push-design
description: Push GameGen Game Design to Godot by parsing AI responses and generating .tscn scene files. Consumes AI responses to build Godot objects/controls.
allowed-tools: Read, Write, Bash(python3:*), Glob, Grep, mcp__dynamodb__get_item, mcp__dynamodb__query_table, mcp__dynamodb__scan_table, mcp__dynamodb__put_item
---

# Push Design Skill

Pushes GameGen Game Design to Godot by:
1. Fetching Game Design AI responses from DynamoDB
2. Parsing the AI-generated scene hierarchy
3. Generating Godot .tscn scene files
4. Updating the Godot project structure

## What This Skill Does

The Push Design skill bridges GameGen's AI-assisted design process with actual Godot project files:

1. **Reads Game Design prompts** from the AIPrompts table
2. **Parses AI responses** to extract scene hierarchies (the AI generates tree structures like `Root (Node2D) → UI (Control) → ...`)
3. **Merges with existing layouts** preserving user-set positions/sizes
4. **Generates .tscn files** in proper Godot 4.x format
5. **Updates project.godot** with the main scene

## Usage

Ask Claude to:
- "Push design for project 2"
- "Build Godot project from the Game Design response"
- "Generate .tscn files from the AI design for project 1"
- "Update the Godot project based on Game Design"

### Workflow

1. **Create Game Design** in GameGen (right-click [PRJ] → Game Design)
2. **Generate AI response** describing the scene structure
3. **Run push-design** to convert AI response to .tscn files

### Command Line Testing

```bash
cd .claude/skills/push-design/scripts

# Sync from existing SceneLayout
python3 sync.py --project-id 2

# Sync from Game Design AI response (parses the response)
python3 sync.py --project-id 2 --from-game-design

# Dry run to preview output
python3 sync.py --project-id 2 --from-game-design --dry-run

# Custom output directory
python3 sync.py --project-id 2 --output-dir /path/to/godot/project
```

## Architecture

### Module Structure

```
push-design/
├── SKILL.md           # This file
└── scripts/
    ├── models.py      # Data classes (SceneNode, NodeProperties)
    ├── parser.py      # AI response parser (extracts tree structures)
    ├── generator.py   # .tscn file generator
    └── sync.py        # Main orchestrator
```

### Data Models (models.py)

- **SceneNode**: Represents a node in the scene hierarchy
- **NodeProperties**: Node properties (position, size, text, color, etc.)
- **ParsedScene**: A parsed scene ready for export

### Parser (parser.py)

Extracts scene hierarchies from AI responses. Handles formats like:

```
Root (Node2D)
├── UI (Control)
│   ├── ToolbarLeft (HBoxContainer)
│   │   └── Button_NewGame (Button)
│   └── StatusBar (HBoxContainer)
└── SlotMachine (Node2D)
```

### Generator (generator.py)

Converts SceneNode trees to Godot .tscn format:

```
[gd_scene load_steps=1 format=3]

[node name="Root" type="Node2D"]

[node name="UI" type="Control" parent="."]

[node name="ToolbarLeft" type="HBoxContainer" parent="UI"]
```

### Syncer (sync.py)

Orchestrates the sync process:
1. Fetches data from DynamoDB (via MCP or direct HTTP)
2. Parses Game Design responses
3. Merges with existing scene layouts
4. Generates and writes .tscn files

## DynamoDB Tables

| Table | Keys | Used For |
|-------|------|----------|
| Projects | ID (N) | Project name, GodotProjectPath |
| SceneLayout | projectID (N) | Existing scene hierarchy (sceneRoot) |
| AIPrompts | projectObjectID (S), promptID (S) | Game Design responses |

### Finding Game Design Prompts

Game Design prompts have:
- `projectObjectID`: `"{projectID}_0"` (e.g., "2_0")
- `title`: "Game Design"
- `response`: The AI-generated design document

## Supported Node Types

### 2D Nodes
- Node2D, Sprite2D, AnimatedSprite2D
- CharacterBody2D, RigidBody2D, StaticBody2D, Area2D

### Containers
- VBoxContainer, HBoxContainer, GridContainer
- FlowContainer, PanelContainer, MarginContainer
- CenterContainer, AspectRatioContainer
- HSplitContainer, VSplitContainer, TabContainer

### Controls
- Button, Label, LineEdit, TextEdit
- CheckBox, CheckButton, OptionButton, MenuButton
- SpinBox, HSlider, VSlider, ProgressBar
- ColorRect, TextureRect, RichTextLabel

## Property Mapping

| GameGen Property | Godot Property | Node Types |
|-----------------|----------------|------------|
| positionX/Y | `position = Vector2(x, y)` | Node2D types |
| positionX/Y | `offset_left/top` | Control types |
| sizeX/Y | `offset_right/bottom` | Control types |
| minSizeX/Y | `custom_minimum_size` | All |
| text | `text` | Button, Label, etc. |
| color | `color = Color(r, g, b, 1)` | ColorRect |
| texture | `texture = ExtResource("id")` | Sprite2D, TextureRect |
| columns | `columns` | GridContainer |

## Example Workflow (Claude)

```
1. Query AIPrompts for Game Design response:
   mcp__dynamodb__query_table(
     tableName="AIPrompts",
     keyConditionExpression="projectObjectID = :pid",
     expressionAttributeValues={":pid": {"S": "2_0"}}
   )

2. Get project info:
   mcp__dynamodb__get_item(
     tableName="Projects",
     key={"ID": {"N": "2"}}
   )

3. Parse AI response and generate .tscn:
   python3 scripts/sync.py --project-id 2 --from-game-design

4. Or use the Python modules directly with MCP-fetched data
```

## Merging Behavior

When syncing from Game Design with existing SceneLayout:
- **Structure**: Adopts the new AI-generated hierarchy
- **Layout properties**: Preserves user-set positions/sizes from existing nodes
- **New nodes**: Added with default properties
- **Removed nodes**: Dropped from the merged result

This allows iterative refinement: regenerate Game Design to restructure, keep manual layout adjustments.
