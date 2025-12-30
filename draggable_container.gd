# Visual container representing a Godot Control node - supports drag/resize,
# widget spawning, AI prompts per node, and properties editing.
class_name DraggableContainer
extends Panel

const ControlsPanelScript = preload("res://draggable_window.gd")

signal closed
signal drag_ended(container: DraggableContainer)
signal unlinked(container: DraggableContainer)
signal selected(container: DraggableContainer)

var container_type: String = ""
var container_name: String = ""
var inner_container: Container
var parent_container: DraggableContainer = null
var is_editing_name := false

# Dragging
var dragging := false
var drag_offset := Vector2.ZERO

# Resizing
var resizing := false
var resize_direction := Vector2.ZERO
var min_size := Vector2(100, 80)
var resize_margin := 10
var is_resizing_this_container := false

@onready var title_bar: HBoxContainer = $TitleBar
@onready var title_label: Label = $TitleBar/TitleLabel
@onready var unlink_button: Button = $TitleBar/UnlinkButton
@onready var close_button: Button = $TitleBar/CloseButton
@onready var content_panel: Panel = $Content

var name_edit: LineEdit
var widget_popup: PopupMenu
var widget_context_menu: PopupMenu
var selected_widget: Control = null
var dragging_widget: Control = null
var widget_drag_offset: Vector2 = Vector2.ZERO
var widget_original_index: int = -1

# Properties dialog
var properties_dialog: Window
var properties_container: VBoxContainer
var editing_widget: Control = null
var container_context_menu: PopupMenu

const WIDGET_TYPES := [
	"Button",
	"Label",
	"LineEdit",
	"TextEdit",
	"CheckBox",
	"CheckButton",
	"OptionButton",
	"SpinBox",
	"HSlider",
	"VSlider",
	"ProgressBar",
	"ColorRect",
	"TextureRect",
	"ColorPickerButton",
	"RichTextLabel"
]


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	unlink_button.pressed.connect(_on_unlink_pressed)
	title_bar.gui_input.connect(_on_title_bar_gui_input)
	title_label.gui_input.connect(_on_title_label_gui_input)

	# Create LineEdit for name editing (hidden by default)
	name_edit = LineEdit.new()
	name_edit.visible = false
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_submitted.connect(_on_name_submitted)
	name_edit.focus_exited.connect(_on_name_focus_lost)
	title_bar.add_child(name_edit)
	title_bar.move_child(name_edit, 0)

	# Create widget popup menu
	widget_popup = PopupMenu.new()
	widget_popup.name = "WidgetPopup"
	for i in range(WIDGET_TYPES.size()):
		widget_popup.add_item(WIDGET_TYPES[i], i)
	widget_popup.id_pressed.connect(_on_widget_selected)
	add_child(widget_popup)

	# Create widget context menu (for delete)
	widget_context_menu = PopupMenu.new()
	widget_context_menu.name = "WidgetContextMenu"
	widget_context_menu.add_item("AI Prompts...", 3)
	widget_context_menu.add_separator()
	widget_context_menu.add_item("Properties...", 0)
	widget_context_menu.add_item("Delete Widget", 1)
	widget_context_menu.add_separator()
	widget_context_menu.add_item("Add Widget Here...", 2)
	widget_context_menu.id_pressed.connect(_on_widget_context_action)
	add_child(widget_context_menu)

	# Create properties dialog
	_create_properties_dialog()

	# Connect content panel right-click
	content_panel.gui_input.connect(_on_content_panel_gui_input)
	# Clip children that overflow the content panel
	content_panel.clip_contents = true

	# Create HTTPRequest for Ollama API calls
	claude_http_request = HTTPRequest.new()
	claude_http_request.timeout = 600  # 10 minute timeout for slow models
	add_child(claude_http_request)
	claude_http_request.request_completed.connect(_on_claude_request_completed)

	# Create HTTPRequest for DynamoDB operations
	dynamodb_http_request = HTTPRequest.new()
	dynamodb_http_request.timeout = 30
	add_child(dynamodb_http_request)
	dynamodb_http_request.request_completed.connect(_on_dynamodb_request_completed)

	_load_config()


func _load_config() -> void:
	# Load main config
	var config_file = FileAccess.open("res://config.json", FileAccess.READ)
	if config_file:
		var config = JSON.parse_string(config_file.get_as_text())
		if config and config.has("dynamodb"):
			dynamodb_endpoint = config["dynamodb"].get("endpoint", "")
			dynamodb_region = config["dynamodb"].get("region", "us-west-2")
		if config and config.has("tables"):
			ai_prompts_table = config["tables"].get("aiPrompts", "AIPrompts")
			usage_tracking_table = config["tables"].get("usageTracking", "UsageTracking")
		if config and config.has("ai_services"):
			ai_services = config["ai_services"]
		if config and config.has("image_services"):
			image_services = config["image_services"]
		if config and config.has("daily_limits"):
			daily_limits = config["daily_limits"]
		if config and config.has("daily_image_limits"):
			daily_image_limits = config["daily_image_limits"]

	# Load API keys
	var api_config_file = FileAccess.open("res://config-api.json", FileAccess.READ)
	if api_config_file:
		var api_config = JSON.parse_string(api_config_file.get_as_text())
		if api_config:
			ai_api_keys = api_config


func _input(event: InputEvent) -> void:
	if not visible:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var local_pos = get_local_mouse_position()
			var my_size = size

			if event.pressed:
				# Only start resize if click is within our bounds and on an edge
				if local_pos.x >= 0 and local_pos.x <= my_size.x and local_pos.y >= 0 and local_pos.y <= my_size.y:
					resize_direction = _get_resize_direction(local_pos, my_size)
					if resize_direction != Vector2.ZERO:
						resizing = true
						is_resizing_this_container = true
						get_viewport().set_input_as_handled()
			else:
				# Only handle release if we started the resize
				if is_resizing_this_container:
					resizing = false
					resize_direction = Vector2.ZERO
					is_resizing_this_container = false

	elif event is InputEventMouseMotion:
		# Only handle resize motion if we're the one resizing
		if is_resizing_this_container and resizing:
			_handle_resize(event)
			get_viewport().set_input_as_handled()
		elif not resizing:
			# Update cursor based on position
			var local_pos = get_local_mouse_position()
			var my_size = size
			if local_pos.x >= 0 and local_pos.x <= my_size.x and local_pos.y >= 0 and local_pos.y <= my_size.y:
				_update_cursor(local_pos)


func set_container_type(type: String) -> void:
	container_type = type
	title_label.text = type

	# Apply color based on container type
	var color = ControlsPanelScript.get_node_color(type)
	_apply_color(color)

	# Create the inner container based on type
	match type:
		"VBoxContainer":
			inner_container = VBoxContainer.new()
		"HBoxContainer":
			inner_container = HBoxContainer.new()
		"GridContainer":
			inner_container = GridContainer.new()
			inner_container.columns = 2
		"FlowContainer":
			inner_container = HFlowContainer.new()
		"MarginContainer":
			inner_container = MarginContainer.new()
		"PanelContainer":
			inner_container = PanelContainer.new()
		"CenterContainer":
			inner_container = CenterContainer.new()
		"AspectRatioContainer":
			inner_container = AspectRatioContainer.new()
		"HSplitContainer":
			inner_container = HSplitContainer.new()
		"VSplitContainer":
			inner_container = VSplitContainer.new()
		"TabContainer":
			inner_container = TabContainer.new()
		_:
			inner_container = VBoxContainer.new()

	inner_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	inner_container.mouse_filter = Control.MOUSE_FILTER_PASS
	inner_container.gui_input.connect(_on_content_panel_gui_input)
	content_panel.add_child(inner_container)


func _apply_color(color: Color) -> void:
	# Style for main panel (border)
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = color.darkened(0.3)
	panel_style.border_width_left = 2
	panel_style.border_width_top = 2
	panel_style.border_width_right = 2
	panel_style.border_width_bottom = 2
	panel_style.border_color = Color(0, 0, 0)
	panel_style.corner_radius_top_left = 4
	panel_style.corner_radius_top_right = 4
	panel_style.corner_radius_bottom_left = 4
	panel_style.corner_radius_bottom_right = 4
	add_theme_stylebox_override("panel", panel_style)

	# Style for title bar
	var title_style = StyleBoxFlat.new()
	title_style.bg_color = color
	title_style.corner_radius_top_left = 4
	title_style.corner_radius_top_right = 4
	title_bar.add_theme_stylebox_override("panel", title_style)

	# Style for content panel
	var content_style = StyleBoxFlat.new()
	content_style.bg_color = color.darkened(0.4)
	content_panel.add_theme_stylebox_override("panel", content_style)


func _update_title_display() -> void:
	if container_name.is_empty():
		title_label.text = container_type
	else:
		title_label.text = container_name + " (" + container_type + ")"


func set_container_name(new_name: String) -> void:
	container_name = new_name
	_update_title_display()


func _on_title_label_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.double_click:
				_start_name_edit()
			elif event.pressed:
				dragging = true
				drag_offset = get_global_mouse_position() - global_position
			else:
				if dragging:
					dragging = false
					drag_ended.emit(self)

	elif event is InputEventMouseMotion and dragging:
		var new_pos = get_global_mouse_position() - drag_offset
		global_position = new_pos

		if parent_container:
			_clamp_to_parent_bounds()


func _start_name_edit() -> void:
	is_editing_name = true
	title_label.visible = false
	name_edit.visible = true
	name_edit.text = container_name
	name_edit.grab_focus()
	name_edit.select_all()


func _finish_name_edit() -> void:
	if not is_editing_name:
		return
	is_editing_name = false
	container_name = name_edit.text.strip_edges()
	name_edit.visible = false
	title_label.visible = true
	_update_title_display()


func _on_name_submitted(_new_text: String) -> void:
	_finish_name_edit()


