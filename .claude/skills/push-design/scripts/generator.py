"""
Generate Godot .tscn scene files from GameGen scene data.

Converts SceneNode hierarchies to Godot 4.x text scene format.
"""

from pathlib import Path
from typing import Dict, List, Any, Optional
from models import SceneNode, NodeCategory, NODE_2D_TYPES, CONTAINER_TYPES, CONTROL_TYPES


class TscnGenerator:
    """Generate Godot .tscn scene files from SceneNode data."""

    # Default styles by panel type
    DEFAULT_STYLES = {
        'MenuBar': {'bg': '#252525', 'border': '#3a3a3a'},
        'StatusBar': {'bg': '#252525', 'border': '#3a3a3a'},
        'LeftToolbar': {'bg': '#2a2a2a', 'border': '#404040'},
        'RightToolbar': {'bg': '#2a2a2a', 'border': '#404040'},
        'PlaySpace': {'bg': '#1e1e1e', 'border': '#333333'},
        'DialogHost': {'bg': '#00000000', 'border': '#00000000'},
        'DialogStack': {'bg': '#00000000', 'border': '#00000000'},
        '_default': {'bg': '#2d2d2d', 'border': '#4a4a4a'},
    }

    def __init__(self):
        self.ext_resources: Dict[str, str] = {}  # path -> id
        self.resource_counter = 0
        self.sub_resources: Dict[str, Dict[str, Any]] = {}  # id -> style definition
        self.node_style_ids: Dict[int, str] = {}  # node.id -> sub_resource id
        self.sub_resource_counter = 0
        self.lines: List[str] = []

    def generate(self, root: SceneNode, scene_name: str = "main") -> str:
        """
        Generate .tscn content from a SceneNode hierarchy.

        Args:
            root: The root SceneNode
            scene_name: Name for the scene (used in resource IDs)

        Returns:
            The complete .tscn file content
        """
        self.ext_resources = {}
        self.resource_counter = 0
        self.sub_resources = {}
        self.node_style_ids = {}
        self.sub_resource_counter = 0
        self.lines = []

        # First pass: collect all external resources and sub_resources (styles)
        self._collect_resources(root)

        # Generate header (load_steps = ext_resources + sub_resources + 1)
        load_steps = len(self.ext_resources) + len(self.sub_resources) + 1
        self.lines.append(f'[gd_scene load_steps={load_steps} format=3]')
        self.lines.append('')

        # Generate external resource declarations
        for path, res_id in self.ext_resources.items():
            res_type = self._infer_resource_type(path)
            self.lines.append(f'[ext_resource type="{res_type}" path="{path}" id="{res_id}"]')

        if self.ext_resources:
            self.lines.append('')

        # Generate sub_resource declarations (StyleBoxFlat for panel styles)
        for res_id, style_def in self.sub_resources.items():
            self._generate_sub_resource(res_id, style_def)

        if self.sub_resources:
            self.lines.append('')

        # Generate node tree
        self._generate_node(root, None, None)

        return '\n'.join(self.lines)

    def _collect_resources(self, node: SceneNode) -> None:
        """Recursively collect all external resources (textures, scripts) and sub_resources (styles)."""
        props = node.properties

        # Texture resources
        if props.texture and props.texture.startswith('res://'):
            self._register_ext_resource(props.texture)

        # Script resources
        if node.script and node.script.startswith('res://'):
            self._register_ext_resource(node.script)

        # Style sub_resources for PanelContainer nodes
        if node.type == 'PanelContainer':
            self._register_style_resource(node)

        # Recurse into children
        for child in node.children:
            self._collect_resources(child)

        # Recurse into widgets
        for widget in node.widgets:
            self._collect_resources(widget)

    def _register_ext_resource(self, path: str) -> str:
        """Register an external resource and return its ID."""
        if path in self.ext_resources:
            return self.ext_resources[path]

        self.resource_counter += 1
        name = Path(path).stem
        res_id = f"{self.resource_counter}_{name}"
        self.ext_resources[path] = res_id
        return res_id

    def _infer_resource_type(self, path: str) -> str:
        """Infer resource type from file extension."""
        ext = Path(path).suffix.lower()
        type_map = {
            '.gd': 'Script',
            '.gdshader': 'Shader',
            '.png': 'Texture2D',
            '.jpg': 'Texture2D',
            '.jpeg': 'Texture2D',
            '.svg': 'Texture2D',
            '.webp': 'Texture2D',
            '.tres': 'Resource',
            '.tscn': 'PackedScene',
            '.wav': 'AudioStreamWAV',
            '.ogg': 'AudioStreamOggVorbis',
            '.mp3': 'AudioStreamMP3',
        }
        return type_map.get(ext, 'Resource')

    def _get_default_style(self, node_name: str) -> Dict[str, str]:
        """Get default style colors for a node by name."""
        return self.DEFAULT_STYLES.get(node_name, self.DEFAULT_STYLES['_default'])

    def _register_style_resource(self, node: SceneNode) -> Optional[str]:
        """Register a StyleBoxFlat sub_resource for a PanelContainer and return its ID."""
        props = node.properties
        default_style = self._get_default_style(node.name)

        # Use explicit properties or fall back to defaults
        bg_color = props.background_color or default_style['bg']
        border_color = props.border_color or default_style['border']
        border_width = props.border_width if props.border_width is not None else 1
        corner_radius = props.corner_radius if props.corner_radius is not None else 4

        # Generate unique ID
        self.sub_resource_counter += 1

        # Transparent panels use StyleBoxEmpty to override the default white background
        if bg_color == '#00000000' and border_color == '#00000000':
            res_id = f"StyleBoxEmpty_{node.name}_{self.sub_resource_counter}"
            self.sub_resources[res_id] = {
                'type': 'empty',
                'node_name': node.name
            }
        else:
            res_id = f"StyleBoxFlat_{node.name}_{self.sub_resource_counter}"
            self.sub_resources[res_id] = {
                'type': 'flat',
                'bg_color': self._parse_hex_color(bg_color),
                'border_color': self._parse_hex_color(border_color),
                'border_width': border_width,
                'corner_radius': corner_radius,
                'node_name': node.name
            }

        # Store mapping from node to style ID
        self.node_style_ids[node.id] = res_id

        return res_id

    def _generate_sub_resource(self, res_id: str, style_def: Dict[str, Any]) -> None:
        """Generate a [sub_resource] block for StyleBoxFlat or StyleBoxEmpty."""
        style_type = style_def.get('type', 'flat')

        if style_type == 'empty':
            # StyleBoxEmpty - completely transparent, no background
            self.lines.append(f'[sub_resource type="StyleBoxEmpty" id="{res_id}"]')
            self.lines.append('')
            return

        # StyleBoxFlat
        self.lines.append(f'[sub_resource type="StyleBoxFlat" id="{res_id}"]')

        # Background color (use 2 decimal places like working tscn files)
        bg = style_def.get('bg_color')
        if bg:
            self.lines.append(f'bg_color = Color({bg["r"]:.2f}, {bg["g"]:.2f}, {bg["b"]:.2f}, {bg["a"]:.2f})')

        # Border width (all sides)
        width = style_def.get('border_width', 0)
        if width > 0:
            self.lines.append(f'border_width_left = {width}')
            self.lines.append(f'border_width_top = {width}')
            self.lines.append(f'border_width_right = {width}')
            self.lines.append(f'border_width_bottom = {width}')

            # Border color (only if border width > 0)
            border = style_def.get('border_color')
            if border:
                self.lines.append(f'border_color = Color({border["r"]:.2f}, {border["g"]:.2f}, {border["b"]:.2f}, {border["a"]:.2f})')

        # Corner radius (all corners)
        radius = style_def.get('corner_radius', 0)
        if radius > 0:
            self.lines.append(f'corner_radius_top_left = {radius}')
            self.lines.append(f'corner_radius_top_right = {radius}')
            self.lines.append(f'corner_radius_bottom_right = {radius}')
            self.lines.append(f'corner_radius_bottom_left = {radius}')

        self.lines.append('')  # Blank line after sub_resource

    def _generate_node(self, node: SceneNode, parent_path: Optional[str], parent_type: Optional[str] = None) -> None:
        """Generate node declaration and properties."""
        node_type = node.type

        # Convert virtual Scene type to Node2D
        if node_type == 'Scene':
            node_type = 'Node2D'

        # Build node header
        if parent_path is None:
            header = f'[node name="{node.name}" type="{node_type}"]'
        else:
            header = f'[node name="{node.name}" type="{node_type}" parent="{parent_path}"]'

        self.lines.append(header)

        # Add script if present
        if node.script and node.script in self.ext_resources:
            script_id = self.ext_resources[node.script]
            self.lines.append(f'script = ExtResource("{script_id}")')

        # Add properties (pass parent_type for layout decisions)
        props = self._map_properties(node, parent_type)
        for key, value in props.items():
            formatted = self._format_value(key, value)
            self.lines.append(f'{key} = {formatted}')

        self.lines.append('')  # Blank line after node

        # Calculate child parent path
        if parent_path is None:
            child_parent = '.'
        elif parent_path == '.':
            child_parent = node.name
        else:
            child_parent = f'{parent_path}/{node.name}'

        # Process children (pass current node type as parent_type)
        for child in node.children:
            self._generate_node(child, child_parent, node_type)

        # Process widgets (they're children in Godot)
        for widget in node.widgets:
            self._generate_node(widget, child_parent, node_type)

    def _map_properties(self, node: SceneNode, parent_type: Optional[str] = None) -> Dict[str, Any]:
        """Map SceneNode properties to Godot .tscn format."""
        props = node.properties
        result = {}

        # Position handling based on node type
        is_2d = node.type in NODE_2D_TYPES
        is_control = node.type in CONTROL_TYPES or node.type in CONTAINER_TYPES
        is_container = node.type in CONTAINER_TYPES
        parent_is_container = parent_type in CONTAINER_TYPES if parent_type else False

        if is_2d:
            # 2D nodes use position property
            if props.position_x != 0 or props.position_y != 0:
                result['position'] = {'type': 'Vector2', 'x': props.position_x, 'y': props.position_y}
        elif is_control:
            # Check for layout mode from extra properties
            layout_mode = props.extra.get('layout_mode')
            full_rect = props.extra.get('full_rect', False)

            # ModalBlocker is special - always hidden and transparent
            if node.name == 'ModalBlocker':
                result['visible'] = False
                result['color'] = {'type': 'Color', 'r': 0.0, 'g': 0.0, 'b': 0.0, 'a': 0.0}
                if parent_is_container:
                    result['layout_mode'] = 2
                    result['size_flags_horizontal'] = 3
                    result['size_flags_vertical'] = 3
            # If parent is a container, use layout_mode 2 (container child)
            elif parent_is_container:
                result['layout_mode'] = 2

                # Use extracted size flags, or infer from node name/type
                h_flags = props.extra.get('size_flags_horizontal')
                v_flags = props.extra.get('size_flags_vertical')

                # Default inference based on common patterns
                if h_flags is None:
                    # Toolbars in HBox should not expand horizontally (use min width)
                    if 'Toolbar' in node.name:
                        h_flags = 1  # Fill only
                    else:
                        h_flags = 3  # Fill + Expand

                if v_flags is None:
                    # MenuBar and StatusBar should not expand vertically
                    if node.name in ('MenuBar', 'StatusBar') or 'Bar' in node.name:
                        v_flags = 1  # Fill only
                    else:
                        v_flags = 3  # Fill + Expand

                result['size_flags_horizontal'] = h_flags
                result['size_flags_vertical'] = v_flags

                # Add minimum sizes from properties or defaults
                min_x = props.min_size_x
                min_y = props.min_size_y

                # Default minimum sizes if not specified
                if min_x == 0 and 'Toolbar' in node.name:
                    min_x = 200
                if min_y == 0 and node.name == 'MenuBar':
                    min_y = 30
                if min_y == 0 and node.name == 'StatusBar':
                    min_y = 20

                if min_x != 0 or min_y != 0:
                    result['custom_minimum_size'] = {'type': 'Vector2', 'x': min_x, 'y': min_y}
            # Root controls or controls needing full rect use anchors
            elif full_rect or node.name in ('Root', 'ScreenStack', 'DialogHost', 'GameView', 'DialogStack'):
                parent_is_2d = parent_type in NODE_2D_TYPES if parent_type else False
                if parent_is_2d:
                    # Controls under Node2D can't use anchors - anchors only work with Control parents
                    # Just set explicit size to fill the default viewport (1152x648)
                    # Don't use anchors - they conflict with explicit size in Godot 4
                    result['size'] = {'type': 'Vector2', 'x': 1152, 'y': 648}
                else:
                    # Parent is Control - use layout_mode 1 (anchors)
                    result['layout_mode'] = 1
                    result['anchors_preset'] = 15  # PRESET_FULL_RECT
                    result['anchor_left'] = 0.0
                    result['anchor_top'] = 0.0
                    result['anchor_right'] = 1.0
                    result['anchor_bottom'] = 1.0
                    result['grow_horizontal'] = 2
                    result['grow_vertical'] = 2
                    result['offset_left'] = 0.0
                    result['offset_top'] = 0.0
                    result['offset_right'] = 0.0
                    result['offset_bottom'] = 0.0
            else:
                # Regular control with offset positioning
                if props.position_x != 0:
                    result['offset_left'] = float(props.position_x)
                if props.position_y != 0:
                    result['offset_top'] = float(props.position_y)
                if props.size_x != 0:
                    result['offset_right'] = float(props.position_x + props.size_x)
                if props.size_y != 0:
                    result['offset_bottom'] = float(props.position_y + props.size_y)

        # Custom minimum size
        if props.min_size_x != 0 or props.min_size_y != 0:
            result['custom_minimum_size'] = {
                'type': 'Vector2',
                'x': props.min_size_x,
                'y': props.min_size_y
            }

        # Scale
        if props.scale_x != 1 or props.scale_y != 1:
            result['scale'] = {'type': 'Vector2', 'x': props.scale_x, 'y': props.scale_y}

        # Texture handling
        if props.texture and props.texture in self.ext_resources:
            result['texture'] = {
                'type': 'ExtResource',
                'id': self.ext_resources[props.texture]
            }

        # Text properties
        if props.text is not None:
            result['text'] = props.text

        if props.placeholder_text is not None:
            result['placeholder_text'] = props.placeholder_text

        # Color properties (convert from #RRGGBB to Color)
        if props.color:
            color = self._parse_hex_color(props.color)
            if color:
                result['color'] = color

        # Layout properties
        if props.columns is not None:
            result['columns'] = int(props.columns)

        if props.alignment is not None:
            result['alignment'] = int(props.alignment)

        if props.separation is not None:
            result['theme_override_constants/separation'] = int(props.separation)

        # Value properties
        if props.value is not None:
            result['value'] = float(props.value)
        if props.min_value is not None:
            result['min_value'] = float(props.min_value)
        if props.max_value is not None:
            result['max_value'] = float(props.max_value)
        if props.step is not None:
            result['step'] = float(props.step)

        # Boolean properties
        if props.button_pressed is not None:
            result['button_pressed'] = props.button_pressed
        if props.bbcode_enabled is not None:
            result['bbcode_enabled'] = props.bbcode_enabled

        # Sprite frame properties
        if props.hframes is not None:
            result['hframes'] = int(props.hframes)
        if props.vframes is not None:
            result['vframes'] = int(props.vframes)
        if props.frame is not None:
            result['frame'] = int(props.frame)

        # Extra properties (pass through)
        for key, value in props.extra.items():
            result[key] = value

        # Panel style (theme override for PanelContainer)
        if node.type == 'PanelContainer' and node.id in self.node_style_ids:
            style_id = self.node_style_ids[node.id]
            result['theme_override_styles/panel'] = {
                'type': 'SubResource',
                'id': style_id
            }

        return result

    def _parse_hex_color(self, hex_color: str) -> Optional[Dict[str, Any]]:
        """Parse hex color to Godot Color dict."""
        if not isinstance(hex_color, str) or not hex_color.startswith('#'):
            return None

        hex_color = hex_color.lstrip('#')
        try:
            r = int(hex_color[0:2], 16) / 255.0
            g = int(hex_color[2:4], 16) / 255.0
            b = int(hex_color[4:6], 16) / 255.0
            a = 1.0
            if len(hex_color) >= 8:
                a = int(hex_color[6:8], 16) / 255.0
            return {'type': 'Color', 'r': r, 'g': g, 'b': b, 'a': a}
        except (ValueError, IndexError):
            return None

    def _format_value(self, key: str, value: Any) -> str:
        """Format a value for .tscn output."""
        if isinstance(value, bool):
            return 'true' if value else 'false'
        elif isinstance(value, str):
            # Escape quotes in strings
            escaped = value.replace('\\', '\\\\').replace('"', '\\"')
            return f'"{escaped}"'
        elif isinstance(value, (int, float)):
            if isinstance(value, float):
                return f'{value:.6g}'
            return str(value)
        elif isinstance(value, dict):
            val_type = value.get('type')
            if val_type == 'Vector2':
                return f'Vector2({value["x"]}, {value["y"]})'
            elif val_type == 'Vector2i':
                return f'Vector2i({int(value["x"])}, {int(value["y"])})'
            elif val_type == 'Color':
                return f'Color({value["r"]:.3f}, {value["g"]:.3f}, {value["b"]:.3f}, {value["a"]:.3f})'
            elif val_type == 'ExtResource':
                return f'ExtResource("{value["id"]}")'
            elif val_type == 'SubResource':
                return f'SubResource("{value["id"]}")'
        return str(value)


def generate_tscn(root: SceneNode, scene_name: str = "main") -> str:
    """
    Convenience function to generate .tscn content.

    Args:
        root: The root SceneNode
        scene_name: Name for the scene

    Returns:
        The .tscn file content
    """
    generator = TscnGenerator()
    return generator.generate(root, scene_name)


def generate_project_godot(project_name: str, main_scene: str = "Scenes/Main.tscn") -> str:
    """
    Generate a project.godot file content.

    Args:
        project_name: Name of the project
        main_scene: Path to the main scene

    Returns:
        The project.godot file content
    """
    return f'''; Engine configuration file.
; It's best edited using the editor UI and not directly,
; since the parameters that go here are not all obvious.
;
; Format:
;   [section] ; section goes between []
;   param=value ; assign values to parameters

config_version=5

[application]

config/name="{project_name}"
run/main_scene="res://{main_scene}"
config/features=PackedStringArray("4.5")

[display]

window/size/viewport_width=1152
window/size/viewport_height=648
'''
