"""
Parser for extracting scene hierarchies from AI-generated Game Design responses.

Handles various formats:
- ASCII tree diagrams with box-drawing characters
- Markdown-style hierarchies
- Indented text hierarchies

Also extracts positioning and sizing information from descriptive text.
"""

import re
from typing import List, Optional, Tuple, Dict, Any, Set
from models import SceneNode, NodeProperties, ParsedScene


class NodePropertyExtractor:
    """Extract position and size properties from AI response text."""

    # Default screen dimensions
    SCREEN_WIDTH = 1920
    SCREEN_HEIGHT = 1080

    # Pattern for height: ~80 px, 80px, 80 px, ~80px
    HEIGHT_PATTERN = re.compile(
        r'\*?\*?Height\*?\*?[:\s]+~?(\d+)\s*(?:px|pixels?)?',
        re.IGNORECASE
    )

    # Pattern for width: ~240 px, 240px, etc.
    WIDTH_PATTERN = re.compile(
        r'\*?\*?Width\*?\*?[:\s]+~?(\d+)\s*(?:px|pixels?)?',
        re.IGNORECASE
    )

    # Pattern for size: ~900×700, 900x700, 900×700
    SIZE_PATTERN = re.compile(
        r'\*?\*?(?:size|dimensions?)\*?\*?[:\s]+~?(\d+)\s*[×xX]\s*~?(\d+)',
        re.IGNORECASE
    )

    # Pattern for minimum size
    MIN_SIZE_PATTERN = re.compile(
        r'(?:custom_)?minimum_size[:\s=]+(?:Vector2\()?\s*~?(\d+)\s*[,×xX]\s*~?(\d+)',
        re.IGNORECASE
    )

    # Pattern for position
    POSITION_PATTERN = re.compile(
        r'position[:\s=]+(?:Vector2\()?\s*~?(-?\d+)\s*[,]\s*~?(-?\d+)',
        re.IGNORECASE
    )

    # Pattern for percentage of screen (e.g., "≈ 12–15% of 1920")
    PERCENT_WIDTH_PATTERN = re.compile(
        r'(\d+)(?:[–-]\d+)?%\s*of\s*(?:screen\s*)?(?:width|1920)',
        re.IGNORECASE
    )

    PERCENT_HEIGHT_PATTERN = re.compile(
        r'(\d+)(?:[–-]\d+)?%\s*of\s*(?:screen\s*)?(?:height|1080)',
        re.IGNORECASE
    )

    # Pattern for separation/spacing
    SEPARATION_PATTERN = re.compile(
        r'(?:Separation|spacing)[:\s]+~?(\d+)\s*(?:px)?',
        re.IGNORECASE
    )

    # Pattern for size flags: "Size Flags: Horizontal: Fill + Expand, Vertical: Fill"
    SIZE_FLAGS_H_PATTERN = re.compile(
        r'(?:Size\s*Flags|Horizontal)[:\s]*(?:Horizontal[:\s]*)?(Fill(?:\s*\+?\s*Expand)?)',
        re.IGNORECASE
    )

    SIZE_FLAGS_V_PATTERN = re.compile(
        r'Vertical[:\s]*(Fill(?:\s*\+?\s*Expand)?)',
        re.IGNORECASE
    )

    # Pattern for Layout -> Full Rect
    FULL_RECT_PATTERN = re.compile(
        r'Layout\s*[→:]\s*Full\s*Rect',
        re.IGNORECASE
    )

    # Layout position keywords
    LAYOUT_KEYWORDS = {
        'top': ['top', 'upper', 'header', 'menu', 'navbar', 'topmenu', 'menubar'],
        'bottom': ['bottom', 'lower', 'footer', 'status', 'statusbar', 'bottomstatus'],
        'left': ['left', 'lefttool', 'leftbar', 'leftpanel', 'sidebar'],
        'right': ['right', 'righttool', 'rightbar', 'rightpanel'],
        'center': ['center', 'middle', 'main', 'play', 'playarea', 'content', 'slot'],
    }

    def __init__(self, response: str):
        self.response = response
        self._node_sections = self._split_into_sections()
        self._layout_info: Dict[str, Dict[str, Any]] = {}  # Cache for layout calculations

    def _split_into_sections(self) -> Dict[str, str]:
        """
        Split response into sections for each node.
        Returns dict mapping node names to their descriptive text.
        """
        sections = {}

        # Pattern to match node section headers like:
        # ### TopMenuBar (PanelContainer)
        # **TopMenuBar**
        # #### LeftToolBar (PanelContainer)
        section_pattern = re.compile(
            r'^(?:#{2,4}\s+|\*\*)?'
            r'([A-Za-z_][A-Za-z0-9_]*)'
            r'(?:\*\*)?'
            r'\s*[\(\[]?([A-Za-z][A-Za-z0-9]*)?[\)\]]?',
            re.MULTILINE
        )

        matches = list(section_pattern.finditer(self.response))

        for i, match in enumerate(matches):
            node_name = match.group(1)
            start = match.start()
            end = matches[i + 1].start() if i + 1 < len(matches) else len(self.response)
            section_text = self.response[start:end]
            sections[node_name] = section_text

        return sections

    def get_properties(self, node_name: str) -> NodeProperties:
        """
        Extract properties for a specific node from the response.
        """
        props = NodeProperties()

        # Get the section for this node
        section = self._node_sections.get(node_name, "")

        # Also search the full response for node-specific mentions
        # like "TopMenuBar - Height: ~80 px"
        node_mention_pattern = re.compile(
            rf'{re.escape(node_name)}[^.\n]*',
            re.IGNORECASE
        )
        mentions = node_mention_pattern.findall(self.response)
        full_text = section + "\n" + "\n".join(mentions)

        # Extract height
        height_match = self.HEIGHT_PATTERN.search(full_text)
        if height_match:
            props.size_y = float(height_match.group(1))
            # If only height specified, set min_size_y too
            props.min_size_y = props.size_y

        # Extract width
        width_match = self.WIDTH_PATTERN.search(full_text)
        if width_match:
            props.size_x = float(width_match.group(1))
            props.min_size_x = props.size_x

        # Extract size (width×height)
        size_match = self.SIZE_PATTERN.search(full_text)
        if size_match:
            props.size_x = float(size_match.group(1))
            props.size_y = float(size_match.group(2))
            props.min_size_x = props.size_x
            props.min_size_y = props.size_y

        # Extract minimum size
        min_size_match = self.MIN_SIZE_PATTERN.search(full_text)
        if min_size_match:
            props.min_size_x = float(min_size_match.group(1))
            props.min_size_y = float(min_size_match.group(2))

        # Extract position
        pos_match = self.POSITION_PATTERN.search(full_text)
        if pos_match:
            props.position_x = float(pos_match.group(1))
            props.position_y = float(pos_match.group(2))

        # Extract separation for containers
        sep_match = self.SEPARATION_PATTERN.search(full_text)
        if sep_match:
            props.separation = int(sep_match.group(1))

        # Extract size flags (Fill = 1, Fill + Expand = 3)
        h_flag_match = self.SIZE_FLAGS_H_PATTERN.search(full_text)
        if h_flag_match:
            flag_text = h_flag_match.group(1).lower()
            if 'expand' in flag_text:
                props.extra['size_flags_horizontal'] = 3  # Fill + Expand
            else:
                props.extra['size_flags_horizontal'] = 1  # Fill only

        v_flag_match = self.SIZE_FLAGS_V_PATTERN.search(full_text)
        if v_flag_match:
            flag_text = v_flag_match.group(1).lower()
            if 'expand' in flag_text:
                props.extra['size_flags_vertical'] = 3  # Fill + Expand
            else:
                props.extra['size_flags_vertical'] = 1  # Fill only

        # Check for Full Rect layout
        if self.FULL_RECT_PATTERN.search(full_text):
            props.extra['full_rect'] = True

        # Calculate from percentage if explicit size not found
        if props.size_x == 0:
            pct_match = self.PERCENT_WIDTH_PATTERN.search(full_text)
            if pct_match:
                pct = float(pct_match.group(1))
                props.size_x = 1920 * (pct / 100)
                props.min_size_x = props.size_x

        if props.size_y == 0:
            pct_match = self.PERCENT_HEIGHT_PATTERN.search(full_text)
            if pct_match:
                pct = float(pct_match.group(1))
                props.size_y = 1080 * (pct / 100)
                props.min_size_y = props.size_y

        return props

    def _detect_layout_role(self, node_name: str) -> Optional[str]:
        """
        Detect the layout role (top, bottom, left, right, center) from node name.
        """
        name_lower = node_name.lower()

        for role, keywords in self.LAYOUT_KEYWORDS.items():
            for keyword in keywords:
                if keyword in name_lower:
                    return role
        return None

    def _collect_layout_info(self, node: SceneNode, parent_info: Optional[Dict] = None) -> None:
        """
        First pass: collect sizes and detect layout roles for all nodes.
        """
        extracted = self.get_properties(node.name)
        role = self._detect_layout_role(node.name)

        # Store layout info for this node
        self._layout_info[node.name] = {
            'role': role,
            'size_x': extracted.size_x if extracted.size_x != 0 else node.properties.size_x,
            'size_y': extracted.size_y if extracted.size_y != 0 else node.properties.size_y,
            'min_size_x': extracted.min_size_x,
            'min_size_y': extracted.min_size_y,
            'children': [c.name for c in node.children],
            'extracted': extracted,
        }

        # Recurse
        for child in node.children:
            self._collect_layout_info(child, self._layout_info[node.name])
        for widget in node.widgets:
            self._collect_layout_info(widget, self._layout_info[node.name])

    def _calculate_positions(self, node: SceneNode,
                             available_x: float = 0, available_y: float = 0,
                             available_width: float = None, available_height: float = None) -> None:
        """
        Second pass: calculate positions based on layout roles and siblings.
        """
        if available_width is None:
            available_width = self.SCREEN_WIDTH
        if available_height is None:
            available_height = self.SCREEN_HEIGHT

        info = self._layout_info.get(node.name, {})
        extracted = info.get('extracted', NodeProperties())

        # Apply extracted sizes first
        if extracted.size_x != 0:
            node.properties.size_x = extracted.size_x
        if extracted.size_y != 0:
            node.properties.size_y = extracted.size_y
        if extracted.min_size_x != 0:
            node.properties.min_size_x = extracted.min_size_x
        if extracted.min_size_y != 0:
            node.properties.min_size_y = extracted.min_size_y
        if extracted.separation is not None:
            node.properties.separation = extracted.separation

        # Apply extracted layout properties (size flags, full_rect)
        if 'size_flags_horizontal' in extracted.extra:
            node.properties.extra['size_flags_horizontal'] = extracted.extra['size_flags_horizontal']
        if 'size_flags_vertical' in extracted.extra:
            node.properties.extra['size_flags_vertical'] = extracted.extra['size_flags_vertical']
        if extracted.extra.get('full_rect'):
            node.properties.extra['full_rect'] = True

        # Apply explicit position if found
        if extracted.position_x != 0:
            node.properties.position_x = extracted.position_x
        if extracted.position_y != 0:
            node.properties.position_y = extracted.position_y

        # Group children by layout role
        children_by_role: Dict[str, List[SceneNode]] = {
            'top': [], 'bottom': [], 'left': [], 'right': [], 'center': [], 'other': []
        }

        for child in node.children:
            child_info = self._layout_info.get(child.name, {})
            role = child_info.get('role') or 'other'
            if role not in children_by_role:
                role = 'other'
            children_by_role[role].append(child)

        # Calculate layout dimensions
        top_height = sum(
            self._layout_info.get(c.name, {}).get('size_y', 80) or 80
            for c in children_by_role['top']
        )
        bottom_height = sum(
            self._layout_info.get(c.name, {}).get('size_y', 70) or 70
            for c in children_by_role['bottom']
        )
        left_width = sum(
            self._layout_info.get(c.name, {}).get('size_x', 200) or 200
            for c in children_by_role['left']
        )
        right_width = sum(
            self._layout_info.get(c.name, {}).get('size_x', 200) or 200
            for c in children_by_role['right']
        )

        # Middle area dimensions
        middle_y = top_height
        middle_height = available_height - top_height - bottom_height
        middle_x = left_width
        middle_width = available_width - left_width - right_width

        # Position top children
        current_y = 0
        for child in children_by_role['top']:
            child_info = self._layout_info.get(child.name, {})
            child_height = child_info.get('size_y', 80) or 80
            child.properties.position_x = 0
            child.properties.position_y = current_y
            child.properties.size_x = available_width
            child.properties.size_y = child_height
            self._calculate_positions(child, 0, current_y, available_width, child_height)
            current_y += child_height

        # Position bottom children
        current_y = available_height
        for child in reversed(children_by_role['bottom']):
            child_info = self._layout_info.get(child.name, {})
            child_height = child_info.get('size_y', 70) or 70
            current_y -= child_height
            child.properties.position_x = 0
            child.properties.position_y = current_y
            child.properties.size_x = available_width
            child.properties.size_y = child_height
            self._calculate_positions(child, 0, current_y, available_width, child_height)

        # Position left children
        current_x = 0
        for child in children_by_role['left']:
            child_info = self._layout_info.get(child.name, {})
            child_width = child_info.get('size_x', 200) or 200
            child.properties.position_x = current_x
            child.properties.position_y = middle_y
            child.properties.size_x = child_width
            child.properties.size_y = middle_height
            self._calculate_positions(child, current_x, middle_y, child_width, middle_height)
            current_x += child_width

        # Position right children
        current_x = available_width
        for child in reversed(children_by_role['right']):
            child_info = self._layout_info.get(child.name, {})
            child_width = child_info.get('size_x', 200) or 200
            current_x -= child_width
            child.properties.position_x = current_x
            child.properties.position_y = middle_y
            child.properties.size_x = child_width
            child.properties.size_y = middle_height
            self._calculate_positions(child, current_x, middle_y, child_width, middle_height)

        # Position center children
        for child in children_by_role['center']:
            child_info = self._layout_info.get(child.name, {})
            child_width = child_info.get('size_x', 0) or middle_width
            child_height = child_info.get('size_y', 0) or middle_height
            # Center the child in the middle area
            child.properties.position_x = middle_x + (middle_width - child_width) / 2
            child.properties.position_y = middle_y + (middle_height - child_height) / 2
            child.properties.size_x = child_width
            child.properties.size_y = child_height
            self._calculate_positions(child, child.properties.position_x, child.properties.position_y,
                                      child_width, child_height)

        # Position other children (no specific layout role)
        for child in children_by_role['other']:
            child_info = self._layout_info.get(child.name, {})
            # If no role detected, position in center area
            child_width = child_info.get('size_x', 0) or 200
            child_height = child_info.get('size_y', 0) or 200
            child.properties.position_x = middle_x
            child.properties.position_y = middle_y
            if child.properties.size_x == 0:
                child.properties.size_x = child_width
            if child.properties.size_y == 0:
                child.properties.size_y = child_height
            self._calculate_positions(child, middle_x, middle_y, middle_width, middle_height)

        # Handle widgets similarly
        for widget in node.widgets:
            self._calculate_positions(widget, available_x, available_y, available_width, available_height)

    def apply_to_tree(self, root: SceneNode) -> None:
        """
        Apply extracted properties to all nodes in the tree.
        Uses a two-pass approach:
        1. Collect sizes and detect layout roles
        2. Calculate positions based on layout
        """
        # First pass: collect layout info
        self._layout_info = {}
        self._collect_layout_info(root)

        # Second pass: calculate and apply positions
        self._calculate_positions(root)