func _on_name_focus_lost() -> void:
	_finish_name_edit()


func get_content_panel() -> Panel:
	return content_panel


func get_inner_container() -> Container:
	return inner_container


func hide_chrome() -> void:
	"""Hide title bar and buttons for a cleaner nested container look"""
	if title_bar:
		title_bar.visible = false
	# Adjust content panel to fill the space
	if content_panel:
		content_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
		content_panel.offset_top = 2
		content_panel.offset_left = 2
		content_panel.offset_right = -2
		content_panel.offset_bottom = -2


func fill_parent_content() -> void:
	"""Make this container fill its parent's content area"""
	if not parent_container:
		return
	var parent_content = parent_container.get_content_panel()
	if not parent_content:
		return
	# Reset to position mode first
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	# Now set position and size directly
	position = Vector2(2, 2)
	var target_size = parent_content.size - Vector2(4, 4)
	# Ensure minimum reasonable size
	target_size = target_size.max(Vector2(50, 50))
	set_deferred("size", target_size)


func get_child_containers() -> Array[DraggableContainer]:
	var children: Array[DraggableContainer] = []
	for child in content_panel.get_children():
		if child is DraggableContainer:
			children.append(child)
	return children


func add_child_container(child: DraggableContainer) -> void:
	# Store the global position before reparenting
	var global_pos = child.global_position

	# Remove from current parent
	if child.get_parent():
		child.get_parent().remove_child(child)

	# Add to our content panel
	content_panel.add_child(child)
	child.parent_container = self

	# Show the unlink button
	child.unlink_button.visible = true

	# Convert global position to local position within content panel
	child.global_position = global_pos

	# Ensure child is within bounds
	child._clamp_to_parent_bounds()


func remove_child_container(child: DraggableContainer) -> void:
	if child.get_parent() == content_panel:
		var global_pos = child.global_position
		content_panel.remove_child(child)
		child.parent_container = null

		# Hide the unlink button
		child.unlink_button.visible = false

		child.global_position = global_pos


func _on_close_pressed() -> void:
	closed.emit()
	queue_free()


func _on_unlink_pressed() -> void:
	unlinked.emit(self)


func _on_title_bar_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				dragging = true
				drag_offset = get_global_mouse_position() - global_position
				selected.emit(self)
			else:
				if dragging:
					dragging = false
					drag_ended.emit(self)

	elif event is InputEventMouseMotion and dragging:
		var new_pos = get_global_mouse_position() - drag_offset
		global_position = new_pos

		# Constrain to parent bounds if we have a parent container
		if parent_container:
			_clamp_to_parent_bounds()


func _clamp_to_parent_bounds() -> void:
	if not parent_container:
		return

	var parent_content = parent_container.get_content_panel()
	var parent_rect = parent_content.get_global_rect()

	# Clamp position so container stays within parent content area
	var min_x = parent_rect.position.x
	var min_y = parent_rect.position.y
	var max_x = parent_rect.position.x + parent_rect.size.x - size.x
	var max_y = parent_rect.position.y + parent_rect.size.y - size.y

	global_position.x = clamp(global_position.x, min_x, max(min_x, max_x))
	global_position.y = clamp(global_position.y, min_y, max(min_y, max_y))


func _get_resize_direction(pos: Vector2, my_size: Vector2) -> Vector2:
	var dir := Vector2.ZERO

	# Check edges
	if pos.x < resize_margin:
		dir.x = -1
	elif pos.x > my_size.x - resize_margin:
		dir.x = 1

	if pos.y < resize_margin:
		dir.y = -1
	elif pos.y > my_size.y - resize_margin:
		dir.y = 1

	return dir


func _handle_resize(event: InputEventMouseMotion) -> void:
	var delta = event.relative
	var new_size = size
	var new_pos = global_position

	# Handle horizontal resize
	if resize_direction.x == 1:
		new_size.x += delta.x
	elif resize_direction.x == -1:
		new_size.x -= delta.x
		new_pos.x += delta.x

	# Handle vertical resize
	if resize_direction.y == 1:
		new_size.y += delta.y
	elif resize_direction.y == -1:
		new_size.y -= delta.y
		new_pos.y += delta.y

	# Apply minimum size constraints
	if new_size.x >= min_size.x:
		size.x = new_size.x
		if resize_direction.x == -1:
			global_position.x = new_pos.x

	if new_size.y >= min_size.y:
		size.y = new_size.y
		if resize_direction.y == -1:
			global_position.y = new_pos.y

	# Constrain to parent bounds if we have a parent container
	if parent_container:
		_clamp_size_to_parent_bounds()


func _clamp_size_to_parent_bounds() -> void:
	if not parent_container:
		return

	var parent_content = parent_container.get_content_panel()
	var parent_rect = parent_content.get_global_rect()

	# Clamp size so container doesn't exceed parent bounds
	var max_width = parent_rect.size.x - (global_position.x - parent_rect.position.x)
	var max_height = parent_rect.size.y - (global_position.y - parent_rect.position.y)

	size.x = min(size.x, max_width)
	size.y = min(size.y, max_height)

	# Also ensure position is valid
	_clamp_to_parent_bounds()


func _update_cursor(pos: Vector2) -> void:
	var dir = _get_resize_direction(pos, size)

	if dir == Vector2.ZERO:
		mouse_default_cursor_shape = Control.CURSOR_ARROW
	elif dir == Vector2(1, 0) or dir == Vector2(-1, 0):
		mouse_default_cursor_shape = Control.CURSOR_HSIZE
	elif dir == Vector2(0, 1) or dir == Vector2(0, -1):
		mouse_default_cursor_shape = Control.CURSOR_VSIZE
	elif dir == Vector2(1, 1) or dir == Vector2(-1, -1):
		mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	elif dir == Vector2(-1, 1) or dir == Vector2(1, -1):
		mouse_default_cursor_shape = Control.CURSOR_BDIAGSIZE


func _on_content_panel_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# Select this container
			selected.emit(self)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			# Show container context menu
			if not container_context_menu:
				container_context_menu = PopupMenu.new()
				container_context_menu.add_item("AI Prompts...", 2)
				container_context_menu.add_separator()
				container_context_menu.add_item("Add Widget...", 0)
				container_context_menu.add_item("Container Properties...", 1)
				container_context_menu.id_pressed.connect(_on_container_context_action)
				add_child(container_context_menu)
			container_context_menu.position = Vector2i(get_global_mouse_position())
			container_context_menu.popup()


func _on_container_context_action(id: int) -> void:
	match id:
		0:  # Add Widget
			widget_popup.position = Vector2i(get_global_mouse_position())
			widget_popup.popup()
		1:  # Container Properties
			show_container_properties()
		2:  # AI Prompts
			_show_ai_prompts_dialog()


func _on_widget_selected(id: int) -> void:
	if id >= 0 and id < WIDGET_TYPES.size():
		var widget_type = WIDGET_TYPES[id]
		_spawn_widget(widget_type)


func _spawn_widget(widget_type: String) -> Control:
	var widget: Control

	match widget_type:
		"Button":
			widget = Button.new()
			widget.text = "Button"
			widget.custom_minimum_size = Vector2(80, 30)
		"Label":
			widget = Label.new()
			widget.text = "Label"
		"LineEdit":
			widget = LineEdit.new()
			widget.placeholder_text = "Enter text..."
			widget.custom_minimum_size = Vector2(120, 0)
		"TextEdit":
			widget = TextEdit.new()
			widget.placeholder_text = "Enter text..."
			widget.custom_minimum_size = Vector2(150, 80)
		"CheckBox":
			widget = CheckBox.new()
			widget.text = "CheckBox"
		"CheckButton":
			widget = CheckButton.new()
			widget.text = "Toggle"
		"OptionButton":
			widget = OptionButton.new()
			widget.add_item("Option 1")
			widget.add_item("Option 2")
			widget.add_item("Option 3")
			widget.custom_minimum_size = Vector2(100, 0)
		"SpinBox":
			widget = SpinBox.new()
			widget.min_value = 0
			widget.max_value = 100
			widget.value = 50
		"HSlider":
			widget = HSlider.new()
			widget.min_value = 0
			widget.max_value = 100
			widget.value = 50
			widget.custom_minimum_size = Vector2(100, 20)
		"VSlider":
			widget = VSlider.new()
			widget.min_value = 0
			widget.max_value = 100
			widget.value = 50
			widget.custom_minimum_size = Vector2(20, 80)
		"ProgressBar":
			widget = ProgressBar.new()
			widget.min_value = 0
			widget.max_value = 100
			widget.value = 50
			widget.custom_minimum_size = Vector2(120, 20)
		"ColorRect":
			widget = ColorRect.new()
			widget.color = Color(0.5, 0.5, 0.8)
			widget.custom_minimum_size = Vector2(60, 40)
		"TextureRect":
			# Use container with label as placeholder since we don't load actual textures
			var tex_container = PanelContainer.new()
			var tex_style = StyleBoxFlat.new()
			tex_style.bg_color = Color(0.4, 0.35, 0.5, 0.9)
			tex_style.border_width_left = 1
			tex_style.border_width_right = 1
			tex_style.border_width_top = 1
			tex_style.border_width_bottom = 1
			tex_style.border_color = Color(0.6, 0.5, 0.7)
			tex_container.add_theme_stylebox_override("panel", tex_style)
			tex_container.custom_minimum_size = Vector2(64, 64)

			var tex_label = Label.new()
			tex_label.text = "TEX"
			tex_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			tex_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			tex_label.add_theme_color_override("font_color", Color(0.8, 0.7, 0.9))
			tex_container.add_child(tex_label)
			widget = tex_container
		"ColorPickerButton":
			widget = ColorPickerButton.new()
			widget.color = Color(1, 0.5, 0.5)
			widget.custom_minimum_size = Vector2(80, 30)
		"RichTextLabel":
			widget = RichTextLabel.new()
			widget.text = "[b]Rich[/b] Text"
			widget.bbcode_enabled = true
			widget.custom_minimum_size = Vector2(120, 60)
		_:
			widget = Label.new()
			widget.text = widget_type

	# Store widget type as metadata
	widget.set_meta("widget_type", widget_type)

	# Ensure widget can receive mouse input (Labels default to IGNORE)
	widget.mouse_filter = Control.MOUSE_FILTER_STOP

	# Connect right-click for context menu
	widget.gui_input.connect(_on_widget_gui_input.bind(widget))

	# Add to inner container
	if inner_container:
		inner_container.add_child(widget)
	else:
		content_panel.add_child(widget)

	print("Spawned widget: ", widget_type)
	return widget


