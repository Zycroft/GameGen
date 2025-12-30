"""
Data models for GameGen scene nodes and properties.

Provides structured representations of Godot nodes that can be serialized
to DynamoDB and converted to .tscn format.
"""

from dataclasses import dataclass, field
from typing import Dict, List, Any, Optional
from enum import Enum


class NodeCategory(Enum):
    """Categories of Godot nodes for property mapping."""
    NODE_2D = "2d"
    CONTROL = "control"
    CONTAINER = "container"
    OTHER = "other"


# Node type classifications
NODE_2D_TYPES = {
    'Node2D', 'Sprite2D', 'AnimatedSprite2D', 'CharacterBody2D',
    'RigidBody2D', 'StaticBody2D', 'Area2D', 'Camera2D',
    'TileMap', 'TileMapLayer', 'Polygon2D', 'Line2D'
}

CONTAINER_TYPES = {
    'VBoxContainer', 'HBoxContainer', 'GridContainer',
    'FlowContainer', 'PanelContainer', 'MarginContainer',
    'CenterContainer', 'AspectRatioContainer',
    'HSplitContainer', 'VSplitContainer', 'TabContainer',
    'ScrollContainer', 'SubViewportContainer'
}

CONTROL_TYPES = {
    'Control', 'Panel', 'Button', 'Label', 'LineEdit', 'TextEdit',
    'CheckBox', 'CheckButton', 'OptionButton', 'MenuButton',
    'SpinBox', 'HSlider', 'VSlider', 'ProgressBar',
    'ColorRect', 'TextureRect', 'ColorPickerButton',
    'RichTextLabel', 'WindowDialog', 'ViewportContainer'
}


def get_node_category(node_type: str) -> NodeCategory:
    """Determine the category of a node type."""
    if node_type in NODE_2D_TYPES:
        return NodeCategory.NODE_2D
    elif node_type in CONTAINER_TYPES:
        return NodeCategory.CONTAINER
    elif node_type in CONTROL_TYPES:
        return NodeCategory.CONTROL
    return NodeCategory.OTHER


