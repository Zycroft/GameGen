# Controls toolbar panel - provides categorized buttons for spawning containers
# (VBox, HBox, Grid, etc.) and UI widgets into the scene.
class_name ControlsPanel
extends Panel

signal node_spawn_requested(node_type: String)

var dragging := false
var drag_offset := Vector2.ZERO

# Resizing
var resizing := false
var resize_direction := Vector2.ZERO
var min_size := Vector2(180, 200)
var resize_margin := 12

# Minimize/restore
var minimized := false
var restored_size := Vector2.ZERO
var title_bar_height := 28.0

# Node categories and types
const NODE_CATEGORIES := {
	"Scenes": ["Scene"],
	"2D Nodes": ["Node2D", "Sprite2D", "AnimatedSprite2D", "CanvasLayer", "Control"],
	"Containers": ["VBoxContainer", "HBoxContainer", "GridContainer",
				   "FlowContainer", "MarginContainer", "PanelContainer",
				   "CenterContainer", "AspectRatioContainer", "HSplitContainer",
				   "VSplitContainer", "TabContainer"],
	"UI Widgets": ["Button", "Label", "LineEdit", "TextEdit", "CheckBox",
				   "CheckButton", "OptionButton", "SpinBox", "HSlider",
				   "VSlider", "ProgressBar", "ColorRect", "TextureRect",
				   "ColorPickerButton", "RichTextLabel"],
	"Animation": ["AnimationPlayer"]
}

const NODE_COLORS := {
	# Scenes
	"Scene": Color(0.9, 0.7, 0.2),
	# 2D Nodes
	"Node2D": Color(0.4, 0.7, 0.4),
	"Sprite2D": Color(0.5, 0.8, 0.5),
	"AnimatedSprite2D": Color(0.4, 0.9, 0.6),
	"CanvasLayer": Color(0.7, 0.5, 0.9),
	"Control": Color(0.3, 0.5, 0.7),
	# Containers
	"VBoxContainer": Color(0.8, 0.3, 0.3),
	"HBoxContainer": Color(0.3, 0.6, 0.8),
	"GridContainer": Color(0.3, 0.7, 0.4),
	"FlowContainer": Color(0.7, 0.5, 0.8),
	"MarginContainer": Color(0.8, 0.6, 0.3),
	"PanelContainer": Color(0.5, 0.5, 0.7),
	"CenterContainer": Color(0.7, 0.7, 0.3),
	"AspectRatioContainer": Color(0.4, 0.7, 0.7),
	"HSplitContainer": Color(0.6, 0.4, 0.5),
	"VSplitContainer": Color(0.5, 0.6, 0.4),
	"TabContainer": Color(0.6, 0.5, 0.6),
	# UI Widgets
	"Button": Color(0.6, 0.6, 0.8),
	"Label": Color(0.7, 0.7, 0.7),
	"LineEdit": Color(0.5, 0.6, 0.7),
	"TextEdit": Color(0.5, 0.6, 0.7),
	"CheckBox": Color(0.6, 0.7, 0.6),
	"CheckButton": Color(0.6, 0.7, 0.6),
	"OptionButton": Color(0.6, 0.6, 0.8),
	"SpinBox": Color(0.7, 0.6, 0.5),
	"HSlider": Color(0.5, 0.7, 0.7),
	"VSlider": Color(0.5, 0.7, 0.7),
	"ProgressBar": Color(0.4, 0.7, 0.8),
	"ColorRect": Color(0.8, 0.5, 0.5),
	"TextureRect": Color(0.7, 0.6, 0.8),
	"ColorPickerButton": Color(0.8, 0.6, 0.7),
	"RichTextLabel": Color(0.6, 0.5, 0.7),
	# Animation
	"AnimationPlayer": Color(0.9, 0.6, 0.3)
}

const CATEGORY_COLORS := {
	"Scenes": Color(0.9, 0.7, 0.2),
	"2D Nodes": Color(0.4, 0.7, 0.4),
	"Containers": Color(0.7, 0.4, 0.4),
	"UI Widgets": Color(0.5, 0.5, 0.8),
	"Animation": Color(0.9, 0.6, 0.3)
}


static func get_node_color(node_type: String) -> Color:
	return NODE_COLORS.get(node_type, Color(0.5, 0.5, 0.5))


@onready var title_bar: Panel = $TitleBar
@onready var title_label: Label = $TitleBar/HBox/Label
@onready var minimize_button: Button = $TitleBar/HBox/MinimizeButton
@onready var controls_tree: Tree = $Content/Tree


func _ready() -> void:
	title_bar.gui_input.connect(_on_title_bar_gui_input)
	gui_input.connect(_on_panel_clicked)
	minimize_button.pressed.connect(_toggle_minimize)
	title_label.text = "Controls"

	# Setup tree
	controls_tree.hide_root = true
	controls_tree.allow_reselect = true
	controls_tree.select_mode = Tree.SELECT_SINGLE
	controls_tree.set_column_expand(0, true)
	controls_tree.item_selected.connect(_on_tree_item_selected)
	controls_tree.item_activated.connect(_on_tree_item_activated)

	# Build the node type tree
	_build_controls_tree()