func _on_widget_gui_input(event: InputEvent, widget: Control) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			selected_widget = widget
			widget_context_menu.position = Vector2i(get_global_mouse_position())
			widget_context_menu.popup()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Emit selected signal for the container
				selected.emit(self)
				# Start dragging widget
				dragging_widget = widget
				widget_drag_offset = widget.get_local_mouse_position()
				if inner_container:
					widget_original_index = widget.get_index()
			else:
				# Stop dragging
				if dragging_widget:
					_finish_widget_drag()
					dragging_widget = null

	elif event is InputEventMouseMotion and dragging_widget == widget:
		_update_widget_drag_position()


func _update_widget_drag_position() -> void:
	if not dragging_widget or not inner_container:
		return

	# Find which position the widget should be moved to based on mouse position
	var mouse_pos = inner_container.get_local_mouse_position()
	var target_index = _get_widget_index_at_position(mouse_pos)

	if target_index != dragging_widget.get_index() and target_index >= 0:
		inner_container.move_child(dragging_widget, target_index)


func _get_widget_index_at_position(local_pos: Vector2) -> int:
	if not inner_container:
		return -1

	var children = inner_container.get_children()
	for i in range(children.size()):
		var child = children[i]
		if not child.has_meta("widget_type"):
			continue

		var child_rect = Rect2(child.position, child.size)

		# Check if mouse is in the upper half (insert before) or lower half (insert after)
		if inner_container is VBoxContainer or inner_container is VFlowContainer:
			if local_pos.y < child_rect.position.y + child_rect.size.y / 2:
				return i
		elif inner_container is HBoxContainer or inner_container is HFlowContainer:
			if local_pos.x < child_rect.position.x + child_rect.size.x / 2:
				return i
		else:
			# For Grid and other containers, use center point distance
			if child_rect.has_point(local_pos):
				return i

	# If we're past all widgets, return the last position
	return children.size() - 1


func _finish_widget_drag() -> void:
	# Widget is already in its new position from _update_widget_drag_position
	var new_index = dragging_widget.get_index() if dragging_widget else -1
	if widget_original_index != new_index and new_index >= 0:
		print("Moved widget from index ", widget_original_index, " to ", new_index)
	widget_original_index = -1


func _on_widget_context_action(id: int) -> void:
	match id:
		0:  # Properties
			if selected_widget and is_instance_valid(selected_widget):
				_show_widget_properties(selected_widget)
		1:  # Delete Widget
			if selected_widget and is_instance_valid(selected_widget):
				selected_widget.queue_free()
				print("Deleted widget")
				selected_widget = null
		2:  # Add Widget Here
			widget_popup.position = Vector2i(get_global_mouse_position())
			widget_popup.popup()
		3:  # AI Prompts
			_show_ai_prompts_dialog()


func get_widgets() -> Array[Control]:
	var widgets: Array[Control] = []
	var container_to_check: Node

	if inner_container:
		container_to_check = inner_container
	else:
		container_to_check = content_panel

	for child in container_to_check.get_children():
		if child.has_meta("widget_type"):
			widgets.append(child)

	return widgets


func add_widget_from_data(widget_type: String, properties: Dictionary) -> Control:
	var widget = _spawn_widget(widget_type)

	# Restore size properties (prefer sizeX/sizeY, fallback to minSizeX/minSizeY)
	if properties.has("sizeX") or properties.has("sizeY"):
		var size_x = properties.get("sizeX", widget.custom_minimum_size.x)
		var size_y = properties.get("sizeY", widget.custom_minimum_size.y)
		widget.custom_minimum_size = Vector2(size_x, size_y)
	elif properties.has("minSizeX") or properties.has("minSizeY"):
		var min_x = properties.get("minSizeX", widget.custom_minimum_size.x)
		var min_y = properties.get("minSizeY", widget.custom_minimum_size.y)
		widget.custom_minimum_size = Vector2(min_x, min_y)

	# Restore text properties
	if properties.has("text") and "text" in widget:
		widget.text = properties["text"]
	if properties.has("placeholder_text") and "placeholder_text" in widget:
		widget.placeholder_text = properties["placeholder_text"]

	# Restore numeric properties
	if properties.has("min_value") and "min_value" in widget:
		widget.min_value = properties["min_value"]
	if properties.has("max_value") and "max_value" in widget:
		widget.max_value = properties["max_value"]
	if properties.has("step") and "step" in widget:
		widget.step = properties["step"]
	if properties.has("value") and "value" in widget:
		widget.value = properties["value"]

	# Restore color
	if properties.has("color") and "color" in widget:
		widget.color = Color(properties["color"])

	# Restore boolean properties
	if properties.has("button_pressed") and "button_pressed" in widget:
		widget.button_pressed = properties["button_pressed"]
	if properties.has("bbcode_enabled") and "bbcode_enabled" in widget:
		widget.bbcode_enabled = properties["bbcode_enabled"]

	# Restore OptionButton items
	if widget is OptionButton and properties.has("items"):
		widget.clear()
		for item in properties["items"]:
			widget.add_item(item)
		if properties.has("selected"):
			widget.selected = properties["selected"]

	return widget


# ==================== PROPERTIES DIALOG ====================

func _create_properties_dialog() -> void:
	properties_dialog = Window.new()
	properties_dialog.title = "Properties"
	properties_dialog.size = Vector2i(300, 400)
	properties_dialog.transient = true
	properties_dialog.visible = false
	add_child(properties_dialog)

	var main_vbox := VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 8)
	main_vbox.offset_left = 10
	main_vbox.offset_top = 10
	main_vbox.offset_right = -10
	main_vbox.offset_bottom = -50
	properties_dialog.add_child(main_vbox)

	# Scrollable container for properties
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(scroll)

	properties_container = VBoxContainer.new()
	properties_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	properties_container.add_theme_constant_override("separation", 6)
	scroll.add_child(properties_container)

	# Close button
	var button_container := HBoxContainer.new()
	button_container.alignment = BoxContainer.ALIGNMENT_END
	button_container.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	button_container.offset_left = 10
	button_container.offset_top = -40
	button_container.offset_right = -10
	button_container.offset_bottom = -10
	properties_dialog.add_child(button_container)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(80, 30)
	close_btn.pressed.connect(func(): properties_dialog.hide())
	button_container.add_child(close_btn)

	properties_dialog.close_requested.connect(func(): properties_dialog.hide())


func _show_widget_properties(widget: Control) -> void:
	editing_widget = widget
	var widget_type = widget.get_meta("widget_type", "Unknown")
	properties_dialog.title = widget_type + " Properties"

	# Clear previous properties
	for child in properties_container.get_children():
		child.queue_free()

	# Add properties based on widget type
	_add_common_widget_properties(widget)

	match widget_type:
		"Button", "CheckBox", "CheckButton":
			_add_text_property(widget, "text", "Text")
			if "button_pressed" in widget:
				_add_bool_property(widget, "button_pressed", "Pressed")
		"Label":
			_add_text_property(widget, "text", "Text")
		"LineEdit":
			_add_text_property(widget, "text", "Text")
			_add_text_property(widget, "placeholder_text", "Placeholder")
		"TextEdit":
			_add_text_property(widget, "text", "Text")
			_add_text_property(widget, "placeholder_text", "Placeholder")
		"SpinBox", "HSlider", "VSlider", "ProgressBar":
			_add_number_property(widget, "value", "Value")
			_add_number_property(widget, "min_value", "Min")
			_add_number_property(widget, "max_value", "Max")
			_add_number_property(widget, "step", "Step")
		"ColorRect", "ColorPickerButton":
			_add_color_property(widget, "color", "Color")
		"RichTextLabel":
			_add_text_property(widget, "text", "BBCode Text")
			_add_bool_property(widget, "bbcode_enabled", "BBCode Enabled")
		"OptionButton":
			_add_option_items_property(widget)

	properties_dialog.popup_centered()


func _add_common_widget_properties(widget: Control) -> void:
	# Size properties
	var size_label := Label.new()
	size_label.text = "— Size —"
	properties_container.add_child(size_label)

	_add_vector2_property(widget, "custom_minimum_size", "Min Size")


func _add_text_property(widget: Control, prop_name: String, label_text: String) -> void:
	var hbox := HBoxContainer.new()
	properties_container.add_child(hbox)

	var label := Label.new()
	label.text = label_text + ":"
	label.custom_minimum_size.x = 80
	hbox.add_child(label)

	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if prop_name in widget:
		edit.text = str(widget.get(prop_name))
	edit.text_changed.connect(func(new_text):
		if prop_name in widget:
			widget.set(prop_name, new_text)
	)
	hbox.add_child(edit)


