# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GameGen is a Godot 4.5 visual game design application with AI-powered content generation. It provides a drag-and-drop interface for designing game UI layouts that persist to DynamoDB, with AI assistants for generating game design documents and content.

## Running the Project

```bash
# Run in Godot editor
/Applications/Godot.app/Contents/MacOS/Godot --path /Users/zycroft/Documents/apps/GameGen

# Or use the MCP tool
mcp__godot__run_project with projectPath="/Users/zycroft/Documents/apps/GameGen"
```

## Architecture

### Godot Application (GDScript)

- **main.gd** - Application controller: manages scene tree, viewport frame, project loading/saving, node spawning, and coordinates between panels. Maintains `scene_root` dictionary representing the node hierarchy.

- **scene_hierarchy.gd** (SceneHierarchy class) - Left panel: displays tree view of scene hierarchy, handles project selection/creation, provides context menus for nodes, and contains the Game Design dialog for AI-assisted design. Right-click on `[PRJ]` root node opens Game Design menu.

- **draggable_container.gd** (DraggableContainer class) - Visual containers representing Godot Control nodes. Supports drag/resize, widget spawning, AI prompts per node, and properties editing. Each container maps to a node in the scene hierarchy.

- **draggable_window.gd** (ControlsPanel) - Right toolbar: categorized buttons for spawning containers (VBox, HBox, Grid, etc.) and widgets.

### AI Worker (Python)

Located in `ai-worker/worker.py`. Polls DynamoDB for prompts with `status='generate'`, calls the appropriate AI service, and updates with responses.

Supported services: Zycroft (Ollama), OpenAI, Claude, Gemini, Grok
Supported image services: OpenAI (DALL-E, gpt-image-1), Stability, Midjourney

### Claude Skills

- **/godot-scene-exporter** - Exports GameGen scenes to Godot `.tscn` files
- **/project-importer** - Imports Godot projects into GameGen format

## Remote Services (zycroft.duckdns.org)

### Docker Containers

| Container | Port | Purpose |
|-----------|------|---------|
| `dynamodb-local` | 8001 | Data persistence |
| `ollama` | 11434 | Local LLM inference |
| `gamegen-ai-worker` | - | Processes AI prompt queue |
| `dynamodb-mcp-server` | - | MCP server for DynamoDB |
| `imagemagick-mcp-server` | - | MCP server for images |
| `openai-mcp-server` | - | MCP server for OpenAI |

### Managing Containers

```bash
ssh zycroft@zycroft.duckdns.org
cd ~/gamegen-ai-worker && docker compose restart
docker logs -f gamegen-ai-worker
```

### Endpoints

- DynamoDB: `http://zycroft.duckdns.org:8001`
- Ollama: `http://zycroft.duckdns.org:11434`

## Configuration

- **config.json** - DynamoDB endpoint, table names, AI services/models, daily usage limits
- **config-api.json** - API keys for external services (not in git)

## DynamoDB Tables

| Table | Keys | Purpose |
|-------|------|---------|
| `Projects` | projectID (N) | Project metadata |
| `SceneLayout` | projectID (N) | Scene hierarchy data |
| `AIPrompts` | projectObjectID (S), promptID (S) | AI prompt queue |
| `UsageTracking` | date (S), service (S) | Daily usage counts |

## AI Prompt Flow

1. Godot saves to `AIPrompts` with `status: "generate"`
2. Worker polls, processes via AI service
3. Worker updates with `status: "completed"` or `"error"`
4. Godot polls and displays response

## CI/CD

GitHub Actions workflow (`.github/workflows/deploy-ai-worker.yml`) auto-deploys ai-worker changes to the remote server on push to main.

## Code Style

Every new file must include a comment at the top explaining concisely what the file does:

```gdscript
# Manages the draggable container UI for visual node editing
class_name DraggableContainer
extends Panel
```

```python
"""
AI Prompt Generation Worker - Polls DynamoDB for prompts and generates
responses using configured AI services.
"""
```