func _build_controls_tree() -> void:
	controls_tree.clear()
	var root = controls_tree.create_item()

	for category in NODE_CATEGORIES.keys():
		var category_item = controls_tree.create_item(root)
		category_item.set_text(0, category)
		category_item.set_custom_color(0, CATEGORY_COLORS.get(category, Color.WHITE))
		category_item.set_selectable(0, false)
		category_item.collapsed = false

		for node_type in NODE_CATEGORIES[category]:
			var node_item = controls_tree.create_item(category_item)
			node_item.set_text(0, node_type)
			node_item.set_custom_color(0, NODE_COLORS.get(node_type, Color.WHITE))
			node_item.set_meta("node_type", node_type)


func _on_tree_item_selected() -> void:
	# Selection changed, but we spawn on double-click/activation
	pass


func _on_tree_item_activated() -> void:
	var item = controls_tree.get_selected()
	if item and item.has_meta("node_type"):
		var node_type = item.get_meta("node_type")
		node_spawn_requested.emit(node_type)


func _input(event: InputEvent) -> void:
	if not visible:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var local_pos = get_local_mouse_position()
			var my_size = size

			if event.pressed:
				if not minimized and local_pos.x >= 0 and local_pos.x <= my_size.x and local_pos.y >= 0 and local_pos.y <= my_size.y:
					resize_direction = _get_resize_direction(local_pos, my_size)
					if resize_direction != Vector2.ZERO:
						resizing = true
						move_to_front()
						get_viewport().set_input_as_handled()
			else:
				resizing = false
				resize_direction = Vector2.ZERO

	elif event is InputEventMouseMotion:
		if resizing:
			_handle_resize(event)
			get_viewport().set_input_as_handled()
		elif not minimized:
			var local_pos = get_local_mouse_position()
			var my_size = size
			if local_pos.x >= 0 and local_pos.x <= my_size.x and local_pos.y >= 0 and local_pos.y <= my_size.y:
				_update_cursor(local_pos)


func _get_resize_direction(pos: Vector2, panel_size: Vector2) -> Vector2:
	var dir := Vector2.ZERO

	if pos.x < resize_margin:
		dir.x = -1
	elif pos.x > panel_size.x - resize_margin:
		dir.x = 1

	if pos.y < resize_margin:
		dir.y = -1
	elif pos.y > panel_size.y - resize_margin:
		dir.y = 1

	return dir


func _update_cursor(pos: Vector2) -> void:
	var dir = _get_resize_direction(pos, size)

	if dir == Vector2.ZERO:
		mouse_default_cursor_shape = Control.CURSOR_ARROW
	elif dir == Vector2(1, 1) or dir == Vector2(-1, -1):
		mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	elif dir == Vector2(-1, 1) or dir == Vector2(1, -1):
		mouse_default_cursor_shape = Control.CURSOR_BDIAGSIZE
	elif dir.x != 0:
		mouse_default_cursor_shape = Control.CURSOR_HSIZE
	elif dir.y != 0:
		mouse_default_cursor_shape = Control.CURSOR_VSIZE


func _handle_resize(event: InputEventMouseMotion) -> void:
	var delta = event.relative
	var new_size = size
	var new_pos = global_position

	if resize_direction.x == 1:
		new_size.x += delta.x
	elif resize_direction.x == -1:
		new_size.x -= delta.x
		new_pos.x += delta.x

	if resize_direction.y == 1:
		new_size.y += delta.y
	elif resize_direction.y == -1:
		new_size.y -= delta.y
		new_pos.y += delta.y

	# Apply minimum size
	if new_size.x < min_size.x:
		if resize_direction.x == -1:
			new_pos.x -= min_size.x - new_size.x
		new_size.x = min_size.x

	if new_size.y < min_size.y:
		if resize_direction.y == -1:
			new_pos.y -= min_size.y - new_size.y
		new_size.y = min_size.y

	size = new_size
	global_position = new_pos


func _on_panel_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		move_to_front()


func _on_title_bar_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.double_click:
					_toggle_minimize()
				else:
					dragging = true
					drag_offset = get_global_mouse_position() - global_position
					move_to_front()
			else:
				dragging = false

	elif event is InputEventMouseMotion and dragging:
		global_position = get_global_mouse_position() - drag_offset


func _toggle_minimize() -> void:
	if minimized:
		# Restore
		size = restored_size
		$Content.visible = true
		$ResizeGrip.visible = true
		minimize_button.text = "−"
		title_label.text = "Controls"
		minimized = false
	else:
		# Minimize
		restored_size = size
		title_label.text = "Cont:"
		# Calculate minimum width: label width + button + padding
		var min_width = title_label.get_minimum_size().x + minimize_button.size.x + 24
		size = Vector2(min_width, title_bar_height + 8)
		$Content.visible = false
		$ResizeGrip.visible = false
		minimize_button.text = "+"
		minimized = true