func _add_number_property(widget: Control, prop_name: String, label_text: String) -> void:
	var hbox := HBoxContainer.new()
	properties_container.add_child(hbox)

	var label := Label.new()
	label.text = label_text + ":"
	label.custom_minimum_size.x = 80
	hbox.add_child(label)

	var spinbox := SpinBox.new()
	spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spinbox.min_value = -10000
	spinbox.max_value = 10000
	spinbox.step = 0.1
	spinbox.allow_greater = true
	spinbox.allow_lesser = true
	if prop_name in widget:
		spinbox.value = widget.get(prop_name)
	spinbox.value_changed.connect(func(new_value):
		if prop_name in widget:
			widget.set(prop_name, new_value)
	)
	hbox.add_child(spinbox)


func _add_bool_property(widget: Control, prop_name: String, label_text: String) -> void:
	var hbox := HBoxContainer.new()
	properties_container.add_child(hbox)

	var checkbox := CheckBox.new()
	checkbox.text = label_text
	if prop_name in widget:
		checkbox.button_pressed = widget.get(prop_name)
	checkbox.toggled.connect(func(pressed):
		if prop_name in widget:
			widget.set(prop_name, pressed)
	)
	hbox.add_child(checkbox)


func _add_color_property(widget: Control, prop_name: String, label_text: String) -> void:
	var hbox := HBoxContainer.new()
	properties_container.add_child(hbox)

	var label := Label.new()
	label.text = label_text + ":"
	label.custom_minimum_size.x = 80
	hbox.add_child(label)

	var color_btn := ColorPickerButton.new()
	color_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	color_btn.custom_minimum_size = Vector2(0, 30)
	if prop_name in widget:
		color_btn.color = widget.get(prop_name)
	color_btn.color_changed.connect(func(new_color):
		if prop_name in widget:
			widget.set(prop_name, new_color)
	)
	hbox.add_child(color_btn)


func _add_vector2_property(widget: Control, prop_name: String, label_text: String) -> void:
	var hbox := HBoxContainer.new()
	properties_container.add_child(hbox)

	var label := Label.new()
	label.text = label_text + ":"
	label.custom_minimum_size.x = 80
	hbox.add_child(label)

	var current_value: Vector2 = widget.get(prop_name) if prop_name in widget else Vector2.ZERO

	var x_spin := SpinBox.new()
	x_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	x_spin.min_value = 0
	x_spin.max_value = 2000
	x_spin.value = current_value.x
	x_spin.prefix = "W:"
	x_spin.value_changed.connect(func(new_x):
		if prop_name in widget:
			var v = widget.get(prop_name)
			widget.set(prop_name, Vector2(new_x, v.y))
	)
	hbox.add_child(x_spin)

	var y_spin := SpinBox.new()
	y_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	y_spin.min_value = 0
	y_spin.max_value = 2000
	y_spin.value = current_value.y
	y_spin.prefix = "H:"
	y_spin.value_changed.connect(func(new_y):
		if prop_name in widget:
			var v = widget.get(prop_name)
			widget.set(prop_name, Vector2(v.x, new_y))
	)
	hbox.add_child(y_spin)


func _add_option_items_property(widget: OptionButton) -> void:
	var label := Label.new()
	label.text = "Items (one per line):"
	properties_container.add_child(label)

	var text_edit := TextEdit.new()
	text_edit.custom_minimum_size = Vector2(0, 100)

	# Get current items
	var items_text := ""
	for i in range(widget.item_count):
		items_text += widget.get_item_text(i) + "\n"
	text_edit.text = items_text.strip_edges()

	text_edit.text_changed.connect(func():
		widget.clear()
		var lines = text_edit.text.split("\n")
		for line in lines:
			if not line.strip_edges().is_empty():
				widget.add_item(line.strip_edges())
	)
	properties_container.add_child(text_edit)


func show_container_properties() -> void:
	editing_widget = null
	properties_dialog.title = container_type + " Properties"

	# Clear previous properties
	for child in properties_container.get_children():
		child.queue_free()

	# Container name
	var name_hbox := HBoxContainer.new()
	properties_container.add_child(name_hbox)

	var name_label := Label.new()
	name_label.text = "Name:"
	name_label.custom_minimum_size.x = 80
	name_hbox.add_child(name_label)

	var name_edit_field := LineEdit.new()
	name_edit_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit_field.text = container_name
	name_edit_field.text_changed.connect(func(new_name):
		set_container_name(new_name)
	)
	name_hbox.add_child(name_edit_field)

	# Container-specific properties
	if inner_container:
		var sep := Label.new()
		sep.text = "— Layout —"
		properties_container.add_child(sep)

		if inner_container is GridContainer:
			_add_inner_number_property("columns", "Columns", 1, 20, 1)

		if inner_container is BoxContainer:
			_add_inner_number_property("separation", "Separation", 0, 100, 1)
			# Alignment
			var align_hbox := HBoxContainer.new()
			properties_container.add_child(align_hbox)

			var align_label := Label.new()
			align_label.text = "Alignment:"
			align_label.custom_minimum_size.x = 80
			align_hbox.add_child(align_label)

			var align_option := OptionButton.new()
			align_option.add_item("Begin", 0)
			align_option.add_item("Center", 1)
			align_option.add_item("End", 2)
			align_option.selected = inner_container.alignment
			align_option.item_selected.connect(func(idx):
				inner_container.alignment = idx
			)
			align_hbox.add_child(align_option)

	properties_dialog.popup_centered()


func _add_inner_number_property(prop_name: String, label_text: String, min_val: float, max_val: float, step_val: float) -> void:
	var hbox := HBoxContainer.new()
	properties_container.add_child(hbox)

	var label := Label.new()
	label.text = label_text + ":"
	label.custom_minimum_size.x = 80
	hbox.add_child(label)

	var spinbox := SpinBox.new()
	spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spinbox.min_value = min_val
	spinbox.max_value = max_val
	spinbox.step = step_val
	if prop_name in inner_container:
		spinbox.value = inner_container.get(prop_name)
	elif prop_name == "separation":
		spinbox.value = inner_container.get_theme_constant("separation")
	spinbox.value_changed.connect(func(new_value):
		if prop_name in inner_container:
			inner_container.set(prop_name, int(new_value))
		elif prop_name == "separation":
			inner_container.add_theme_constant_override("separation", int(new_value))
	)
	hbox.add_child(spinbox)


# ============================================
# AI Prompts Dialog
# ============================================

var ai_prompts_dialog: Window
var ai_prompt_title_edit: LineEdit
var ai_prompt_content_edit: TextEdit
var ai_regenerate_btn: Button
var ai_response_edit: TextEdit
var ai_images_grid: GridContainer
var ai_service_dropdown: OptionButton
var ai_model_dropdown: OptionButton
var ai_services: Dictionary = {}
var image_service_dropdown: OptionButton
var image_model_dropdown: OptionButton
var image_services: Dictionary = {}
var ai_prompt_images: Array = []
var saved_prompts_dropdown: OptionButton
var saved_prompts_list: Array = []
var ai_status_label: Label
var ai_status_timer: Timer
var current_prompt_status: String = ""
var image_status_label: Label
var current_image_status: String = ""

# Daily limits
var daily_limits: Dictionary = {"default": 5}
var daily_image_limits: Dictionary = {"default": 3}
var usage_tracking_table: String = "UsageTracking"
var prompt_limit_label: Label
var image_limit_label: Label
var ai_generate_btn: Button

# Image generation settings
var image_mode_replace: CheckBox
var image_mode_append: CheckBox
var image_count_spinbox: SpinBox

# Image loading from URLs
var pending_image_loads: Array = []  # Track pending image load requests

# AI API
var claude_http_request: HTTPRequest
var ai_api_keys: Dictionary = {}

# DynamoDB
var dynamodb_http_request: HTTPRequest
var dynamodb_endpoint: String = ""
var dynamodb_region: String = ""
var ai_prompts_table: String = ""
var current_prompt_id: String = ""
var current_generated_images: String = ""  # Preserve images when saving
var is_loading_prompts: bool = false

# Project/Object identification for prompts
var current_project_id: int = -1
var current_object_id: int = -1


func _show_ai_prompts_dialog() -> void:
	if not ai_prompts_dialog:
		_create_ai_prompts_dialog()

	# Get object ID from container's meta
	current_object_id = get_meta("node_id", get_meta("container_id", -1))

	# Reset for new prompt
	current_prompt_id = ""
	current_generated_images = ""
	ai_prompt_title_edit.text = ""
	ai_prompt_content_edit.text = ""
	ai_response_edit.text = ""
	_clear_ai_images()

	# Update button states for new prompt
	_update_regenerate_button_states()

	# Fetch saved prompts from DynamoDB for this specific object
	_fetch_saved_prompts()

	# Check usage limits for currently selected services
	_check_usage_limits()

	ai_prompts_dialog.popup_centered()


func _update_regenerate_button_states() -> void:
	"""Update Regenerate Prompt and Regenerate Images button states based on current conditions."""
	var is_saved = not current_prompt_id.is_empty()
	var has_response = ai_response_edit and not ai_response_edit.text.strip_edges().is_empty()

	# Regenerate Prompt: enabled only if prompt is saved
	if ai_regenerate_btn:
		# Don't override if disabled due to daily limit
		if ai_regenerate_btn.tooltip_text.begins_with("Daily limit"):
			pass  # Keep disabled due to limit
		elif not is_saved:
			ai_regenerate_btn.disabled = true
			ai_regenerate_btn.tooltip_text = "Save prompt first"
		else:
			ai_regenerate_btn.disabled = false
			ai_regenerate_btn.tooltip_text = ""

	# Regenerate Images: enabled only if prompt is saved AND has AI response
	if ai_generate_btn:
		# Don't override if disabled due to daily limit
		if ai_generate_btn.tooltip_text.begins_with("Daily limit"):
			pass  # Keep disabled due to limit
		elif not is_saved:
			ai_generate_btn.disabled = true
			ai_generate_btn.tooltip_text = "Save prompt first"
		elif not has_response:
			ai_generate_btn.disabled = true
			ai_generate_btn.tooltip_text = "Generate AI response first"
		else:
			ai_generate_btn.disabled = false
			ai_generate_btn.tooltip_text = ""


