# Scene hierarchy panel - displays tree view of nodes, handles project selection/creation,
# provides context menus, and contains Game Design dialog for AI-assisted design.
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
	"Scene": ["Scene"],
	"2D": ["Node2D", "Sprite2D", "AnimatedSprite2D", "CanvasLayer"],
	"Control": ["Control", "VBoxContainer", "HBoxContainer", "GridContainer",
				"FlowContainer", "MarginContainer", "PanelContainer",
				"CenterContainer", "AspectRatioContainer", "HSplitContainer",
				"VSplitContainer", "TabContainer"],
	"UI": ["Button", "Label", "LineEdit", "TextEdit", "CheckBox", "CheckButton",
		   "OptionButton", "SpinBox", "HSlider", "VSlider", "ProgressBar",
		   "ColorRect", "TextureRect", "ColorPickerButton", "RichTextLabel"],
	"Animation": ["AnimationPlayer"],
	"Audio": ["AudioStreamPlayer"]
}

const NODE_COLORS := {
	# Project
	"Project": Color(1.0, 0.8, 0.2),
	# Scene
	"Scene": Color(0.9, 0.7, 0.2),
	# 2D Nodes
	"Node2D": Color(0.4, 0.7, 0.4),
	"Sprite2D": Color(0.5, 0.8, 0.5),
	"AnimatedSprite2D": Color(0.4, 0.9, 0.6),
	"CanvasLayer": Color(0.7, 0.5, 0.9),
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
	"AnimationPlayer": Color(0.9, 0.6, 0.3),
	# Audio
	"AudioStreamPlayer": Color(0.3, 0.7, 0.9)
}

const NODE_ICONS := {
	"Project": "PRJ",
	"Scene": "SCN",
	"Node2D": "2D",
	"Sprite2D": "SPR",
	"AnimatedSprite2D": "ANI",
	"CanvasLayer": "CVL",
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
	"AnimationPlayer": "ANM",
	"AudioStreamPlayer": "SFX"
}

@onready var title_bar: Panel = $TitleBar
@onready var title_label: Label = $TitleBar/HBox/Label
@onready var minimize_button: Button = $TitleBar/HBox/MinimizeButton
@onready var button_row: HBoxContainer = $ButtonRow
@onready var project_button: Button = $ButtonRow/ProjectButton
@onready var save_button: Button = $ButtonRow/SaveButton
@onready var new_button: Button = $ButtonRow/NewButton
@onready var tree: Tree = $Content/Tree
@onready var add_node_popup: PopupMenu

var context_menu: PopupMenu
var add_child_popup: PopupMenu
var context_node_id: int = -1

# Title bar context menu
var title_bar_context_menu: PopupMenu
var game_design_dialog: Window
var game_design_concept_edit: TextEdit
var game_design_service_dropdown: OptionButton
var game_design_model_dropdown: OptionButton
var game_design_status_label: Label
var game_design_usage_label: Label
var game_design_response_edit: TextEdit
var game_design_generate_btn: Button
var game_design_prompt_id: String = ""
var game_design_status_timer: Timer
var game_design_dynamodb_request: HTTPRequest

# Project management
var http_request: HTTPRequest
var create_http_request: HTTPRequest
var projects_list: Array = []
var selected_project_index: int = -1
var current_project_name: String = ""
var projects_dialog: Window
var project_item_list: ItemList
var save_confirm_dialog: ConfirmationDialog

# New project dialog
var new_project_dialog: Window
var new_project_name_edit: LineEdit
var new_project_path_edit: LineEdit
var new_project_path_label: Label
var file_dialog: FileDialog


