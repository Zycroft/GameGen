class_name SceneHierarchy
extends Panel

signal node_selected(node_data: Dictionary)
# signal node_reparented(node_id: int, new_parent_id: int)  # TODO: implement drag reparenting
signal node_deleted(node_id: int)
signal add_node_requested(parent_id: int, node_type: String)
signal properties_requested(node_id: int, node_data: Dictionary)
signal project_selected(project_data: Dictionary)
signal save_requested
signal load_requested

var dragging := false
var drag_offset := Vector2.ZERO

# Resizing
var resizing := false
var resize_direction := Vector2.ZERO
var min_size := Vector2(200, 250)
var resize_margin := 12

# Minimize/restore
var minimized := false
var restored_size := Vector2.ZERO
var title_bar_height := 28.0

# Tree item tracking
var tree_items: Dictionary = {}  # node_id -> TreeItem
var selected_node_id: int = -1
var _selecting_programmatically := false  # Prevents pruning when selecting from viewport

# Node type definitions
const NODE_CATEGORIES := {
	"2D": ["Node2D", "Sprite2D", "AnimatedSprite2D"],
	"Control": ["Control", "VBoxContainer", "HBoxContainer", "GridContainer",
				"FlowContainer", "MarginContainer", "PanelContainer",
				"CenterContainer", "AspectRatioContainer", "HSplitContainer",
				"VSplitContainer", "TabContainer"],
	"UI": ["Button", "Label", "LineEdit", "TextEdit", "CheckBox", "CheckButton",
		   "OptionButton", "SpinBox", "HSlider", "VSlider", "ProgressBar",
		   "ColorRect", "TextureRect", "ColorPickerButton", "RichTextLabel"],
	"Animation": ["AnimationPlayer"]
}

const NODE_COLORS := {
	# 2D Nodes
	"Node2D": Color(0.4, 0.7, 0.4),
	"Sprite2D": Color(0.5, 0.8, 0.5),
	"AnimatedSprite2D": Color(0.4, 0.9, 0.6),
	# Control Nodes (containers)
	"Control": Color(0.3, 0.5, 0.7),
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

const NODE_ICONS := {
	"Node2D": "2D",
	"Sprite2D": "SPR",
	"AnimatedSprite2D": "ANI",
	"Control": "CTL",
	"VBoxContainer": "VB",
	"HBoxContainer": "HB",
	"GridContainer": "GR",
	"FlowContainer": "FL",
	"MarginContainer": "MG",
	"PanelContainer": "PN",
	"CenterContainer": "CN",
	"AspectRatioContainer": "AR",
	"HSplitContainer": "HS",
	"VSplitContainer": "VS",
	"TabContainer": "TB",
	"Button": "BTN",
	"Label": "LBL",
	"LineEdit": "INP",
	"TextEdit": "TXT",
	"CheckBox": "CHK",
	"CheckButton": "TOG",
	"OptionButton": "OPT",
	"SpinBox": "NUM",
	"HSlider": "SLD",
	"VSlider": "SLD",
	"ProgressBar": "PRG",
	"ColorRect": "CLR",
	"TextureRect": "TEX",
	"ColorPickerButton": "CLR",
	"RichTextLabel": "RTF",
	"AnimationPlayer": "ANM"
}

@onready var title_bar: Panel = $TitleBar
@onready var title_label: Label = $TitleBar/HBox/Label
@onready var minimize_button: Button = $TitleBar/HBox/MinimizeButton
@onready var button_row: HBoxContainer = $ButtonRow
@onready var project_button: Button = $ButtonRow/ProjectButton
@onready var save_button: Button = $ButtonRow/SaveButton
@onready var tree: Tree = $Content/Tree
@onready var add_node_popup: PopupMenu

var context_menu: PopupMenu
var add_child_popup: PopupMenu
var context_node_id: int = -1

# Project management
var http_request: HTTPRequest
var projects_list: Array = []
var selected_project_index: int = -1
var current_project_name: String = ""
var projects_dialog: Window
var project_item_list: ItemList
var save_confirm_dialog: ConfirmationDialog


func _ready() -> void:
	title_bar.gui_input.connect(_on_title_bar_gui_input)
	gui_input.connect(_on_panel_clicked)
	minimize_button.pressed.connect(_toggle_minimize)

	# Connect buttons
	project_button.pressed.connect(_on_project_button_pressed)
	save_button.pressed.connect(_on_save_button_pressed)

	# Setup tree
	tree.hide_root = false
	tree.allow_reselect = true
	tree.select_mode = Tree.SELECT_SINGLE
	tree.set_column_expand(0, true)
	tree.item_selected.connect(_on_tree_item_selected)
	tree.item_activated.connect(_on_tree_item_activated)
	tree.gui_input.connect(_on_tree_gui_input)

	# Create context menu
	_create_context_menu()
	_create_add_child_popup()

	# Create HTTPRequest for DynamoDB calls
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_request_completed)

	# Create project selection dialog
	_create_projects_dialog()

	# Create save confirmation dialog
	_create_save_confirm_dialog()