func _fetch_saved_prompts() -> void:
	if dynamodb_endpoint.is_empty():
		print("DynamoDB endpoint not configured")
		return

	if current_project_id < 0 or current_object_id < 0:
		print("Project or object ID not set, cannot fetch prompts")
		saved_prompts_dropdown.clear()
		saved_prompts_dropdown.add_item("-- New Prompt --")
		return

	is_loading_prompts = true
	saved_prompts_dropdown.clear()
	saved_prompts_dropdown.add_item("-- New Prompt --")
	saved_prompts_dropdown.add_item("Loading...")
	saved_prompts_dropdown.disabled = true

	# Build the composite key
	var project_object_id = str(current_project_id) + "_" + str(current_object_id)

	# Query by partition key (projectObjectID)
	var request_body = JSON.stringify({
		"TableName": ai_prompts_table,
		"KeyConditionExpression": "projectObjectID = :poid",
		"ExpressionAttributeValues": {
			":poid": {"S": project_object_id}
		}
	})

	var headers = PackedStringArray([
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.Query",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	])

	dynamodb_http_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)


func _create_ai_prompts_dialog() -> void:
	ai_prompts_dialog = Window.new()
	ai_prompts_dialog.title = "AI Prompts"
	ai_prompts_dialog.size = Vector2i(750, 1100)
	ai_prompts_dialog.transient = true
	ai_prompts_dialog.exclusive = false
	ai_prompts_dialog.visible = false
	add_child(ai_prompts_dialog)

	var main_vbox := VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 10)
	main_vbox.offset_left = 15
	main_vbox.offset_top = 15
	main_vbox.offset_right = -15
	main_vbox.offset_bottom = -15
	ai_prompts_dialog.add_child(main_vbox)

	# Saved prompts dropdown
	var saved_hbox := HBoxContainer.new()
	saved_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(saved_hbox)

	var saved_label := Label.new()
	saved_label.text = "Saved Prompts:"
	saved_hbox.add_child(saved_label)

	saved_prompts_dropdown = OptionButton.new()
	saved_prompts_dropdown.add_item("-- New Prompt --")
	saved_prompts_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	saved_prompts_dropdown.item_selected.connect(_on_saved_prompt_selected)
	saved_hbox.add_child(saved_prompts_dropdown)

	var separator := HSeparator.new()
	main_vbox.add_child(separator)

	# Prompt title
	var prompt_title_label := Label.new()
	prompt_title_label.text = "Prompt Title:"
	main_vbox.add_child(prompt_title_label)

	ai_prompt_title_edit = LineEdit.new()
	ai_prompt_title_edit.placeholder_text = "Enter a title for this prompt..."
	ai_prompt_title_edit.custom_minimum_size.y = 30
	main_vbox.add_child(ai_prompt_title_edit)

	# Prompt content
	var content_label := Label.new()
	content_label.text = "Prompt Content:"
	main_vbox.add_child(content_label)

	ai_prompt_content_edit = TextEdit.new()
	ai_prompt_content_edit.placeholder_text = "Enter the AI prompt content..."
	ai_prompt_content_edit.custom_minimum_size.y = 100
	ai_prompt_content_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ai_prompt_content_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	main_vbox.add_child(ai_prompt_content_edit)

	# AI Prompt regenerate button
	var prompt_hbox := HBoxContainer.new()
	prompt_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(prompt_hbox)

	var prompt_label := Label.new()
	prompt_label.text = "AI Prompt"
	prompt_hbox.add_child(prompt_label)

	ai_regenerate_btn = Button.new()
	ai_regenerate_btn.text = "Regenerate Prompt"
	ai_regenerate_btn.pressed.connect(_on_ai_regenerate_prompt_pressed)
	prompt_hbox.add_child(ai_regenerate_btn)

	# Service and Model selection row
	var service_model_hbox := HBoxContainer.new()
	service_model_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(service_model_hbox)

	var service_label := Label.new()
	service_label.text = "Service:"
	service_model_hbox.add_child(service_label)

	ai_service_dropdown = OptionButton.new()
	if ai_services.is_empty():
		ai_service_dropdown.add_item("Zycroft")
		ai_service_dropdown.add_item("OpenAI")
		ai_service_dropdown.add_item("Claude")
	else:
		for service_name in ai_services.keys():
			ai_service_dropdown.add_item(service_name)
	ai_service_dropdown.custom_minimum_size.x = 120
	ai_service_dropdown.item_selected.connect(_on_ai_service_changed)
	service_model_hbox.add_child(ai_service_dropdown)

	var model_label := Label.new()
	model_label.text = "Model:"
	service_model_hbox.add_child(model_label)

	ai_model_dropdown = OptionButton.new()
	ai_model_dropdown.custom_minimum_size.x = 200
	service_model_hbox.add_child(ai_model_dropdown)

	# Initialize models for first service
	_update_models_for_service(0)

	# Status indicator
	var status_hbox := HBoxContainer.new()
	status_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(status_hbox)

	var status_title := Label.new()
	status_title.text = "Status:"
	status_hbox.add_child(status_title)

	ai_status_label = Label.new()
	ai_status_label.text = "Not saved"
	ai_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	status_hbox.add_child(ai_status_label)

	# Spacer to push limit label to right
	var limit_spacer := Control.new()
	limit_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_hbox.add_child(limit_spacer)

	# Prompt limit warning label
	prompt_limit_label = Label.new()
	prompt_limit_label.text = ""
	prompt_limit_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.2))
	status_hbox.add_child(prompt_limit_label)

	# AI Response text box (larger than prompt content)
	var response_label := Label.new()
	response_label.text = "AI Response:"
	main_vbox.add_child(response_label)

	ai_response_edit = TextEdit.new()
	ai_response_edit.placeholder_text = "AI generated response will appear here..."
	ai_response_edit.custom_minimum_size.y = 120
	ai_response_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ai_response_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	main_vbox.add_child(ai_response_edit)

	# Image grid
	var images_label := Label.new()
	images_label.text = "Generated Images:"
	main_vbox.add_child(images_label)

	var images_scroll := ScrollContainer.new()
	images_scroll.custom_minimum_size.y = 180
	images_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(images_scroll)

	ai_images_grid = GridContainer.new()
	ai_images_grid.columns = 4
	ai_images_grid.add_theme_constant_override("h_separation", 10)
	ai_images_grid.add_theme_constant_override("v_separation", 10)
	ai_images_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	images_scroll.add_child(ai_images_grid)

	_add_placeholder_images(4)

	# Image service and model selection row
	var image_service_hbox := HBoxContainer.new()
	image_service_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(image_service_hbox)

	var image_service_label := Label.new()
	image_service_label.text = "Image Service:"
	image_service_hbox.add_child(image_service_label)

	image_service_dropdown = OptionButton.new()
	if image_services.is_empty():
		image_service_dropdown.add_item("OpenAI")
		image_service_dropdown.add_item("Stability")
		image_service_dropdown.add_item("Midjourney")
	else:
		for service_name in image_services.keys():
			image_service_dropdown.add_item(service_name)
	image_service_dropdown.custom_minimum_size.x = 120
	image_service_dropdown.item_selected.connect(_on_image_service_changed)
	image_service_hbox.add_child(image_service_dropdown)

	var image_model_label := Label.new()
	image_model_label.text = "Model:"
	image_service_hbox.add_child(image_model_label)

	image_model_dropdown = OptionButton.new()
	image_model_dropdown.custom_minimum_size.x = 180
	image_service_hbox.add_child(image_model_dropdown)

	# Initialize models for first image service
	_update_image_models_for_service(0)

	# Image status row (like prompt status row)
	var image_status_hbox := HBoxContainer.new()
	image_status_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(image_status_hbox)

	var image_status_title := Label.new()
	image_status_title.text = "Status:"
	image_status_hbox.add_child(image_status_title)

	image_status_label = Label.new()
	image_status_label.text = "Not saved"
	image_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	image_status_hbox.add_child(image_status_label)

	# Spacer to push limit label to right
	var image_limit_spacer := Control.new()
	image_limit_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	image_status_hbox.add_child(image_limit_spacer)

	# Image limit warning label
	image_limit_label = Label.new()
	image_limit_label.text = ""
	image_limit_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.2))
	image_status_hbox.add_child(image_limit_label)

	# Image generation options row
	var image_options_hbox := HBoxContainer.new()
	image_options_hbox.add_theme_constant_override("separation", 15)
	main_vbox.add_child(image_options_hbox)

	# Mode label
	var mode_label := Label.new()
	mode_label.text = "Mode:"
	image_options_hbox.add_child(mode_label)

	# Replace radio button
	image_mode_replace = CheckBox.new()
	image_mode_replace.text = "Replace"
	image_mode_replace.button_pressed = true
	image_mode_replace.toggled.connect(func(pressed: bool):
		if pressed:
			image_mode_append.button_pressed = false
	)
	image_options_hbox.add_child(image_mode_replace)

	# Append radio button
	image_mode_append = CheckBox.new()
	image_mode_append.text = "Append"
	image_mode_append.button_pressed = false
	image_mode_append.toggled.connect(func(pressed: bool):
		if pressed:
			image_mode_replace.button_pressed = false
	)
	image_options_hbox.add_child(image_mode_append)

	# Spacer
	var options_spacer := Control.new()
	options_spacer.custom_minimum_size.x = 20
	image_options_hbox.add_child(options_spacer)

	# Count label
	var count_label := Label.new()
	count_label.text = "Count:"
	image_options_hbox.add_child(count_label)

	# Count spinbox
	image_count_spinbox = SpinBox.new()
	image_count_spinbox.min_value = 1
	image_count_spinbox.max_value = 10
	image_count_spinbox.value = 1
	image_count_spinbox.custom_minimum_size.x = 70
	image_options_hbox.add_child(image_count_spinbox)

	# Buttons
	var button_row := HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_END
	button_row.add_theme_constant_override("separation", 10)
	main_vbox.add_child(button_row)

	ai_generate_btn = Button.new()
	ai_generate_btn.text = "Regenerate Images"
	ai_generate_btn.custom_minimum_size = Vector2(140, 35)
	ai_generate_btn.pressed.connect(_on_ai_generate_pressed)
	button_row.add_child(ai_generate_btn)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(80, 35)
	save_btn.pressed.connect(_on_ai_save_pressed)
	button_row.add_child(save_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(80, 35)
	close_btn.pressed.connect(func():
		ai_prompts_dialog.hide()
		_stop_status_refresh()
	)
	button_row.add_child(close_btn)

	ai_prompts_dialog.close_requested.connect(func():
		ai_prompts_dialog.hide()
		_stop_status_refresh()
	)

	# Status refresh timer
	ai_status_timer = Timer.new()
	ai_status_timer.wait_time = 3.0
	ai_status_timer.timeout.connect(_on_status_timer_timeout)
	add_child(ai_status_timer)


func _add_placeholder_images(count: int) -> void:
	for i in range(count):
		_add_image_slot(null)


func _add_image_slot(texture: Texture2D) -> void:
	var slot_vbox := VBoxContainer.new()
	slot_vbox.add_theme_constant_override("separation", 5)

	var image_rect := TextureRect.new()
	image_rect.custom_minimum_size = Vector2(100, 100)
	image_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image_rect.texture = texture

	if not texture:
		var placeholder := ColorRect.new()
		placeholder.color = Color(0.3, 0.3, 0.3, 1)
		placeholder.custom_minimum_size = Vector2(100, 100)
		slot_vbox.add_child(placeholder)
	else:
		slot_vbox.add_child(image_rect)

	var checks_vbox := VBoxContainer.new()
	checks_vbox.add_theme_constant_override("separation", 2)
	slot_vbox.add_child(checks_vbox)

	var claude_check := CheckBox.new()
	claude_check.text = "Claude"
	claude_check.add_theme_font_size_override("font_size", 11)
	checks_vbox.add_child(claude_check)

	var user_check := CheckBox.new()
	user_check.text = "User"
	user_check.add_theme_font_size_override("font_size", 11)
	checks_vbox.add_child(user_check)

	ai_images_grid.add_child(slot_vbox)

	ai_prompt_images.append({
		"slot": slot_vbox,
		"image_rect": image_rect,
		"claude_check": claude_check,
		"user_check": user_check,
		"texture": texture
	})


func _on_ai_service_changed(index: int) -> void:
	_update_models_for_service(index)
	# Check usage limits for new service
	var selected_service = ai_service_dropdown.get_item_text(index)
	_fetch_usage_count(selected_service, "prompt")


func _update_models_for_service(service_index: int) -> void:
	ai_model_dropdown.clear()

	if ai_services.is_empty():
		# Fallback defaults if no config
		var default_models = {
			0: ["llama3.2:3b", "qwen2.5:7b-instruct", "mistral:7b"],
			1: ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"],
			2: ["claude-sonnet-4-20250514", "claude-opus-4-20250514", "claude-3-5-haiku-20241022"]
		}
		if default_models.has(service_index):
			for model in default_models[service_index]:
				ai_model_dropdown.add_item(model)
	else:
		var service_name = ai_service_dropdown.get_item_text(service_index)
		if ai_services.has(service_name):
			for model in ai_services[service_name]:
				ai_model_dropdown.add_item(model)


func _on_image_service_changed(index: int) -> void:
	_update_image_models_for_service(index)
	# Check usage limits for new image service
	var selected_service = image_service_dropdown.get_item_text(index)
	_fetch_usage_count(selected_service, "image")


func _update_image_models_for_service(service_index: int) -> void:
	image_model_dropdown.clear()

	if image_services.is_empty():
		# Fallback defaults if no config
		var default_models = {
			0: ["gpt-image-1", "dall-e-3"],
			1: ["stable-diffusion-xl", "stable-diffusion-3"],
			2: ["midjourney-v6", "midjourney-v5"]
		}
		if default_models.has(service_index):
			for model in default_models[service_index]:
				image_model_dropdown.add_item(model)
	else:
		var service_name = image_service_dropdown.get_item_text(service_index)
		if image_services.has(service_name):
			for model in image_services[service_name]:
				image_model_dropdown.add_item(model)


func _clear_ai_images() -> void:
	# Cancel pending image loads
	for req_data in pending_image_loads:
		if req_data.has("request") and is_instance_valid(req_data["request"]):
			req_data["request"].queue_free()
	pending_image_loads.clear()

	for child in ai_images_grid.get_children():
		child.queue_free()
	ai_prompt_images.clear()
	# Re-add placeholders
	_add_placeholder_images(4)


func _load_images_from_urls(images_data: Array) -> void:
	"""Load images from URL data array"""
	_clear_ai_images()

	# Clear the placeholder images
	for child in ai_images_grid.get_children():
		child.queue_free()
	ai_prompt_images.clear()

	if images_data.is_empty():
		_add_placeholder_images(4)
		return

	# Load each image
	for img_data in images_data:
		var url = img_data.get("url", "")
		if url.is_empty():
			continue
		_load_image_from_url(url, img_data.get("index", 0))


func _load_image_from_url(url: String, index: int) -> void:
	"""Load a single image from URL"""
	# Create a placeholder slot first
	var slot_vbox := VBoxContainer.new()
	slot_vbox.add_theme_constant_override("separation", 5)

	# Loading placeholder
	var placeholder := ColorRect.new()
	placeholder.color = Color(0.25, 0.25, 0.35, 1)
	placeholder.custom_minimum_size = Vector2(100, 100)
	slot_vbox.add_child(placeholder)

	# Loading label
	var loading_label := Label.new()
	loading_label.text = "Loading..."
	loading_label.add_theme_font_size_override("font_size", 10)
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slot_vbox.add_child(loading_label)

	# Checkboxes container
	var checks_vbox := VBoxContainer.new()
	checks_vbox.add_theme_constant_override("separation", 2)
	slot_vbox.add_child(checks_vbox)

	var claude_check := CheckBox.new()
	claude_check.text = "Claude"
	claude_check.add_theme_font_size_override("font_size", 11)
	checks_vbox.add_child(claude_check)

	var user_check := CheckBox.new()
	user_check.text = "User"
	user_check.add_theme_font_size_override("font_size", 11)
	checks_vbox.add_child(user_check)

	ai_images_grid.add_child(slot_vbox)

	# Track image data
	var image_entry = {
		"slot": slot_vbox,
		"placeholder": placeholder,
		"loading_label": loading_label,
		"claude_check": claude_check,
		"user_check": user_check,
		"texture": null,
		"url": url,
		"index": index
	}
	ai_prompt_images.append(image_entry)

	# Create HTTPRequest for this image
	var img_http_request := HTTPRequest.new()
	add_child(img_http_request)

	var request_data = {
		"request": img_http_request,
		"slot": slot_vbox,
		"placeholder": placeholder,
		"loading_label": loading_label,
		"image_entry": image_entry
	}
	pending_image_loads.append(request_data)

	img_http_request.request_completed.connect(
		func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
			_on_image_loaded(result, response_code, body, request_data)
	)

	var error = img_http_request.request(url)
	if error != OK:
		loading_label.text = "Error"
		print("Failed to request image: ", url)


func _on_image_loaded(result: int, response_code: int, body: PackedByteArray, request_data: Dictionary) -> void:
	"""Handle loaded image data"""
	# Clean up the request
	if request_data.has("request") and is_instance_valid(request_data["request"]):
		request_data["request"].queue_free()
	pending_image_loads.erase(request_data)

	var slot = request_data.get("slot")
	var placeholder = request_data.get("placeholder")
	var loading_label = request_data.get("loading_label")
	var image_entry = request_data.get("image_entry")

	if not is_instance_valid(slot):
		return

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		if is_instance_valid(loading_label):
			loading_label.text = "Failed"
		print("Failed to load image: HTTP ", response_code)
		return

	# Create image from bytes
	var image := Image.new()
	var error = image.load_png_from_buffer(body)

	if error != OK:
		# Try JPEG format
		error = image.load_jpg_from_buffer(body)

	if error != OK:
		# Try WebP format
		error = image.load_webp_from_buffer(body)

	if error != OK:
		if is_instance_valid(loading_label):
			loading_label.text = "Invalid"
		print("Failed to parse image data")
		return

	# Create texture from image
	var texture := ImageTexture.create_from_image(image)

	# Replace placeholder with actual image
	if is_instance_valid(placeholder):
		var image_rect := TextureRect.new()
		image_rect.custom_minimum_size = Vector2(100, 100)
		image_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		image_rect.texture = texture

		# Get the index of placeholder in slot
		var idx = placeholder.get_index()
		slot.remove_child(placeholder)
		placeholder.queue_free()
		slot.add_child(image_rect)
		slot.move_child(image_rect, idx)

		# Update image entry
		if image_entry:
			image_entry["texture"] = texture
			image_entry["image_rect"] = image_rect
			image_entry.erase("placeholder")

	# Remove loading label
	if is_instance_valid(loading_label):
		loading_label.queue_free()
		if image_entry:
			image_entry.erase("loading_label")

	print("Image loaded successfully")


func _on_ai_regenerate_prompt_pressed() -> void:
	if current_prompt_id.is_empty():
		ai_response_edit.text = "Error: No prompt selected to regenerate."
		return

	if current_project_id < 0 or current_object_id < 0:
		ai_response_edit.text = "Error: Project or object ID not set."
		return

	var project_object_id = str(current_project_id) + "_" + str(current_object_id)

	# Update status to "generate" in DynamoDB - this triggers AI worker processing
	var request_body = JSON.stringify({
		"TableName": ai_prompts_table,
		"Key": {
			"projectObjectID": {"S": project_object_id},
			"promptID": {"S": current_prompt_id}
		},
		"UpdateExpression": "SET #status = :generate",
		"ExpressionAttributeNames": {"#status": "status"},
		"ExpressionAttributeValues": {":generate": {"S": "generate"}}
	})

	var headers = PackedStringArray([
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.UpdateItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	])

	ai_response_edit.text = "Regenerating response..."
	_update_status_display("generate")
	_start_status_refresh()

	dynamodb_http_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)
	print("Regenerating prompt: ", current_prompt_id)