func _ready() -> void:
	title_bar.gui_input.connect(_on_title_bar_gui_input)
	gui_input.connect(_on_panel_clicked)
	minimize_button.pressed.connect(_toggle_minimize)

	# Connect buttons
	project_button.pressed.connect(_on_project_button_pressed)
	save_button.pressed.connect(_on_save_button_pressed)
	new_button.pressed.connect(_on_new_button_pressed)

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

	# Create HTTPRequest for creating new projects
	create_http_request = HTTPRequest.new()
	add_child(create_http_request)
	create_http_request.request_completed.connect(_on_create_project_completed)

	# Create project selection dialog
	_create_projects_dialog()

	# Create save confirmation dialog
	_create_save_confirm_dialog()

	# Create new project dialog
	_create_new_project_dialog()

	# Create title bar context menu
	_create_title_bar_context_menu()

	# Create game design dialog
	_create_game_design_dialog()

	# Create HTTPRequest for Ollama API calls
	claude_http_request = HTTPRequest.new()
	claude_http_request.timeout = 600  # 10 minute timeout for slow models
	add_child(claude_http_request)
	claude_http_request.request_completed.connect(_on_claude_request_completed)

	# Create HTTPRequest for AI Prompts DynamoDB operations
	ai_dynamodb_http_request = HTTPRequest.new()
	ai_dynamodb_http_request.timeout = 30
	add_child(ai_dynamodb_http_request)
	ai_dynamodb_http_request.request_completed.connect(_on_ai_dynamodb_request_completed)

	_load_config()

	# Automatically fetch projects and show selection dialog on startup
	call_deferred("_fetch_projects_from_dynamodb")


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


func _create_context_menu() -> void:
	context_menu = PopupMenu.new()
	context_menu.add_item("AI Prompts...", 5)
	context_menu.add_separator()
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
		5:  # AI Prompts
			_show_ai_prompts_dialog()


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
				var node_type = item.get_meta("node_type", "")
				if node_type == "Project":
					# Show Game Design menu for root [PRJ] node
					title_bar_context_menu.position = Vector2i(get_global_mouse_position())
					title_bar_context_menu.popup()
				else:
					# Show regular context menu for other nodes
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

	# Default to first project if available
	if project_item_list.item_count > 0:
		project_item_list.select(0)
		selected_project_index = 0

	projects_dialog.popup_centered()


func _on_project_item_selected(index: int) -> void:
	selected_project_index = index


func _on_project_item_activated(index: int) -> void:
	selected_project_index = index
	_on_project_dialog_ok_pressed()


func _on_project_dialog_ok_pressed() -> void:
	if selected_project_index >= 0 and selected_project_index < projects_list.size():
		var selected_project = projects_list[selected_project_index]
		current_project_id = selected_project.get("ID", -1)
		current_project_name = selected_project.get("Name", "Unknown")
		print("Selected project: ", current_project_name, " (ID: ", current_project_id, ")")
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


# ============================================
# New Project Dialog Functions
# ============================================

func _create_new_project_dialog() -> void:
	new_project_dialog = Window.new()
	new_project_dialog.title = "New Project"
	new_project_dialog.size = Vector2i(450, 200)
	new_project_dialog.transient = true
	new_project_dialog.exclusive = true
	new_project_dialog.visible = false
	add_child(new_project_dialog)

	var main_vbox := VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 12)
	main_vbox.offset_left = 15
	main_vbox.offset_top = 15
	main_vbox.offset_right = -15
	main_vbox.offset_bottom = -15
	new_project_dialog.add_child(main_vbox)

	# Project name row
	var name_hbox := HBoxContainer.new()
	name_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(name_hbox)

	var name_label := Label.new()
	name_label.text = "Project Name:"
	name_label.custom_minimum_size.x = 100
	name_hbox.add_child(name_label)

	new_project_name_edit = LineEdit.new()
	new_project_name_edit.placeholder_text = "My Game"
	new_project_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_hbox.add_child(new_project_name_edit)

	# Godot path row
	var path_hbox := HBoxContainer.new()
	path_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(path_hbox)

	var path_label := Label.new()
	path_label.text = "Godot Project:"
	path_label.custom_minimum_size.x = 100
	path_hbox.add_child(path_label)

	new_project_path_edit = LineEdit.new()
	new_project_path_edit.placeholder_text = "/path/to/godot/project"
	new_project_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_project_path_edit.editable = false
	path_hbox.add_child(new_project_path_edit)

	var browse_button := Button.new()
	browse_button.text = "Browse..."
	browse_button.custom_minimum_size.x = 80
	browse_button.pressed.connect(_on_browse_button_pressed)
	path_hbox.add_child(browse_button)

	# Info label
	var info_label := Label.new()
	info_label.text = "Select a Godot project folder (contains project.godot)"
	info_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	info_label.add_theme_font_size_override("font_size", 12)
	main_vbox.add_child(info_label)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(spacer)

	# Button row
	var button_container := HBoxContainer.new()
	button_container.alignment = BoxContainer.ALIGNMENT_END
	button_container.add_theme_constant_override("separation", 10)
	main_vbox.add_child(button_container)

	var create_button := Button.new()
	create_button.text = "Create"
	create_button.custom_minimum_size = Vector2(80, 30)
	create_button.pressed.connect(_on_new_project_create_pressed)
	button_container.add_child(create_button)

	var cancel_button := Button.new()
	cancel_button.text = "Cancel"
	cancel_button.custom_minimum_size = Vector2(80, 30)
	cancel_button.pressed.connect(_on_new_project_cancel_pressed)
	button_container.add_child(cancel_button)

	new_project_dialog.close_requested.connect(_on_new_project_cancel_pressed)

	# Create file dialog for directory selection
	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.title = "Select Godot Project Directory"
	file_dialog.size = Vector2i(700, 500)
	file_dialog.dir_selected.connect(_on_directory_selected)
	add_child(file_dialog)


