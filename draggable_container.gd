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
			widget = TextureRect.new()
			widget.custom_minimum_size = Vector2(64, 64)
			widget.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
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

	# Restore size properties
	if properties.has("minSizeX") or properties.has("minSizeY"):
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
