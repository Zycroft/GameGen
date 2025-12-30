"""
Parser for extracting scene hierarchies from AI-generated Game Design responses.

Handles various formats:
- ASCII tree diagrams with box-drawing characters
- Markdown-style hierarchies
- Indented text hierarchies
"""

import re
from typing import List, Optional, Tuple, Dict, Any
from models import SceneNode, NodeProperties, ParsedScene


class AIResponseParser:
    """Parse AI responses to extract Godot scene hierarchies."""

    # Pattern to match node definitions like "NodeName (NodeType)" or "NodeName: NodeType"
    NODE_PATTERN = re.compile(
        r'^[\s│├└─\-\|\+\*]*'  # Tree characters and whitespace
        r'(?:\d+\.\s*)?'  # Optional numbering
        r'(?:\*\*)?'  # Optional bold
        r'[`]?'  # Optional backtick
        r'([A-Za-z_][A-Za-z0-9_]*)'  # Node name (capture group 1)
        r'[`]?'  # Optional backtick
        r'(?:\*\*)?'  # Optional bold
        r'\s*'
        r'[\(:]?\s*'  # Opening paren or colon
        r'[`]?'  # Optional backtick
        r'([A-Za-z][A-Za-z0-9]*)'  # Node type (capture group 2)
        r'[`]?'  # Optional backtick
        r'[\)]?'  # Optional closing paren
    )

    # Pattern to detect code block markers
    CODE_BLOCK_PATTERN = re.compile(r'^```')

    # Known Godot node types for validation
    KNOWN_TYPES = {
        # 2D nodes
        'Node', 'Node2D', 'Sprite2D', 'AnimatedSprite2D', 'CharacterBody2D',
        'RigidBody2D', 'StaticBody2D', 'Area2D', 'Camera2D', 'TileMap',
        'TileMapLayer', 'Polygon2D', 'Line2D',
        # Control nodes
        'Control', 'Panel', 'Button', 'Label', 'LineEdit', 'TextEdit',
        'CheckBox', 'CheckButton', 'OptionButton', 'MenuButton',
        'SpinBox', 'HSlider', 'VSlider', 'ProgressBar',
        'ColorRect', 'TextureRect', 'ColorPickerButton', 'RichTextLabel',
        # Containers
        'VBoxContainer', 'HBoxContainer', 'GridContainer', 'FlowContainer',
        'PanelContainer', 'MarginContainer', 'CenterContainer',
        'AspectRatioContainer', 'HSplitContainer', 'VSplitContainer',
        'TabContainer', 'ScrollContainer', 'SubViewportContainer',
        'ViewportContainer',
        # Dialogs
        'WindowDialog', 'AcceptDialog', 'ConfirmationDialog', 'FileDialog',
        # Other
        'AnimationPlayer', 'AudioStreamPlayer', 'CanvasLayer', 'ParallaxBackground'
    }

    def __init__(self):
        self.debug = False

    def parse(self, response: str, default_scene_path: str = "Scenes/Main.tscn") -> Optional[ParsedScene]:
        """
        Parse an AI response and extract the scene hierarchy.

        Args:
            response: The AI-generated text containing scene structure
            default_scene_path: Default path for the scene file

        Returns:
            ParsedScene if a hierarchy was found, None otherwise
        """
        # Try to find and parse a tree structure
        root = self._extract_tree(response)

        if root:
            return ParsedScene(root=root, scene_path=default_scene_path)

        return None

    def _extract_tree(self, text: str) -> Optional[SceneNode]:
        """Extract a tree structure from text."""
        lines = text.split('\n')

        # Find code blocks with tree structures
        in_code_block = False
        tree_lines = []
        potential_tree_lines = []

        for line in lines:
            if self.CODE_BLOCK_PATTERN.match(line):
                if in_code_block and potential_tree_lines:
                    # End of code block, save if it looks like a tree
                    if self._looks_like_tree(potential_tree_lines):
                        tree_lines = potential_tree_lines
                        break
                in_code_block = not in_code_block
                potential_tree_lines = []
                continue

            if in_code_block:
                potential_tree_lines.append(line)
            else:
                # Also collect lines that look like tree nodes outside code blocks
                if self._is_tree_line(line):
                    potential_tree_lines.append(line)
                elif potential_tree_lines and line.strip() == '':
                    # Empty line might be part of tree
                    potential_tree_lines.append(line)
                elif potential_tree_lines:
                    # Non-tree line ends the potential tree
                    if self._looks_like_tree(potential_tree_lines):
                        tree_lines = potential_tree_lines
                        break
                    potential_tree_lines = []

        # Use the best tree found
        if not tree_lines and self._looks_like_tree(potential_tree_lines):
            tree_lines = potential_tree_lines

        if not tree_lines:
            return None

        return self._parse_tree_lines(tree_lines)

    def _looks_like_tree(self, lines: List[str]) -> bool:
        """Check if lines look like a tree structure."""
        node_count = 0
        for line in lines:
            if self._parse_node_line(line):
                node_count += 1
        return node_count >= 2  # At least root + one child

    def _is_tree_line(self, line: str) -> bool:
        """Check if a line could be part of a tree structure."""
        # Has tree characters or starts with whitespace followed by node pattern
        tree_chars = {'│', '├', '└', '─', '|', '+', '-'}
        has_tree_char = any(c in line for c in tree_chars)
        return has_tree_char or self._parse_node_line(line) is not None

    def _parse_node_line(self, line: str) -> Optional[Tuple[int, str, str]]:
        """
        Parse a single line to extract node info.

        Returns:
            Tuple of (indent_level, node_name, node_type) or None
        """
        if not line.strip():
            return None

        match = self.NODE_PATTERN.match(line)
        if not match:
            return None

        name = match.group(1)
        node_type = match.group(2)

        # Validate node type
        if node_type not in self.KNOWN_TYPES:
            # Try common suffixes/prefixes
            normalized = self._normalize_type(node_type)
            if normalized not in self.KNOWN_TYPES:
                return None
            node_type = normalized

        # Calculate indent level based on tree characters and whitespace
        indent = self._calculate_indent(line)

        return (indent, name, node_type)

    def _normalize_type(self, type_name: str) -> str:
        """Try to normalize a type name to a known Godot type."""
        # Common aliases
        aliases = {
            'Sprite': 'Sprite2D',
            'AnimatedSprite': 'AnimatedSprite2D',
            'WindowDialog': 'Control',  # WindowDialog is deprecated in 4.x
            'Viewport': 'SubViewport',
        }
        return aliases.get(type_name, type_name)

    def _calculate_indent(self, line: str) -> int:
        """Calculate the indentation level of a line."""
        indent = 0
        for char in line:
            if char in ' \t':
                indent += 1
            elif char in '│|':
                indent += 1
            elif char in '├└':
                indent += 1
                break
            elif char in '─-':
                continue
            else:
                break

        # Normalize to levels (roughly 4 chars per level)
        return indent // 3

    def _parse_tree_lines(self, lines: List[str]) -> Optional[SceneNode]:
        """Parse tree lines into a node hierarchy."""
        parsed = []
        for line in lines:
            result = self._parse_node_line(line)
            if result:
                parsed.append(result)

        if not parsed:
            return None

        # Build hierarchy using indent levels
        return self._build_hierarchy(parsed)

    def _build_hierarchy(self, parsed: List[Tuple[int, str, str]]) -> Optional[SceneNode]:
        """Build node hierarchy from parsed tuples."""
        if not parsed:
            return None

        # Create root node
        _, root_name, root_type = parsed[0]
        root = SceneNode(name=root_name, type=root_type)

        if len(parsed) == 1:
            return root

        # Stack to track parent nodes at each level
        # (node, indent_level)
        stack: List[Tuple[SceneNode, int]] = [(root, parsed[0][0])]

        for indent, name, node_type in parsed[1:]:
            node = SceneNode(name=name, type=node_type)

            # Find parent: pop stack until we find a node with smaller indent
            while stack and stack[-1][1] >= indent:
                stack.pop()

            if stack:
                parent = stack[-1][0]
                parent.add_child(node)
            else:
                # This shouldn't happen with well-formed trees
                root.add_child(node)

            stack.append((node, indent))

        return root

    def parse_multiple_scenes(self, response: str) -> List[ParsedScene]:
        """
        Parse an AI response that might contain multiple scene definitions.

        Returns:
            List of ParsedScene objects
        """
        scenes = []

        # Look for scene section markers
        scene_markers = re.finditer(
            r'(?:###?\s*)?(?:Scene|File)[\s:]+[`"]?([A-Za-z0-9_/]+\.tscn)[`"]?',
            response,
            re.IGNORECASE
        )

        marker_positions = [(m.start(), m.group(1)) for m in scene_markers]

        if not marker_positions:
            # No explicit scenes, try to parse as single scene
            scene = self.parse(response)
            if scene:
                scenes.append(scene)
        else:
            # Parse each scene section
            for i, (pos, scene_path) in enumerate(marker_positions):
                end_pos = marker_positions[i + 1][0] if i + 1 < len(marker_positions) else len(response)
                section = response[pos:end_pos]

                scene = self.parse(section, scene_path)
                if scene:
                    scenes.append(scene)

        return scenes


def extract_node_comments(response: str) -> Dict[str, str]:
    """
    Extract explanatory comments for nodes from the AI response.

    Returns:
        Dict mapping node names to their descriptions
    """
    comments = {}

    # Pattern for node descriptions like "**NodeName:** description" or "- NodeName: description"
    patterns = [
        re.compile(r'\*\*([A-Za-z_][A-Za-z0-9_]*)\*\*[:\s]+(.+?)(?=\n|$)'),
        re.compile(r'[-*]\s*([A-Za-z_][A-Za-z0-9_]*)[:\s]+(.+?)(?=\n|$)'),
    ]

    for pattern in patterns:
        for match in pattern.finditer(response):
            name = match.group(1)
            desc = match.group(2).strip()
            if name not in comments:
                comments[name] = desc

    return comments


# Convenience function for skill usage
def parse_game_design_response(response: str) -> Optional[SceneNode]:
    """
    Parse a Game Design AI response and return the scene root.

    Args:
        response: The AI-generated game design document

    Returns:
        SceneNode root or None if no hierarchy found
    """
    parser = AIResponseParser()
    scene = parser.parse(response)
    return scene.root if scene else None