func _create_title_bar_context_menu() -> void:
	title_bar_context_menu = PopupMenu.new()
	title_bar_context_menu.add_item("Game Design...", 0)
	title_bar_context_menu.add_separator()
	title_bar_context_menu.add_item("Push Design", 1)
	title_bar_context_menu.id_pressed.connect(_on_title_bar_menu_action)
	add_child(title_bar_context_menu)


func _create_game_design_dialog() -> void:
	game_design_dialog = Window.new()
	game_design_dialog.title = "Game Design"
	game_design_dialog.size = Vector2i(800, 600)
	game_design_dialog.transient = true
	game_design_dialog.exclusive = true
	game_design_dialog.visible = false
	add_child(game_design_dialog)

	var main_vbox := VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 10)
	main_vbox.offset_left = 20
	main_vbox.offset_top = 20
	main_vbox.offset_right = -20
	main_vbox.offset_bottom = -20
	game_design_dialog.add_child(main_vbox)

	# Game Concept section
	var concept_label := Label.new()
	concept_label.text = "Game Concept:"
	concept_label.add_theme_font_size_override("font_size", 16)
	main_vbox.add_child(concept_label)

	game_design_concept_edit = TextEdit.new()
	game_design_concept_edit.placeholder_text = "Describe your game in 2-3 sentences. What makes it unique?"
	game_design_concept_edit.custom_minimum_size.y = 80
	game_design_concept_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	main_vbox.add_child(game_design_concept_edit)

	# Generate button row
	var generate_hbox := HBoxContainer.new()
	generate_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(generate_hbox)

	game_design_generate_btn = Button.new()
	game_design_generate_btn.text = "Generate Design"
	game_design_generate_btn.custom_minimum_size = Vector2(140, 35)
	game_design_generate_btn.pressed.connect(_on_game_design_generate_pressed)
	generate_hbox.add_child(game_design_generate_btn)

	# Service and Model selection
	var service_label := Label.new()
	service_label.text = "Service:"
	generate_hbox.add_child(service_label)

	game_design_service_dropdown = OptionButton.new()
	if ai_services.is_empty():
		game_design_service_dropdown.add_item("Zycroft")
		game_design_service_dropdown.add_item("OpenAI")
		game_design_service_dropdown.add_item("Claude")
	else:
		for service_name in ai_services.keys():
			game_design_service_dropdown.add_item(service_name)
	game_design_service_dropdown.custom_minimum_size.x = 120
	game_design_service_dropdown.item_selected.connect(_on_game_design_service_changed)
	generate_hbox.add_child(game_design_service_dropdown)

	var model_label := Label.new()
	model_label.text = "Model:"
	generate_hbox.add_child(model_label)

	game_design_model_dropdown = OptionButton.new()
	game_design_model_dropdown.custom_minimum_size.x = 200
	generate_hbox.add_child(game_design_model_dropdown)

	# Initialize models for first service
	_update_game_design_models(0)

	# Status and Usage row
	var status_hbox := HBoxContainer.new()
	status_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(status_hbox)

	var status_title := Label.new()
	status_title.text = "Status:"
	status_hbox.add_child(status_title)

	game_design_status_label = Label.new()
	game_design_status_label.text = "Ready"
	game_design_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	status_hbox.add_child(game_design_status_label)

	# Spacer to push usage label to right
	var usage_spacer := Control.new()
	usage_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_hbox.add_child(usage_spacer)

	game_design_usage_label = Label.new()
	game_design_usage_label.text = ""
	game_design_usage_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
	status_hbox.add_child(game_design_usage_label)

	# AI Response section
	var response_label := Label.new()
	response_label.text = "AI Response:"
	response_label.add_theme_font_size_override("font_size", 16)
	main_vbox.add_child(response_label)

	game_design_response_edit = TextEdit.new()
	game_design_response_edit.placeholder_text = "AI generated game design will appear here..."
	game_design_response_edit.custom_minimum_size.y = 200
	game_design_response_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	game_design_response_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	main_vbox.add_child(game_design_response_edit)

	# Button row
	var button_container := HBoxContainer.new()
	button_container.alignment = BoxContainer.ALIGNMENT_END
	button_container.add_theme_constant_override("separation", 10)
	main_vbox.add_child(button_container)

	var design_save_button := Button.new()
	design_save_button.text = "Save"
	design_save_button.custom_minimum_size = Vector2(100, 35)
	design_save_button.pressed.connect(_on_game_design_save_pressed)
	button_container.add_child(design_save_button)

	var design_close_button := Button.new()
	design_close_button.text = "Close"
	design_close_button.custom_minimum_size = Vector2(100, 35)
	design_close_button.pressed.connect(_on_game_design_close)
	button_container.add_child(design_close_button)

	game_design_dialog.close_requested.connect(_on_game_design_close)

	# Create HTTPRequest for Game Design DynamoDB calls
	game_design_dynamodb_request = HTTPRequest.new()
	game_design_dynamodb_request.timeout = 30
	add_child(game_design_dynamodb_request)
	game_design_dynamodb_request.request_completed.connect(_on_game_design_dynamodb_completed)

	# Create status refresh timer
	game_design_status_timer = Timer.new()
	game_design_status_timer.wait_time = 2.0
	game_design_status_timer.one_shot = false
	game_design_status_timer.timeout.connect(_on_game_design_status_timeout)
	add_child(game_design_status_timer)