func _on_claude_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	ai_regenerate_btn.disabled = false

	# Check for HTTP request errors
	if result != HTTPRequest.RESULT_SUCCESS:
		var error_names = {
			HTTPRequest.RESULT_CANT_CONNECT: "Can't connect to server",
			HTTPRequest.RESULT_CANT_RESOLVE: "Can't resolve hostname",
			HTTPRequest.RESULT_CONNECTION_ERROR: "Connection error",
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "TLS handshake error",
			HTTPRequest.RESULT_NO_RESPONSE: "No response from server",
			HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: "Response too large",
			HTTPRequest.RESULT_REQUEST_FAILED: "Request failed",
			HTTPRequest.RESULT_TIMEOUT: "Request timed out"
		}
		ai_response_edit.text = "Error: " + error_names.get(result, "Unknown error " + str(result))
		return

	var response_text = body.get_string_from_utf8()
	var json = JSON.parse_string(response_text)

	if response_code == 200 and json:
		if json.has("response"):
			# Normalize line breaks - replace multiple newlines with single newline
			var response = json["response"] as String
			while response.contains("\n\n"):
				response = response.replace("\n\n", "\n")
			ai_response_edit.text = response.strip_edges()
		else:
			ai_response_edit.text = "Error: Unexpected response format\n" + response_text.left(500)
	else:
		var error_msg = "Error: HTTP " + str(response_code)
		if json and json.has("error"):
			error_msg += " - " + str(json["error"])
		elif response_text.length() > 0:
			error_msg += "\n" + response_text.left(200)
		ai_response_edit.text = error_msg


