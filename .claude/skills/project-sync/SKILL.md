---
name: project-sync
description: Sync GameGen SceneLayout from DynamoDB to Godot .tscn files. Exports current layout without AI parsing.
allowed-tools: Read, Write, Bash(python3:*), Glob, Grep, mcp__dynamodb__get_item, mcp__dynamodb__scan_table
---

# Project Sync Skill

Syncs GameGen scene layouts from DynamoDB to Godot project files.

## What This Skill Does

1. **Reads SceneLayout** from DynamoDB (not AI prompts)
2. **Generates .tscn files** with proper Godot 4.x format
3. **Writes to Godot project** at the configured path
4. **Preserves styling** (background colors, borders, corner radius)

This is the **frequent** sync operation used during development. For initial project setup from AI Game Design, use `push-design` instead.

## Usage

Ask Claude to:
- "Sync project 2 to Godot"
- "Export GameGen layout to Godot"
- "Update Godot project from DynamoDB"
- "project-sync for project 3"

### Command Line

```bash
cd .claude/skills/project-sync/scripts

# Sync project to Godot
python3 sync.py --project-id 2

# Dry run to preview output
python3 sync.py --project-id 2 --dry-run

# Custom output directory
python3 sync.py --project-id 2 --output-dir /path/to/godot/project
```

## Data Flow

```
DynamoDB (SceneLayout) → project-sync → Godot (.tscn files)
```

## DynamoDB Tables Used

| Table | Keys | Data |
|-------|------|------|
| Projects | ID (N) | Project name, GodotProjectPath |
| SceneLayout | projectID (N) | Scene hierarchy (sceneRoot) |

## Generated Output

### Scene File (.tscn)
```
[gd_scene load_steps=5 format=3]

[sub_resource type="StyleBoxFlat" id="StyleBoxFlat_MenuBar_1"]
bg_color = Color(0.145, 0.145, 0.145, 1.000)
...

[node name="Root" type="PanelContainer"]
theme_override_styles/panel = SubResource("StyleBoxFlat_Root_1")

[node name="MenuBar" type="PanelContainer" parent="Root/ScreenStack"]
layout_mode = 2
theme_override_styles/panel = SubResource("StyleBoxFlat_MenuBar_1")
```

### Project Config (project.godot)
```ini
[application]
config/name="MyGame"
run/main_scene="res://Scenes/Main.tscn"
```

## Styling Support

Style properties from GameGen are exported:
- `backgroundColor` → StyleBoxFlat bg_color
- `borderColor` → StyleBoxFlat border_color
- `borderWidth` → StyleBoxFlat border_width_*
- `cornerRadius` → StyleBoxFlat corner_radius_*

Default styles are applied per panel type:
- MenuBar/StatusBar: `#252525`
- Toolbars: `#2a2a2a`
- PlaySpace: `#1e1e1e`
- Dialogs: Transparent

## Related Skills

- **push-design**: Initial project setup from AI Game Design (infrequent)
- **project-importer**: Import Godot changes back to DynamoDB (reverse sync)