func _on_title_bar_menu_action(id: int) -> void:
	match id:
		0:  # Game Design
			_load_game_design_from_dynamodb()
			game_design_dialog.popup_centered()
		1:  # Push Design
			_request_project_sync()


func _request_project_sync() -> void:
	if current_project_id < 0:
		print("PUSH_DESIGN: No project selected")
		return
	print("PUSH_DESIGN_REQUEST: project_id=%d" % current_project_id)
	print("Run '/push-design' in Claude Code to push this design to Godot")


func _on_game_design_close() -> void:
	game_design_dialog.hide()


func _load_game_design_from_dynamodb() -> void:
	if dynamodb_endpoint.is_empty():
		return

	if current_project_id < 0:
		return

	var project_object_id = str(current_project_id) + "_0"

	# Query for game design prompts (promptID starts with "gd_")
	var request_body = JSON.stringify({
		"TableName": ai_prompts_table,
		"KeyConditionExpression": "projectObjectID = :poid AND begins_with(promptID, :prefix)",
		"ExpressionAttributeValues": {
			":poid": {"S": project_object_id},
			":prefix": {"S": "gd_"}
		}
	})

	var headers = PackedStringArray([
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.Query",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	])

	# Create a one-time HTTPRequest for loading
	var load_request = HTTPRequest.new()
	add_child(load_request)
	load_request.request_completed.connect(
		func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
			_handle_game_design_load_response(result, response_code, body)
			load_request.queue_free()
	)
	load_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)


func _handle_game_design_load_response(result: int, response_code: int, body: PackedByteArray) -> void:
	var response_text = body.get_string_from_utf8()
	print("Game design load response: ", response_code, " result: ", result)

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		print("Failed to load game design: ", response_text.left(500))
		return

	var json = JSON.parse_string(response_text)

	if not json or not json.has("Items") or json["Items"].size() == 0:
		# No saved game design, reset fields
		game_design_prompt_id = ""
		game_design_concept_edit.text = ""
		game_design_response_edit.text = ""
		game_design_status_label.text = "Ready"
		game_design_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		return

	# Find the most recent game design (highest createdAt)
	var items = json["Items"]
	var latest_item = items[0]
	var latest_time = float(latest_item.get("createdAt", {}).get("N", "0"))

	for item in items:
		var item_time = float(item.get("createdAt", {}).get("N", "0"))
		if item_time > latest_time:
			latest_time = item_time
			latest_item = item

	# Populate fields with the loaded data
	game_design_prompt_id = latest_item.get("promptID", {}).get("S", "")
	game_design_concept_edit.text = latest_item.get("content", {}).get("S", "")
	game_design_response_edit.text = latest_item.get("response", {}).get("S", "")

	# Set service dropdown
	var saved_service = latest_item.get("service", {}).get("S", "")
	if not saved_service.is_empty():
		for i in range(game_design_service_dropdown.item_count):
			if game_design_service_dropdown.get_item_text(i) == saved_service:
				game_design_service_dropdown.selected = i
				_update_game_design_models(i)
				break

	# Set model dropdown
	var saved_model = latest_item.get("model", {}).get("S", "")
	if not saved_model.is_empty():
		for i in range(game_design_model_dropdown.item_count):
			if game_design_model_dropdown.get_item_text(i) == saved_model:
				game_design_model_dropdown.selected = i
				break

	# Update status
	var status = latest_item.get("status", {}).get("S", "idle")
	match status:
		"idle":
			game_design_status_label.text = "Saved"
			game_design_status_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
		"completed":
			game_design_status_label.text = "Completed"
			game_design_status_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
		_:
			game_design_status_label.text = "Ready"
			game_design_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))

	print("Loaded game design: ", game_design_prompt_id)