func _on_ai_generate_pressed() -> void:
	if current_prompt_id.is_empty():
		print("Error: No prompt selected for image generation.")
		return

	if current_project_id < 0 or current_object_id < 0:
		print("Error: Project or object ID not set.")
		return

	var project_object_id = str(current_project_id) + "_" + str(current_object_id)

	# Get image generation settings
	var image_mode = "replace" if image_mode_replace.button_pressed else "append"
	var image_count = int(image_count_spinbox.value)

	# Update imageStatus to "generate" with mode and count in DynamoDB
	var request_body = JSON.stringify({
		"TableName": ai_prompts_table,
		"Key": {
			"projectObjectID": {"S": project_object_id},
			"promptID": {"S": current_prompt_id}
		},
		"UpdateExpression": "SET #imageStatus = :generate, #imageMode = :mode, #imageCount = :count",
		"ExpressionAttributeNames": {
			"#imageStatus": "imageStatus",
			"#imageMode": "imageMode",
			"#imageCount": "imageCount"
		},
		"ExpressionAttributeValues": {
			":generate": {"S": "generate"},
			":mode": {"S": image_mode},
			":count": {"N": str(image_count)}
		}
	})

	var headers = PackedStringArray([
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.UpdateItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	])

	_update_image_status_display("generate")
	_start_status_refresh()

	dynamodb_http_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)
	print("Regenerating %d images (mode: %s) for prompt: %s" % [image_count, image_mode, current_prompt_id])


func _on_ai_save_pressed() -> void:
	if dynamodb_endpoint.is_empty():
		print("Error: DynamoDB endpoint not configured")
		return

	if current_project_id < 0 or current_object_id < 0:
		print("Error: Project or object ID not set")
		return

	# Generate a unique prompt ID if not editing existing
	if current_prompt_id.is_empty():
		current_prompt_id = str(Time.get_unix_time_from_system()) + "_" + str(randi())

	var selected_service = ai_service_dropdown.get_item_text(ai_service_dropdown.selected)
	var selected_model = ai_model_dropdown.get_item_text(ai_model_dropdown.selected)
	var selected_image_service = image_service_dropdown.get_item_text(image_service_dropdown.selected)
	var selected_image_model = image_model_dropdown.get_item_text(image_model_dropdown.selected)

	# Build the composite key
	var project_object_id = str(current_project_id) + "_" + str(current_object_id)

	# Build DynamoDB PutItem request
	# Use "idle" status on save - only "generate" triggers AI processing
	var item = {
		"projectObjectID": {"S": project_object_id},
		"promptID": {"S": current_prompt_id},
		"title": {"S": ai_prompt_title_edit.text},
		"content": {"S": ai_prompt_content_edit.text},
		"service": {"S": selected_service},
		"model": {"S": selected_model},
		"imageService": {"S": selected_image_service},
		"imageModel": {"S": selected_image_model},
		"imageStatus": {"S": "idle"},
		"response": {"S": ai_response_edit.text},
		"status": {"S": "idle"},
		"createdAt": {"N": str(Time.get_unix_time_from_system())},
		"containerName": {"S": container_name if not container_name.is_empty() else container_type},
		"projectID": {"N": str(current_project_id)},
		"objectID": {"N": str(current_object_id)}
	}

	# Preserve generated images if they exist
	if not current_generated_images.is_empty():
		item["generatedImages"] = {"S": current_generated_images}

	var request_body = JSON.stringify({
		"TableName": ai_prompts_table,
		"Item": item
	})

	var headers = PackedStringArray([
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.PutItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	])

	var url = dynamodb_endpoint
	print("Saving AI prompt to DynamoDB: ", project_object_id, " / ", current_prompt_id)

	# Update status to idle (not triggering generation)
	_update_status_display("idle")
	_update_image_status_display("idle")

	dynamodb_http_request.request(url, headers, HTTPClient.METHOD_POST, request_body)


func _on_dynamodb_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		print("DynamoDB request failed with result: ", result)
		if is_loading_prompts:
			is_loading_prompts = false
			saved_prompts_dropdown.clear()
			saved_prompts_dropdown.add_item("-- New Prompt --")
			saved_prompts_dropdown.disabled = false
		return

	var response_text = body.get_string_from_utf8()
	var json = JSON.parse_string(response_text)

	if response_code == 200:
		# Check if this is a Scan response (loading prompts)
		if json and json.has("Items"):
			_handle_prompts_loaded(json["Items"])
		else:
			# This is a PutItem response (saving)
			print("AI prompt saved successfully to DynamoDB")
			# Refresh prompts list to show the saved prompt
			_fetch_saved_prompts()
	else:
		print("DynamoDB error: HTTP ", response_code, " - ", response_text)
		if json and json.has("message"):
			print("Error message: ", json["message"])
		if is_loading_prompts:
			is_loading_prompts = false
			saved_prompts_dropdown.clear()
			saved_prompts_dropdown.add_item("-- New Prompt --")
			saved_prompts_dropdown.disabled = false


func _handle_prompts_loaded(items: Array) -> void:
	is_loading_prompts = false
	saved_prompts_list.clear()
	saved_prompts_dropdown.clear()
	saved_prompts_dropdown.add_item("-- New Prompt --")

	for item in items:
		var prompt_data = {}
		for key in item.keys():
			var value = item[key]
			if value.has("S"):
				prompt_data[key] = value["S"]
			elif value.has("N"):
				prompt_data[key] = value["N"]
		saved_prompts_list.append(prompt_data)

	# Sort by createdAt descending (newest first)
	saved_prompts_list.sort_custom(func(a, b):
		var a_time = float(a.get("createdAt", "0"))
		var b_time = float(b.get("createdAt", "0"))
		return a_time > b_time
	)

	# Add to dropdown and find current prompt index
	var current_index = 0  # Default to "New Prompt"
	for i in range(saved_prompts_list.size()):
		var prompt_data = saved_prompts_list[i]
		var title = prompt_data.get("title", "Untitled")
		if title.is_empty():
			title = "Untitled"
		saved_prompts_dropdown.add_item(title)
		# Check if this is the currently selected prompt
		if prompt_data.get("promptID", "") == current_prompt_id:
			current_index = i + 1  # +1 because "New Prompt" is at index 0

	saved_prompts_dropdown.disabled = false
	# Restore selection without triggering the signal
	saved_prompts_dropdown.selected = current_index
	print("Loaded ", saved_prompts_list.size(), " saved prompts")