func _create_context_menu() -> void:
	context_menu = PopupMenu.new()
	context_menu.add_item("Properties...", 0)
	context_menu.add_separator()
	context_menu.add_item("Add Child Node...", 1)
	context_menu.add_separator()
	context_menu.add_item("Rename", 2)
	context_menu.add_item("Duplicate", 3)
	context_menu.add_separator()
	context_menu.add_item("Delete", 4)
	context_menu.id_pressed.connect(_on_context_menu_action)
	add_child(context_menu)


func _create_add_child_popup() -> void:
	add_child_popup = PopupMenu.new()
	add_child_popup.name = "AddChildPopup"

	# Add categories as submenus
	var idx := 0
	for category in NODE_CATEGORIES.keys():
		var submenu := PopupMenu.new()
		submenu.name = category + "Submenu"

		for node_type in NODE_CATEGORIES[category]:
			submenu.add_item(node_type)

		submenu.id_pressed.connect(_on_add_node_type_selected.bind(category))
		add_child_popup.add_child(submenu)
		add_child_popup.add_submenu_item(category, category + "Submenu", idx)
		idx += 1

	add_child(add_child_popup)


func _on_add_node_type_selected(idx: int, category: String) -> void:
	var node_type = NODE_CATEGORIES[category][idx]
	add_node_requested.emit(context_node_id, node_type)


func _on_context_menu_action(id: int) -> void:
	match id:
		0:  # Properties
			if tree_items.has(context_node_id):
				var item = tree_items[context_node_id]
				var node_data = item.get_meta("node_data", {})
				properties_requested.emit(context_node_id, node_data)
		1:  # Add Child Node
			add_child_popup.position = context_menu.position
			add_child_popup.popup()
		2:  # Rename
			_start_rename(context_node_id)
		3:  # Duplicate
			print("Duplicate not yet implemented")
		4:  # Delete
			node_deleted.emit(context_node_id)


func _start_rename(node_id: int) -> void:
	if tree_items.has(node_id):
		var item = tree_items[node_id]
		item.set_editable(0, true)
		tree.edit_selected()


func _on_tree_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			var item = tree.get_item_at_position(event.position)
			if item:
				context_node_id = item.get_meta("node_id", -1)
				context_menu.position = Vector2i(get_global_mouse_position())
				context_menu.popup()


func _on_tree_item_selected() -> void:
	var item = tree.get_selected()
	if item:
		selected_node_id = item.get_meta("node_id", -1)
		var node_data = item.get_meta("node_data", {})
		# Only emit signal (trigger pruning) if selected from tree, not programmatically
		if not _selecting_programmatically:
			node_selected.emit(node_data)


func _on_tree_item_activated() -> void:
	# Double-click - could open properties or expand/collapse
	pass