func _on_game_design_save_pressed() -> void:
	var concept = game_design_concept_edit.text.strip_edges()
	if concept.is_empty():
		game_design_response_edit.text = "Please enter a game concept to save."
		return

	if dynamodb_endpoint.is_empty():
		game_design_response_edit.text = "Error: DynamoDB endpoint not configured."
		return

	var selected_service = game_design_service_dropdown.get_item_text(game_design_service_dropdown.selected)
	var selected_model = game_design_model_dropdown.get_item_text(game_design_model_dropdown.selected)
	var response_text = game_design_response_edit.text.strip_edges()

	# Generate prompt ID if new
	if game_design_prompt_id.is_empty():
		game_design_prompt_id = "gd_" + str(Time.get_unix_time_from_system())

	var project_object_id = str(current_project_id) + "_0"
	var system_prompt = "You are a game design expert. Based on the game concept provided, create a comprehensive game design document that includes: 1) Game Overview, 2) Core Gameplay Mechanics, 3) Player Progression, 4) Art Style and Visual Direction, 5) Target Audience, 6) Key Features, and 7) Technical Considerations. Be specific and actionable."

	# Save to DynamoDB with status "idle" (saved but not generating)
	var request_body = JSON.stringify({
		"TableName": ai_prompts_table,
		"Item": {
			"projectObjectID": {"S": project_object_id},
			"promptID": {"S": game_design_prompt_id},
			"title": {"S": "Game Design"},
			"content": {"S": concept},
			"systemPrompt": {"S": system_prompt},
			"service": {"S": selected_service},
			"model": {"S": selected_model},
			"status": {"S": "idle"},
			"response": {"S": response_text},
			"createdAt": {"N": str(Time.get_unix_time_from_system())}
		}
	})

	var headers = PackedStringArray([
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.PutItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	])

	# Update status
	game_design_status_label.text = "Saving..."
	game_design_status_label.add_theme_color_override("font_color", Color(0.2, 0.6, 1.0))

	# Create a one-time HTTPRequest for saving
	var save_request = HTTPRequest.new()
	add_child(save_request)
	save_request.request_completed.connect(
		func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
			_handle_game_design_save_response(result, response_code, body)
			save_request.queue_free()
	)
	save_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)
	print("Saving game design: ", game_design_prompt_id)