func _on_saved_prompt_selected(index: int) -> void:
	_stop_status_refresh()

	if index == 0:
		# "New Prompt" selected - clear fields
		current_prompt_id = ""
		current_generated_images = ""
		ai_prompt_title_edit.text = ""
		ai_prompt_content_edit.text = ""
		ai_response_edit.text = ""
		_clear_ai_images()
		_update_status_display("new")
		_update_image_status_display("new")
		_update_regenerate_button_states()
		return

	# Get the saved prompt data (index - 1 because first item is "New Prompt")
	var prompt_index = index - 1
	if prompt_index >= 0 and prompt_index < saved_prompts_list.size():
		var prompt_data = saved_prompts_list[prompt_index]
		current_prompt_id = prompt_data.get("promptID", "")
		ai_prompt_title_edit.text = prompt_data.get("title", "")
		ai_prompt_content_edit.text = prompt_data.get("content", "")
		ai_response_edit.text = prompt_data.get("response", "")

		# Set service dropdown if saved
		var saved_service = prompt_data.get("service", "")
		if not saved_service.is_empty():
			for i in range(ai_service_dropdown.item_count):
				if ai_service_dropdown.get_item_text(i) == saved_service:
					ai_service_dropdown.selected = i
					_update_models_for_service(i)
					break

		# Set model dropdown if saved
		var saved_model = prompt_data.get("model", "")
		if not saved_model.is_empty():
			for i in range(ai_model_dropdown.item_count):
				if ai_model_dropdown.get_item_text(i) == saved_model:
					ai_model_dropdown.selected = i
					break

		# Set image service dropdown if saved
		var saved_image_service = prompt_data.get("imageService", "")
		if not saved_image_service.is_empty():
			for i in range(image_service_dropdown.item_count):
				if image_service_dropdown.get_item_text(i) == saved_image_service:
					image_service_dropdown.selected = i
					_update_image_models_for_service(i)
					break

		# Set image model dropdown if saved
		var saved_image_model = prompt_data.get("imageModel", "")
		if not saved_image_model.is_empty():
			for i in range(image_model_dropdown.item_count):
				if image_model_dropdown.get_item_text(i) == saved_image_model:
					image_model_dropdown.selected = i
					break

		# Update status and start refresh if needed
		var status = prompt_data.get("status", "")
		_update_status_display(status)

		# Update image status
		var image_status = prompt_data.get("imageStatus", "")
		_update_image_status_display(image_status)

		# Load generated images if any
		var generated_images_json = prompt_data.get("generatedImages", "")
		current_generated_images = generated_images_json  # Preserve for saving
		if not generated_images_json.is_empty():
			var json = JSON.new()
			var parse_result = json.parse(generated_images_json)
			if parse_result == OK and json.data is Array:
				_load_images_from_urls(json.data)
			else:
				_clear_ai_images()
		else:
			_clear_ai_images()

		# Start refresh if either prompt or image is being processed
		if status == "generate" or status == "processing" or image_status == "generate" or image_status == "processing":
			_start_status_refresh()

		# Update button states based on loaded prompt
		_update_regenerate_button_states()

		print("Loaded prompt: ", current_prompt_id)


func _update_status_display(status: String) -> void:
	current_prompt_status = status
	if not ai_status_label:
		return

	match status:
		"new", "":
			ai_status_label.text = "Not saved"
			ai_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		"idle":
			ai_status_label.text = "Saved"
			ai_status_label.add_theme_color_override("font_color", Color(0.5, 0.7, 0.5))
		"generate":
			ai_status_label.text = "⏳ Queued..."
			ai_status_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		"processing":
			ai_status_label.text = "⚙️ Processing..."
			ai_status_label.add_theme_color_override("font_color", Color(0.2, 0.6, 1.0))
		"completed":
			ai_status_label.text = "✓ Completed"
			ai_status_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
		"error":
			ai_status_label.text = "✗ Error"
			ai_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		_:
			ai_status_label.text = status
			ai_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))


func _update_image_status_display(status: String) -> void:
	current_image_status = status
	if not image_status_label:
		return

	match status:
		"new", "":
			image_status_label.text = "Not saved"
			image_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		"idle":
			image_status_label.text = "Saved"
			image_status_label.add_theme_color_override("font_color", Color(0.5, 0.7, 0.5))
		"generate":
			image_status_label.text = "⏳ Queued..."
			image_status_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		"processing":
			image_status_label.text = "⚙️ Processing..."
			image_status_label.add_theme_color_override("font_color", Color(0.2, 0.6, 1.0))
		"completed":
			image_status_label.text = "✓ Completed"
			image_status_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
		"error":
			image_status_label.text = "✗ Error"
			image_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		_:
			image_status_label.text = status
			image_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))


func _start_status_refresh() -> void:
	if ai_status_timer and not ai_status_timer.is_stopped():
		return
	if ai_status_timer:
		ai_status_timer.start()
		print("Started status refresh timer")


func _stop_status_refresh() -> void:
	if ai_status_timer and not ai_status_timer.is_stopped():
		ai_status_timer.stop()
		print("Stopped status refresh timer")


func _on_status_timer_timeout() -> void:
	if current_prompt_id.is_empty() or current_project_id < 0 or current_object_id < 0:
		_stop_status_refresh()
		return

	_fetch_prompt_status()


func _fetch_prompt_status() -> void:
	if dynamodb_endpoint.is_empty():
		return

	var project_object_id = str(current_project_id) + "_" + str(current_object_id)

	var request_body = JSON.stringify({
		"TableName": ai_prompts_table,
		"Key": {
			"projectObjectID": {"S": project_object_id},
			"promptID": {"S": current_prompt_id}
		}
	})

	var headers = PackedStringArray([
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.GetItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	])

	# Use a separate HTTPRequest for status polling
	var status_request = HTTPRequest.new()
	add_child(status_request)
	status_request.request_completed.connect(func(result, code, _hdrs, body):
		_handle_status_response(result, code, body)
		status_request.queue_free()
	)
	status_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)


func _handle_status_response(result: int, response_code: int, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return

	var response_text = body.get_string_from_utf8()
	var json = JSON.parse_string(response_text)
	if not json or not json.has("Item"):
		return

	var item = json["Item"]
	var status = item.get("status", {}).get("S", "")
	var response = item.get("response", {}).get("S", "")
	var image_status = item.get("imageStatus", {}).get("S", "")

	# Update the displays
	_update_status_display(status)
	_update_image_status_display(image_status)

	# Handle prompt status
	if status == "completed":
		if not response.is_empty() and ai_response_edit:
			ai_response_edit.text = response
			# Update button states since we now have a response
			_update_regenerate_button_states()
	elif status == "error":
		var error_msg = item.get("error", {}).get("S", "Unknown error")
		if ai_response_edit:
			ai_response_edit.text = "Error: " + error_msg

	# Handle image status - load images when completed
	if image_status == "completed":
		var generated_images_json = item.get("generatedImages", {}).get("S", "")
		current_generated_images = generated_images_json  # Preserve for saving
		if not generated_images_json.is_empty():
			var json_parser = JSON.new()
			var parse_result = json_parser.parse(generated_images_json)
			if parse_result == OK and json_parser.data is Array:
				_load_images_from_urls(json_parser.data)

	# Stop polling only if both prompt and image processing are done
	var prompt_done = status in ["idle", "completed", "error", ""]
	var image_done = image_status in ["idle", "completed", "error", ""]
	if prompt_done and image_done:
		_stop_status_refresh()
		# Refresh the prompts list to update dropdown
		_fetch_saved_prompts()


# Daily limit checking functions

func _get_today_date_string() -> String:
	var datetime = Time.get_datetime_dict_from_system(true)  # UTC
	return "%04d-%02d-%02d" % [datetime["year"], datetime["month"], datetime["day"]]


func _check_usage_limits() -> void:
	# Check prompt limit for selected service
	var selected_service = ai_service_dropdown.get_item_text(ai_service_dropdown.selected)
	_fetch_usage_count(selected_service, "prompt")

	# Check image limit for selected image service
	var selected_image_service = image_service_dropdown.get_item_text(image_service_dropdown.selected)
	_fetch_usage_count(selected_image_service, "image")


func _fetch_usage_count(service: String, usage_type: String) -> void:
	if dynamodb_endpoint.is_empty():
		return

	var date_service = "%s_%s_%s" % [_get_today_date_string(), service, usage_type]

	var request_body = JSON.stringify({
		"TableName": usage_tracking_table,
		"Key": {
			"dateService": {"S": date_service}
		}
	})

	var headers = PackedStringArray([
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.GetItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	])

	# Create a one-time HTTPRequest for usage check
	var usage_request = HTTPRequest.new()
	add_child(usage_request)
	usage_request.request_completed.connect(
		func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
			_handle_usage_response(result, response_code, body, service, usage_type)
			usage_request.queue_free()
	)
	usage_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)


func _handle_usage_response(result: int, response_code: int, body: PackedByteArray, service: String, usage_type: String) -> void:
	var current_count = 0

	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		var response_text = body.get_string_from_utf8()
		var json = JSON.parse_string(response_text)
		if json and json.has("Item"):
			current_count = int(json["Item"].get("count", {}).get("N", "0"))

	# Get the limit for this service
	var limit: int
	if usage_type == "image":
		limit = daily_image_limits.get(service, daily_image_limits.get("default", 3))
	else:
		limit = daily_limits.get(service, daily_limits.get("default", 5))

	# Update UI based on usage type
	if usage_type == "prompt":
		_update_prompt_limit_display(current_count, limit, service)
	else:
		_update_image_limit_display(current_count, limit, service)


func _update_prompt_limit_display(current_count: int, limit: int, service: String) -> void:
	if not prompt_limit_label:
		return

	if current_count >= limit:
		prompt_limit_label.text = "Limit Reached (%d/%d)" % [current_count, limit]
		prompt_limit_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		if ai_regenerate_btn:
			ai_regenerate_btn.disabled = true
			ai_regenerate_btn.tooltip_text = "Daily limit reached for %s" % service
	else:
		prompt_limit_label.text = "Usage: %d/%d" % [current_count, limit]
		prompt_limit_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
		if ai_regenerate_btn:
			ai_regenerate_btn.disabled = false
			ai_regenerate_btn.tooltip_text = ""


func _update_image_limit_display(current_count: int, limit: int, service: String) -> void:
	if not image_limit_label:
		return

	if current_count >= limit:
		image_limit_label.text = "Limit Reached (%d/%d)" % [current_count, limit]
		image_limit_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		if ai_generate_btn:
			ai_generate_btn.disabled = true
			ai_generate_btn.tooltip_text = "Daily limit reached for %s" % service
	else:
		image_limit_label.text = "Usage: %d/%d" % [current_count, limit]
		image_limit_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
		if ai_generate_btn:
			ai_generate_btn.disabled = false
			ai_generate_btn.tooltip_text = ""