@dataclass
class NodeProperties:
    """Properties for a scene node."""
    position_x: float = 0.0
    position_y: float = 0.0
    size_x: float = 0.0
    size_y: float = 0.0
    min_size_x: float = 0.0
    min_size_y: float = 0.0
    scale_x: float = 1.0
    scale_y: float = 1.0

    # Content properties
    text: Optional[str] = None
    placeholder_text: Optional[str] = None
    color: Optional[str] = None  # Hex color like #RRGGBB
    texture: Optional[str] = None  # res:// path

    # Layout properties
    columns: Optional[int] = None
    alignment: Optional[int] = None
    separation: Optional[int] = None

    # Value properties (sliders, spinbox, progress)
    value: Optional[float] = None
    min_value: Optional[float] = None
    max_value: Optional[float] = None
    step: Optional[float] = None

    # Boolean properties
    button_pressed: Optional[bool] = None
    bbcode_enabled: Optional[bool] = None

    # Sprite properties
    hframes: Optional[int] = None
    vframes: Optional[int] = None
    frame: Optional[int] = None

    # Additional raw properties
    extra: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for DynamoDB storage."""
        result = {}

        # Position/size (use GameGen naming convention)
        if self.position_x != 0:
            result['positionX'] = self.position_x
        if self.position_y != 0:
            result['positionY'] = self.position_y
        if self.size_x != 0:
            result['sizeX'] = self.size_x
        if self.size_y != 0:
            result['sizeY'] = self.size_y
        if self.min_size_x != 0:
            result['minSizeX'] = self.min_size_x
        if self.min_size_y != 0:
            result['minSizeY'] = self.min_size_y
        if self.scale_x != 1:
            result['scaleX'] = self.scale_x
        if self.scale_y != 1:
            result['scaleY'] = self.scale_y

        # Content
        if self.text is not None:
            result['text'] = self.text
        if self.placeholder_text is not None:
            result['placeholder_text'] = self.placeholder_text
        if self.color is not None:
            result['color'] = self.color
        if self.texture is not None:
            result['texture'] = self.texture

        # Layout
        if self.columns is not None:
            result['columns'] = self.columns
        if self.alignment is not None:
            result['alignment'] = self.alignment
        if self.separation is not None:
            result['separation'] = self.separation

        # Values
        if self.value is not None:
            result['value'] = self.value
        if self.min_value is not None:
            result['min_value'] = self.min_value
        if self.max_value is not None:
            result['max_value'] = self.max_value
        if self.step is not None:
            result['step'] = self.step

        # Booleans
        if self.button_pressed is not None:
            result['button_pressed'] = self.button_pressed
        if self.bbcode_enabled is not None:
            result['bbcode_enabled'] = self.bbcode_enabled

        # Sprite
        if self.hframes is not None:
            result['hframes'] = self.hframes
        if self.vframes is not None:
            result['vframes'] = self.vframes
        if self.frame is not None:
            result['frame'] = self.frame

        # Extra properties
        result.update(self.extra)

        return result

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'NodeProperties':
        """Create from dictionary (e.g., from DynamoDB)."""
        known_keys = {
            'positionX', 'positionY', 'sizeX', 'sizeY',
            'minSizeX', 'minSizeY', 'scaleX', 'scaleY',
            'text', 'placeholder_text', 'color', 'texture',
            'columns', 'alignment', 'separation',
            'value', 'min_value', 'max_value', 'step',
            'button_pressed', 'bbcode_enabled',
            'hframes', 'vframes', 'frame'
        }

        extra = {k: v for k, v in data.items() if k not in known_keys}

        return cls(
            position_x=float(data.get('positionX', 0)),
            position_y=float(data.get('positionY', 0)),
            size_x=float(data.get('sizeX', 0)),
            size_y=float(data.get('sizeY', 0)),
            min_size_x=float(data.get('minSizeX', 0)),
            min_size_y=float(data.get('minSizeY', 0)),
            scale_x=float(data.get('scaleX', 1)),
            scale_y=float(data.get('scaleY', 1)),
            text=data.get('text'),
            placeholder_text=data.get('placeholder_text'),
            color=data.get('color'),
            texture=data.get('texture'),
            columns=data.get('columns'),
            alignment=data.get('alignment'),
            separation=data.get('separation'),
            value=data.get('value'),
            min_value=data.get('min_value'),
            max_value=data.get('max_value'),
            step=data.get('step'),
            button_pressed=data.get('button_pressed'),
            bbcode_enabled=data.get('bbcode_enabled'),
            hframes=data.get('hframes'),
            vframes=data.get('vframes'),
            frame=data.get('frame'),
            extra=extra
        )


# Global counter for generating unique IDs
_next_id = 1


def _generate_id() -> int:
    """Generate a unique node ID."""
    global _next_id
    node_id = _next_id
    _next_id += 1
    return node_id


def reset_id_counter(start: int = 1) -> None:
    """Reset the ID counter (useful for testing or new scenes)."""
    global _next_id
    _next_id = start


@dataclass
class SceneNode:
    """A node in the scene hierarchy."""
    name: str
    type: str
    id: int = field(default_factory=_generate_id)
    properties: NodeProperties = field(default_factory=NodeProperties)
    children: List['SceneNode'] = field(default_factory=list)
    widgets: List['SceneNode'] = field(default_factory=list)
    script: Optional[str] = None  # res:// path to script
    scene_path: Optional[str] = None  # For Scene nodes, the .tscn path

    @property
    def category(self) -> NodeCategory:
        """Get the node's category."""
        return get_node_category(self.type)

    def add_child(self, child: 'SceneNode') -> None:
        """Add a child node."""
        self.children.append(child)

    def add_widget(self, widget: 'SceneNode') -> None:
        """Add a widget node."""
        self.widgets.append(widget)

    def find_node(self, name: str) -> Optional['SceneNode']:
        """Find a node by name in the subtree."""
        if self.name == name:
            return self
        for child in self.children:
            found = child.find_node(name)
            if found:
                return found
        for widget in self.widgets:
            found = widget.find_node(name)
            if found:
                return found
        return None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for DynamoDB storage (GameGen format)."""
        result = {
            'name': self.name,
            'id': self.id,
            'type': self.type,
            'widgets': [widget.to_dict() for widget in self.widgets],
            'children': [child.to_dict() for child in self.children],
            'properties': self.properties.to_dict(),
        }

        if self.script:
            result['script'] = self.script

        if self.scene_path:
            result['_scenePath'] = self.scene_path

        return result

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'SceneNode':
        """Create from dictionary (e.g., from DynamoDB)."""
        props = NodeProperties.from_dict(data.get('properties', {}))

        # Use provided ID or generate a new one
        node_id = data.get('id')
        if node_id is not None:
            node = cls(
                name=data.get('name', 'Node'),
                type=data.get('type', 'Node2D'),
                id=node_id,
                properties=props,
                script=data.get('script'),
                scene_path=data.get('_scenePath')
            )
        else:
            node = cls(
                name=data.get('name', 'Node'),
                type=data.get('type', 'Node2D'),
                properties=props,
                script=data.get('script'),
                scene_path=data.get('_scenePath')
            )

        for child_data in data.get('children', []):
            node.children.append(cls.from_dict(child_data))

        for widget_data in data.get('widgets', []):
            node.widgets.append(cls.from_dict(widget_data))

        return node

    def __repr__(self) -> str:
        return f"SceneNode({self.name!r}, {self.type!r}, children={len(self.children)}, widgets={len(self.widgets)})"


@dataclass
class ParsedScene:
    """A parsed scene ready for export."""
    root: SceneNode
    scene_path: str  # Relative path like "Scenes/Main.tscn"

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            'sceneRoot': self.root.to_dict(),
            'scenePath': self.scene_path
        }