func _handle_game_design_save_response(result: int, response_code: int, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		game_design_status_label.text = "Save Failed"
		game_design_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	if response_code == 200:
		game_design_status_label.text = "Saved"
		game_design_status_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
		print("Game design saved successfully")
	else:
		var response_text = body.get_string_from_utf8()
		game_design_status_label.text = "Save Failed"
		game_design_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		print("Failed to save game design: ", response_text.left(200))


func _update_game_design_models(service_index: int) -> void:
	game_design_model_dropdown.clear()

	if ai_services.is_empty():
		# Fallback defaults if no config
		var default_models = {
			0: ["llama3.2:3b", "qwen2.5:7b-instruct", "mistral:7b"],
			1: ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"],
			2: ["claude-sonnet-4-20250514", "claude-opus-4-20250514", "claude-3-5-haiku-20241022"]
		}
		if default_models.has(service_index):
			for model in default_models[service_index]:
				game_design_model_dropdown.add_item(model)
	else:
		var service_name = game_design_service_dropdown.get_item_text(service_index)
		if ai_services.has(service_name):
			for model in ai_services[service_name]:
				game_design_model_dropdown.add_item(model)


func _on_game_design_service_changed(index: int) -> void:
	_update_game_design_models(index)
	# Update usage display for new service
	var selected_service = game_design_service_dropdown.get_item_text(index)
	_update_game_design_usage(selected_service)


func _update_game_design_usage(_service: String) -> void:
	# For now, just show ready status - can add usage tracking later
	game_design_usage_label.text = ""


func _on_game_design_generate_pressed() -> void:
	var concept = game_design_concept_edit.text.strip_edges()
	if concept.is_empty():
		game_design_response_edit.text = "Please enter a game concept first."
		return

	if dynamodb_endpoint.is_empty():
		game_design_response_edit.text = "Error: DynamoDB endpoint not configured."
		return

	var selected_service = game_design_service_dropdown.get_item_text(game_design_service_dropdown.selected)
	var selected_model = game_design_model_dropdown.get_item_text(game_design_model_dropdown.selected)

	# Build the prompt for game design generation
	var system_prompt = "You are a game design expert. Based on the game concept provided, create a comprehensive game design document that includes: 1) Game Overview, 2) Core Gameplay Mechanics, 3) Player Progression, 4) Art Style and Visual Direction, 5) Target Audience, 6) Key Features, and 7) Technical Considerations. Be specific and actionable."

	# Generate or reuse prompt ID
	if game_design_prompt_id.is_empty():
		game_design_prompt_id = "gd_" + str(Time.get_unix_time_from_system())

	# Use project ID 0 and object ID 0 for game design documents
	var project_object_id = str(current_project_id) + "_0"

	# Save/update the prompt in DynamoDB with status "generate"
	var request_body = JSON.stringify({
		"TableName": ai_prompts_table,
		"Item": {
			"projectObjectID": {"S": project_object_id},
			"promptID": {"S": game_design_prompt_id},
			"title": {"S": "Game Design"},
			"content": {"S": concept},
			"systemPrompt": {"S": system_prompt},
			"service": {"S": selected_service},
			"model": {"S": selected_model},
			"status": {"S": "generate"},
			"response": {"S": ""},
			"createdAt": {"N": str(Time.get_unix_time_from_system())}
		}
	})

	var headers = PackedStringArray([
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.PutItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	])

	# Update status
	game_design_status_label.text = "Queued..."
	game_design_status_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	game_design_generate_btn.disabled = true
	game_design_response_edit.text = "Generating game design..."

	game_design_dynamodb_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)
	print("Submitting game design prompt: ", game_design_prompt_id)


func _on_game_design_dynamodb_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		game_design_response_edit.text = "Error: Failed to connect to DynamoDB"
		_reset_game_design_status()
		return

	var response_text = body.get_string_from_utf8()

	if response_code == 200:
		# Successfully saved - start polling for status
		print("Game design prompt saved, starting status refresh")
		_start_game_design_status_refresh()
	else:
		game_design_response_edit.text = "Error saving to DynamoDB: " + response_text.left(200)
		_reset_game_design_status()


func _reset_game_design_status() -> void:
	game_design_status_label.text = "Ready"
	game_design_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	game_design_generate_btn.disabled = false


func _start_game_design_status_refresh() -> void:
	if game_design_status_timer and not game_design_status_timer.is_stopped():
		return
	if game_design_status_timer:
		game_design_status_timer.start()
		print("Started game design status refresh timer")


func _stop_game_design_status_refresh() -> void:
	if game_design_status_timer and not game_design_status_timer.is_stopped():
		game_design_status_timer.stop()
		print("Stopped game design status refresh timer")


func _on_game_design_status_timeout() -> void:
	if game_design_prompt_id.is_empty():
		_stop_game_design_status_refresh()
		return
	_fetch_game_design_status()