func _on_panel_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		move_to_front()


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
		$ButtonRow.visible = true
		$Content.visible = true
		$ResizeGrip.visible = true
		minimize_button.text = "−"
		if current_project_name.is_empty():
			title_label.text = "Project:"
		else:
			title_label.text = "Project: " + current_project_name
		minimized = false
	else:
		# Minimize
		restored_size = size
		if current_project_name.is_empty():
			title_label.text = "Proj:"
		else:
			title_label.text = "Proj: " + current_project_name
		# Calculate minimum width: label width + button + padding
		var min_width = title_label.get_minimum_size().x + minimize_button.size.x + 24
		size = Vector2(min_width, title_bar_height + 8)
		$ButtonRow.visible = false
		$Content.visible = false
		$ResizeGrip.visible = false
		minimize_button.text = "+"
		minimized = true


func get_node_color(node_type: String) -> Color:
	return NODE_COLORS.get(node_type, Color(0.5, 0.5, 0.5))


func get_node_icon(node_type: String) -> String:
	return NODE_ICONS.get(node_type, "???")


# Build tree from scene data
func build_tree(scene_data: Dictionary) -> void:
	tree.clear()
	tree_items.clear()

	if scene_data.is_empty():
		return

	var root_item = tree.create_item()
	_build_tree_item(root_item, scene_data)


func _build_tree_item(tree_item: TreeItem, node_data: Dictionary) -> void:
	var node_type = node_data.get("type", "Node")
	var node_name = node_data.get("name", node_type)
	var node_id = node_data.get("id", -1)

	# Set display text with icon prefix
	var icon = get_node_icon(node_type)
	var display_text = "[%s] %s" % [icon, node_name]
	tree_item.set_text(0, display_text)

	# Set color based on node type
	var color = get_node_color(node_type)
	tree_item.set_custom_color(0, color)

	# Store metadata
	tree_item.set_meta("node_id", node_id)
	tree_item.set_meta("node_type", node_type)
	tree_item.set_meta("node_data", node_data)

	# Track in dictionary
	if node_id >= 0:
		tree_items[node_id] = tree_item

	# Build children
	var children = node_data.get("children", [])
	for child_data in children:
		var child_item = tree.create_item(tree_item)
		_build_tree_item(child_item, child_data)

	# Build widgets (for containers)
	var widgets = node_data.get("widgets", [])
	for widget_data in widgets:
		var widget_item = tree.create_item(tree_item)
		_build_tree_item(widget_item, widget_data)


func select_node(node_id: int) -> void:
	if tree_items.has(node_id):
		var item = tree_items[node_id]
		_selecting_programmatically = true
		item.select(0)
		tree.scroll_to_item(item)
		_selecting_programmatically = false
		selected_node_id = node_id


func refresh_node(node_id: int, node_data: Dictionary) -> void:
	if tree_items.has(node_id):
		var item = tree_items[node_id]
		var node_type = node_data.get("type", "Node")
		var node_name = node_data.get("name", node_type)
		var icon = get_node_icon(node_type)
		item.set_text(0, "[%s] %s" % [icon, node_name])
		item.set_meta("node_data", node_data)


func add_tree_node(parent_id: int, node_data: Dictionary) -> void:
	var parent_item: TreeItem
	if parent_id < 0:
		parent_item = tree.get_root()
	elif tree_items.has(parent_id):
		parent_item = tree_items[parent_id]
	else:
		return

	if parent_item:
		var child_item = tree.create_item(parent_item)
		_build_tree_item(child_item, node_data)


func remove_tree_node(node_id: int) -> void:
	if tree_items.has(node_id):
		var item = tree_items[node_id]
		item.free()
		tree_items.erase(node_id)


# ============================================
# Project Management Functions
# ============================================