class MermaidParser:
    """Parse mermaid graph TD format into scene hierarchies."""

    # Pattern for mermaid node definitions: A[NodeName<br/>NodeType]
    MERMAID_NODE_PATTERN = re.compile(
        r'([A-Za-z_][A-Za-z0-9_]*)\[([^<\]]+)(?:<br/>|\s*\n\s*)([^\]]+)\]'
    )

    # Pattern for mermaid edges: A --> B or A[...] --> B
    MERMAID_EDGE_PATTERN = re.compile(
        r'([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?\s*-->\s*([A-Za-z_][A-Za-z0-9_]*)'
    )

    # Known Godot types for validation
    KNOWN_TYPES = {
        'Node', 'Node2D', 'Sprite2D', 'AnimatedSprite2D', 'CharacterBody2D',
        'RigidBody2D', 'StaticBody2D', 'Area2D', 'Camera2D', 'TileMap',
        'Control', 'Panel', 'Button', 'Label', 'LineEdit', 'TextEdit',
        'VBoxContainer', 'HBoxContainer', 'GridContainer', 'FlowContainer',
        'PanelContainer', 'MarginContainer', 'CenterContainer',
        'AspectRatioContainer', 'HSplitContainer', 'VSplitContainer',
        'TabContainer', 'ScrollContainer', 'ColorRect', 'TextureRect',
        'SubViewportContainer', 'CanvasLayer'
    }

    # Type aliases for abstract/deprecated types
    TYPE_ALIASES = {
        'CanvasItem': 'Control',  # CanvasItem is abstract, use Control
        'WindowDialog': 'Control',  # Deprecated in Godot 4.x
        'Sprite': 'Sprite2D',
        'AnimatedSprite': 'AnimatedSprite2D',
    }

    def parse(self, mermaid_text: str) -> Optional[SceneNode]:
        """Parse mermaid graph TD text into a scene hierarchy."""
        # Extract node definitions
        nodes = {}  # id -> (name, type)
        for match in self.MERMAID_NODE_PATTERN.finditer(mermaid_text):
            node_id = match.group(1)
            raw_name = match.group(2).strip()
            raw_type = match.group(3).strip()

            # Clean up the name (remove .tscn suffix etc)
            name = raw_name.replace('.tscn', '').strip()

            # Extract type from strings like "Control (Full Rect)" or "Node2D or Control"
            node_type = self._extract_type(raw_type)

            if name and node_type:
                nodes[node_id] = (name, node_type)

        if not nodes:
            return None

        # Extract edges (parent -> child relationships)
        edges = []
        for match in self.MERMAID_EDGE_PATTERN.finditer(mermaid_text):
            parent_id = match.group(1)
            child_id = match.group(2)
            if parent_id in nodes and child_id in nodes:
                edges.append((parent_id, child_id))

        if not edges:
            return None

        # Find root (node with no parent)
        all_children = {e[1] for e in edges}
        all_parents = {e[0] for e in edges}
        roots = all_parents - all_children

        if not roots:
            # Use first node as root
            roots = {list(nodes.keys())[0]}

        root_id = list(roots)[0]

        # Build tree
        return self._build_tree(root_id, nodes, edges)

    def _extract_type(self, type_str: str) -> Optional[str]:
        """Extract a valid Godot type from a type string."""
        # Handle "Node2D or Control" - take first valid type
        type_str = type_str.split('(')[0].strip()  # Remove parenthetical

        for word in type_str.replace(' or ', ' ').split():
            word = word.strip()
            # Check aliases first
            if word in self.TYPE_ALIASES:
                return self.TYPE_ALIASES[word]
            if word in self.KNOWN_TYPES:
                return word

        # Try to find any known type or alias in the string
        for alias, replacement in self.TYPE_ALIASES.items():
            if alias in type_str:
                return replacement
        for known in self.KNOWN_TYPES:
            if known in type_str:
                return known

        return None

    def _build_tree(self, node_id: str, nodes: Dict[str, Tuple[str, str]],
                    edges: List[Tuple[str, str]]) -> SceneNode:
        """Build scene tree from node definitions and edges."""
        name, node_type = nodes[node_id]
        node = SceneNode(name=name, type=node_type)

        # Find children
        for parent_id, child_id in edges:
            if parent_id == node_id:
                child_node = self._build_tree(child_id, nodes, edges)
                node.add_child(child_node)

        return node


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

    def parse(self, response: str, default_scene_path: str = "Scenes/Main.tscn",
              extract_properties: bool = True) -> Optional[ParsedScene]:
        """
        Parse an AI response and extract the scene hierarchy.

        Args:
            response: The AI-generated text containing scene structure
            default_scene_path: Default path for the scene file
            extract_properties: Whether to extract position/size from text

        Returns:
            ParsedScene if a hierarchy was found, None otherwise
        """
        # Try to find and parse a tree structure
        root = self._extract_tree(response)

        if root:
            # Extract and apply position/size properties from the response text
            if extract_properties:
                extractor = NodePropertyExtractor(response)
                extractor.apply_to_tree(root)

            return ParsedScene(root=root, scene_path=default_scene_path)

        return None

    def _extract_tree(self, text: str) -> Optional[SceneNode]:
        """Extract a tree structure from text."""
        # First, try to find and parse mermaid graph
        mermaid_result = self._try_mermaid_parse(text)
        if mermaid_result:
            return mermaid_result

        # Fall back to ASCII tree parsing
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

    def _try_mermaid_parse(self, text: str) -> Optional[SceneNode]:
        """Try to parse mermaid graph TD format from the text."""
        # Find mermaid code blocks
        mermaid_pattern = re.compile(r'```mermaid\n(.*?)```', re.DOTALL)
        matches = mermaid_pattern.findall(text)

        for mermaid_text in matches:
            # Check if it's a graph TD (tree diagram)
            if 'graph TD' in mermaid_text or 'graph LR' in mermaid_text:
                parser = MermaidParser()
                result = parser.parse(mermaid_text)
                if result:
                    return result

        return None

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