func _fetch_game_design_status() -> void:
	if dynamodb_endpoint.is_empty():
		return

	var project_object_id = str(current_project_id) + "_0"

	var request_body = JSON.stringify({
		"TableName": ai_prompts_table,
		"Key": {
			"projectObjectID": {"S": project_object_id},
			"promptID": {"S": game_design_prompt_id}
		}
	})

	var headers = PackedStringArray([
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.GetItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	])

	# Create a one-time HTTPRequest for status check
	var status_request = HTTPRequest.new()
	add_child(status_request)
	status_request.request_completed.connect(
		func(req_result: int, req_response_code: int, _req_headers: PackedStringArray, req_body: PackedByteArray):
			_handle_game_design_status_response(req_result, req_response_code, req_body)
			status_request.queue_free()
	)
	status_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)


func _handle_game_design_status_response(result: int, response_code: int, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return

	var response_text = body.get_string_from_utf8()
	var json = JSON.parse_string(response_text)

	if not json or not json.has("Item"):
		return

	var item = json["Item"]
	var status = item.get("status", {}).get("S", "")
	var response = item.get("response", {}).get("S", "")

	# Update status display
	match status:
		"generate":
			game_design_status_label.text = "Queued..."
			game_design_status_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		"processing":
			game_design_status_label.text = "Processing..."
			game_design_status_label.add_theme_color_override("font_color", Color(0.2, 0.6, 1.0))
		"completed":
			game_design_status_label.text = "Completed"
			game_design_status_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
			game_design_generate_btn.disabled = false
			_stop_game_design_status_refresh()
			if not response.is_empty():
				game_design_response_edit.text = response
		"error":
			game_design_status_label.text = "Error"
			game_design_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			game_design_generate_btn.disabled = false
			_stop_game_design_status_refresh()
			if not response.is_empty():
				game_design_response_edit.text = "Error: " + response


func _on_new_button_pressed() -> void:
	# Clear previous values
	new_project_name_edit.text = ""
	new_project_path_edit.text = ""
	new_project_dialog.popup_centered()


func _on_browse_button_pressed() -> void:
	file_dialog.popup_centered()


func _on_directory_selected(dir: String) -> void:
	new_project_path_edit.text = dir
	# Try to auto-fill project name if empty
	if new_project_name_edit.text.is_empty():
		var dir_name = dir.get_file()
		if dir_name.is_empty():
			dir_name = dir.get_base_dir().get_file()
		new_project_name_edit.text = dir_name


func _on_new_project_create_pressed() -> void:
	var project_name = new_project_name_edit.text.strip_edges()
	var project_path = new_project_path_edit.text.strip_edges()

	if project_name.is_empty():
		_show_error("Please enter a project name.")
		return

	# Create project in DynamoDB
	_create_project_in_dynamodb(project_name, project_path)


func _on_new_project_cancel_pressed() -> void:
	new_project_dialog.hide()


func _show_error(message: String) -> void:
	var error_dialog := AcceptDialog.new()
	error_dialog.title = "Error"
	error_dialog.dialog_text = message
	error_dialog.confirmed.connect(error_dialog.queue_free)
	error_dialog.canceled.connect(error_dialog.queue_free)
	add_child(error_dialog)
	error_dialog.popup_centered()


func _create_project_in_dynamodb(project_name: String, project_path: String) -> void:
	# First, scan to get the highest ID
	var endpoint := "http://zycroft.duckdns.org:8001"

	var headers := [
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.Scan",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	]
	var body := JSON.stringify({
		"TableName": "Projects",
		"ProjectionExpression": "ID"
	})

	# Store the pending project data
	set_meta("pending_project_name", project_name)
	set_meta("pending_project_path", project_path)

	print("Fetching project IDs to determine next ID...")
	var error = create_http_request.request(endpoint, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		print("Failed to send scan request: ", error)


func _on_create_project_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var json = JSON.parse_string(body.get_string_from_utf8())

	# Check if this is a scan response (getting IDs) or a put response (creating project)
	if json and json.has("Items"):
		# This is the scan response - find max ID
		var max_id := 0
		for item in json["Items"]:
			if item.has("ID") and item["ID"].has("N"):
				var id = int(item["ID"]["N"])
				if id > max_id:
					max_id = id

		var new_id = max_id + 1
		var project_name = get_meta("pending_project_name", "")
		var project_path = get_meta("pending_project_path", "")

		# Now create the project with PutItem
		_put_project_item(new_id, project_name, project_path)

	elif response_code == 200:
		# This is the PutItem response - project created successfully
		print("Project created successfully!")
		new_project_dialog.hide()

		# Update local state and UI
		var new_project = {
			"ID": get_meta("new_project_id", 0),
			"Name": get_meta("pending_project_name", ""),
			"GodotProjectPath": get_meta("pending_project_path", "")
		}

		current_project_id = new_project["ID"]
		current_project_name = new_project["Name"]
		title_label.text = "Project: " + current_project_name
		project_selected.emit(new_project)

		# Clean up metadata
		remove_meta("pending_project_name")
		remove_meta("pending_project_path")
		remove_meta("new_project_id")
	else:
		var error_body = body.get_string_from_utf8()
		print("Failed to create project: ", response_code, " - ", error_body)
		_show_error("Failed to create project: " + error_body)


func _put_project_item(project_id: int, project_name: String, project_path: String) -> void:
	var endpoint := "http://zycroft.duckdns.org:8001"

	var headers := [
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.PutItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	]

	var item := {
		"ID": {"N": str(project_id)},
		"Name": {"S": project_name},
		"ShortDescription": {"S": ""},
		"Overview": {"S": ""},
		"GodotProjectPath": {"S": project_path}
	}

	var body := JSON.stringify({
		"TableName": "Projects",
		"Item": item
	})

	# Store the new ID for use after successful creation
	set_meta("new_project_id", project_id)

	print("Creating project with ID: ", project_id)
	var error = create_http_request.request(endpoint, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		print("Failed to send PutItem request: ", error)


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
var ai_prompt_images: Array = []  # Array of {texture, claude_approved, user_approved}
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

# DynamoDB for AI Prompts
var ai_dynamodb_http_request: HTTPRequest
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

	# Get object ID from context node
	current_object_id = context_node_id

	# Reset for new prompt
	current_prompt_id = ""
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

	ai_dynamodb_http_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)


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

	# Prompt title (smaller text box)
	var prompt_title_label := Label.new()
	prompt_title_label.text = "Prompt Title:"
	main_vbox.add_child(prompt_title_label)

	ai_prompt_title_edit = LineEdit.new()
	ai_prompt_title_edit.placeholder_text = "Enter a title for this prompt..."
	ai_prompt_title_edit.custom_minimum_size.y = 30
	main_vbox.add_child(ai_prompt_title_edit)

	# Prompt content (larger text box)
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

	# Image grid section
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

	# Add placeholder images for demo
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

	# Button row
	var dialog_button_row := HBoxContainer.new()
	dialog_button_row.alignment = BoxContainer.ALIGNMENT_END
	dialog_button_row.add_theme_constant_override("separation", 10)
	main_vbox.add_child(dialog_button_row)

	ai_generate_btn = Button.new()
	ai_generate_btn.text = "Regenerate Images"
	ai_generate_btn.custom_minimum_size = Vector2(140, 35)
	ai_generate_btn.pressed.connect(_on_ai_generate_pressed)
	dialog_button_row.add_child(ai_generate_btn)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(80, 35)
	save_btn.pressed.connect(_on_ai_save_pressed)
	dialog_button_row.add_child(save_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(80, 35)
	close_btn.pressed.connect(func():
		ai_prompts_dialog.hide()
		_stop_status_refresh()
	)
	dialog_button_row.add_child(close_btn)

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

	# Image display
	var image_rect := TextureRect.new()
	image_rect.custom_minimum_size = Vector2(100, 100)
	image_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image_rect.texture = texture

	# Placeholder background if no texture
	if not texture:
		var placeholder := ColorRect.new()
		placeholder.color = Color(0.3, 0.3, 0.3, 1)
		placeholder.custom_minimum_size = Vector2(100, 100)
		slot_vbox.add_child(placeholder)
	else:
		slot_vbox.add_child(image_rect)

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

	# Track the image data
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

	ai_dynamodb_http_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)
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

	ai_dynamodb_http_request.request(dynamodb_endpoint, headers, HTTPClient.METHOD_POST, request_body)
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

	# Get node name from tree if available
	var node_name = "Unknown"
	if tree_items.has(current_object_id):
		var tree_item = tree_items[current_object_id]
		var node_data = tree_item.get_meta("node_data", {})
		node_name = node_data.get("name", node_data.get("type", "Unknown"))

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
		"projectName": {"S": current_project_name if not current_project_name.is_empty() else "Unknown"},
		"nodeName": {"S": node_name},
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

	ai_dynamodb_http_request.request(url, headers, HTTPClient.METHOD_POST, request_body)


func _on_ai_dynamodb_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
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