func _create_projects_dialog() -> void:
	projects_dialog = Window.new()
	projects_dialog.title = "Select Project"
	projects_dialog.size = Vector2i(400, 300)
	projects_dialog.transient = true
	projects_dialog.exclusive = true
	projects_dialog.visible = false
	add_child(projects_dialog)

	var main_vbox := VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 10)
	main_vbox.offset_left = 10
	main_vbox.offset_top = 10
	main_vbox.offset_right = -10
	main_vbox.offset_bottom = -10
	projects_dialog.add_child(main_vbox)

	project_item_list = ItemList.new()
	project_item_list.select_mode = ItemList.SELECT_SINGLE
	project_item_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	project_item_list.item_selected.connect(_on_project_item_selected)
	project_item_list.item_activated.connect(_on_project_item_activated)
	main_vbox.add_child(project_item_list)

	var button_container := HBoxContainer.new()
	button_container.alignment = BoxContainer.ALIGNMENT_END
	button_container.add_theme_constant_override("separation", 10)
	main_vbox.add_child(button_container)

	var ok_button := Button.new()
	ok_button.text = "OK"
	ok_button.custom_minimum_size = Vector2(80, 30)
	ok_button.pressed.connect(_on_project_dialog_ok_pressed)
	button_container.add_child(ok_button)

	var cancel_button := Button.new()
	cancel_button.text = "Cancel"
	cancel_button.custom_minimum_size = Vector2(80, 30)
	cancel_button.pressed.connect(_on_project_dialog_cancel_pressed)
	button_container.add_child(cancel_button)

	projects_dialog.close_requested.connect(_on_project_dialog_cancel_pressed)


func _create_save_confirm_dialog() -> void:
	save_confirm_dialog = ConfirmationDialog.new()
	save_confirm_dialog.title = "Save Project"
	save_confirm_dialog.dialog_text = "Are you sure you want to save the current project?"
	save_confirm_dialog.ok_button_text = "Save"
	save_confirm_dialog.confirmed.connect(_on_save_confirmed)
	add_child(save_confirm_dialog)


func _on_project_button_pressed() -> void:
	_fetch_projects_from_dynamodb()


func _on_save_button_pressed() -> void:
	if current_project_name.is_empty():
		# No project selected, show warning
		var warning := AcceptDialog.new()
		warning.title = "No Project"
		warning.dialog_text = "Please select a project first."
		warning.confirmed.connect(warning.queue_free)
		warning.canceled.connect(warning.queue_free)
		add_child(warning)
		warning.popup_centered()
		return
	save_confirm_dialog.popup_centered()


func _on_save_confirmed() -> void:
	save_requested.emit()


func _fetch_projects_from_dynamodb() -> void:
	var endpoint := "http://zycroft.duckdns.org:8001"
	var table_name := "Projects"

	var headers := [
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.Scan",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	]
	var body := JSON.stringify({"TableName": table_name})

	print("Fetching projects from DynamoDB...")
	var error = http_request.request(endpoint, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		print("Failed to send request: ", error)


func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json and json.has("Items"):
			projects_list.clear()
			for item in json["Items"]:
				var project := {}
				for key in item.keys():
					var value = item[key]
					if value.has("S"):
						project[key] = value["S"]
					elif value.has("N"):
						project[key] = int(value["N"])
				projects_list.append(project)
			print("Projects loaded: ", projects_list.size())
			_show_projects_dialog()
	else:
		var error_body = body.get_string_from_utf8()
		print("Failed to fetch projects: ", response_code, " - ", error_body)


func _show_projects_dialog() -> void:
	project_item_list.clear()
	selected_project_index = -1

	for project in projects_list:
		var project_name = project.get("Name", "Unnamed Project")
		project_item_list.add_item(project_name)

	projects_dialog.popup_centered()


func _on_project_item_selected(index: int) -> void:
	selected_project_index = index


func _on_project_item_activated(index: int) -> void:
	selected_project_index = index
	_on_project_dialog_ok_pressed()


func _on_project_dialog_ok_pressed() -> void:
	if selected_project_index >= 0 and selected_project_index < projects_list.size():
		var selected_project = projects_list[selected_project_index]
		current_project_name = selected_project.get("Name", "Unknown")
		print("Selected project: ", current_project_name)
		title_label.text = "Project: " + current_project_name
		project_selected.emit(selected_project)
		# Auto-load after selecting project
		load_requested.emit()
	projects_dialog.hide()


func _on_project_dialog_cancel_pressed() -> void:
	projects_dialog.hide()


func set_project_name(project_name: String) -> void:
	current_project_name = project_name
	if minimized:
		title_label.text = "Proj: " + project_name
	else:
		title_label.text = "Project: " + project_name
