extends Node2D

const DraggableContainerScene = preload("res://draggable_container.tscn")
const SceneHierarchyScene = preload("res://scene_hierarchy.tscn")
const SceneHierarchyScript = preload("res://scene_hierarchy.gd")

@onready var controls_panel: Panel = $GameToolBar  # ControlsPanel type
@onready var scene_hierarchy: Panel  # SceneHierarchy type

var spawn_offset := 0
var all_containers: Array[DraggableContainer] = []
var current_project_id: int = -1
var current_project_name: String = ""
var save_http_request: HTTPRequest
var load_http_request: HTTPRequest
var node_id_counter := 0

# Scene data structure
var scene_root: Dictionary = {}
var all_nodes: Dictionary = {}  # node_id -> node instance or data
var selected_node_id: int = -1

# Viewport frame settings
var project_viewport_size := Vector2(1920, 1080)  # Default project viewport
var viewport_margin_percent := 0.10  # 10% margin
var viewport_frame: Line2D
var viewport_label: Label
var viewport_offset: Vector2  # Offset to center content with margin


func _ready() -> void:
	# Connect Controls panel signal (node spawning)
	controls_panel.node_spawn_requested.connect(_on_node_spawn_requested)

	# Create HTTPRequest for saving
	save_http_request = HTTPRequest.new()
	add_child(save_http_request)
	save_http_request.request_completed.connect(_on_save_completed)

	# Create HTTPRequest for loading
	load_http_request = HTTPRequest.new()
	add_child(load_http_request)
	load_http_request.request_completed.connect(_on_load_completed)

	# Create viewport frame
	_create_viewport_frame()

	# Connect to window resize signal
	get_tree().root.size_changed.connect(_on_window_resized)

	# Create scene hierarchy panel
	_create_scene_hierarchy()


func _create_viewport_frame() -> void:
	"""Create a visible frame showing the project viewport boundaries"""
	# Create the frame using Line2D
	viewport_frame = Line2D.new()
	viewport_frame.width = 3.0
	viewport_frame.default_color = Color(0.3, 0.6, 0.9, 0.8)  # Light blue
	viewport_frame.closed = true
	add_child(viewport_frame)

	# Add a label showing viewport size
	viewport_label = Label.new()
	viewport_label.text = "Project Viewport: %dx%d" % [int(project_viewport_size.x), int(project_viewport_size.y)]
	viewport_label.add_theme_color_override("font_color", Color(0.3, 0.6, 0.9, 0.8))
	viewport_label.add_theme_font_size_override("font_size", 14)
	add_child(viewport_label)

	# Set initial positions based on window size
	_on_window_resized()


func _on_window_resized() -> void:
	"""Recenter the viewport frame and objects when window size changes"""
	var window_size = get_viewport().get_visible_rect().size

	# Store old offset to calculate delta
	var old_offset = viewport_offset

	# Calculate new offset to center the project viewport in the window
	viewport_offset = (window_size - project_viewport_size) / 2
	viewport_offset = viewport_offset.max(Vector2(50, 50))  # Minimum margin

	# Calculate how much to move objects
	var offset_delta = viewport_offset - old_offset

	# Update frame points
	if viewport_frame:
		viewport_frame.clear_points()
		var frame_pos = viewport_offset
		var frame_size = project_viewport_size
		viewport_frame.add_point(frame_pos)
		viewport_frame.add_point(Vector2(frame_pos.x + frame_size.x, frame_pos.y))
		viewport_frame.add_point(Vector2(frame_pos.x + frame_size.x, frame_pos.y + frame_size.y))
		viewport_frame.add_point(Vector2(frame_pos.x, frame_pos.y + frame_size.y))
		viewport_frame.add_point(frame_pos)

	# Update label position
	if viewport_label:
		viewport_label.position = viewport_offset + Vector2(5, -25)

	# Move all containers by the offset delta
	if offset_delta != Vector2.ZERO:
		for container in all_containers:
			if is_instance_valid(container):
				container.global_position += offset_delta


func _create_scene_hierarchy() -> void:
	scene_hierarchy = SceneHierarchyScene.instantiate()
	add_child(scene_hierarchy)

	# Position to the right of the controls panel
	scene_hierarchy.global_position = Vector2(340, 100)

	# Connect hierarchy signals
	scene_hierarchy.node_selected.connect(_on_hierarchy_node_selected)
	scene_hierarchy.node_deleted.connect(_on_hierarchy_node_deleted)
	scene_hierarchy.add_node_requested.connect(_on_hierarchy_add_node_requested)
	scene_hierarchy.properties_requested.connect(_on_hierarchy_properties_requested)

	# Connect project management signals (moved from toolbar)
	scene_hierarchy.project_selected.connect(_on_project_selected)
	scene_hierarchy.save_requested.connect(_on_save_requested)
	scene_hierarchy.load_requested.connect(_on_load_requested)

	# Initialize with empty root
	_initialize_scene_root()


func _initialize_scene_root() -> void:
	node_id_counter = 0
	scene_root = {
		"id": _get_next_node_id(),
		"type": "Node2D",
		"name": "Root",
		"children": [],
		"properties": {}
	}
	all_nodes[scene_root["id"]] = scene_root
	_refresh_hierarchy()


func _get_next_node_id() -> int:
	node_id_counter += 1
	return node_id_counter


func _refresh_hierarchy() -> void:
	if scene_hierarchy:
		scene_hierarchy.build_tree(scene_root)


func _on_hierarchy_node_selected(node_data: Dictionary) -> void:
	selected_node_id = node_data.get("id", -1)
	var node_id = node_data.get("id", -1)

	# Find the selected node in scene data
	var selected_node_data = _find_node_data(node_id)
	if selected_node_data.is_empty():
		return

	# Clear all visual nodes
	_clear_all_visual_nodes()

	# Recreate only the selected node and its descendants
	_create_nodes_from_tree(selected_node_data, null)

	# Highlight the corresponding container/node in the viewport
	if all_nodes.has(node_id):
		var node = all_nodes[node_id]
		if node is DraggableContainer:
			_highlight_container(node)
		elif node is Node2D:
			_highlight_node2d(node)


func _clear_all_visual_nodes() -> void:
	"""Clear visual nodes without touching scene data"""
	for container in all_containers.duplicate():
		if is_instance_valid(container):
			container.queue_free()
	all_containers.clear()

	for node_id in all_nodes.keys():
		var node = all_nodes[node_id]
		if is_instance_valid(node) and node is Node:
			node.queue_free()
	all_nodes.clear()


func _remove_visual_node_recursive(node_data: Dictionary) -> void:
	"""Remove visual representation only, keep scene data intact"""
	var node_id = node_data.get("id", -1)

	# Remove children first
	for child in node_data.get("children", []):
		_remove_visual_node_recursive(child)

	# Remove widgets
	for widget in node_data.get("widgets", []):
		var widget_id = widget.get("id", -1)
		if all_nodes.has(widget_id):
			var widget_node = all_nodes[widget_id]
			if widget_node is Node:
				widget_node.queue_free()
			all_nodes.erase(widget_id)

	# Remove the node itself
	if all_nodes.has(node_id):
		var node = all_nodes[node_id]
		if node is Node:
			node.queue_free()
		all_nodes.erase(node_id)

	# Also remove from all_containers if it's a container
	for i in range(all_containers.size() - 1, -1, -1):
		if all_containers[i].get_meta("node_id", -1) == node_id:
			all_containers.remove_at(i)


func _highlight_container(container: DraggableContainer) -> void:
	# Deselect all containers first
	for c in all_containers:
		c.modulate = Color.WHITE

	# Highlight selected
	container.modulate = Color(1.2, 1.2, 1.0)


func _highlight_node2d(_node: Node2D) -> void:
	# TODO: Implement visual selection for 2D nodes
	pass


func _on_hierarchy_node_deleted(node_id: int) -> void:
	if node_id == scene_root.get("id", -1):
		print("Cannot delete root node")
		return

	# Find and remove from parent
	_remove_node_from_tree(node_id)
	_refresh_hierarchy()


func _remove_node_from_tree(node_id: int) -> void:
	# Find parent and remove child
	var parent_data = _find_parent_of_node(scene_root, node_id)
	if parent_data:
		var children = parent_data.get("children", [])
		for i in range(children.size()):
			if children[i].get("id") == node_id:
				# Also remove actual node if it exists
				if all_nodes.has(node_id):
					var node = all_nodes[node_id]
					if node is Node:
						node.queue_free()
					all_nodes.erase(node_id)
				children.remove_at(i)
				break


func _find_parent_of_node(current: Dictionary, target_id: int) -> Dictionary:
	var children = current.get("children", [])
	for child in children:
		if child.get("id") == target_id:
			return current
		var found = _find_parent_of_node(child, target_id)
		if not found.is_empty():
			return found
	return {}


func _find_node_data(node_id: int) -> Dictionary:
	return _find_node_in_tree(scene_root, node_id)


func _find_node_in_tree(current: Dictionary, target_id: int) -> Dictionary:
	if current.get("id") == target_id:
		return current
	# Search in children
	for child in current.get("children", []):
		var found = _find_node_in_tree(child, target_id)
		if not found.is_empty():
			return found
	# Search in widgets
	for widget in current.get("widgets", []):
		if widget.get("id") == target_id:
			return widget
	return {}


func _on_hierarchy_properties_requested(node_id: int, node_data: Dictionary) -> void:
	_show_properties_dialog(node_id, node_data)


var properties_dialog: Window
var properties_node_id: int = -1

func _show_properties_dialog(node_id: int, node_data: Dictionary) -> void:
	properties_node_id = node_id

	# Create dialog if it doesn't exist
	if not properties_dialog:
		properties_dialog = Window.new()
		properties_dialog.title = "Properties"
		properties_dialog.size = Vector2i(350, 400)
		properties_dialog.transient = true
		properties_dialog.close_requested.connect(_on_properties_dialog_closed)
		add_child(properties_dialog)

	# Clear existing content
	for child in properties_dialog.get_children():
		child.queue_free()

	# Build properties UI
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 10
	scroll.offset_top = 10
	scroll.offset_right = -10
	scroll.offset_bottom = -50
	properties_dialog.add_child(scroll)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# Node info header
	var header = Label.new()
	header.text = "%s (%s)" % [node_data.get("name", "Unknown"), node_data.get("type", "Unknown")]
	header.add_theme_font_size_override("font_size", 16)
	vbox.add_child(header)

	vbox.add_child(HSeparator.new())

	# Properties
	var props = node_data.get("properties", {})
	for key in props.keys():
		var hbox = HBoxContainer.new()

		var label = Label.new()
		label.text = key + ":"
		label.custom_minimum_size.x = 100
		hbox.add_child(label)

		var value = props[key]
		var edit = LineEdit.new()
		edit.text = str(value)
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.set_meta("prop_key", key)
		edit.text_submitted.connect(_on_property_changed.bind(key))
		hbox.add_child(edit)

		vbox.add_child(hbox)

	# Add property button
	var add_btn = Button.new()
	add_btn.text = "+ Add Property"
	add_btn.pressed.connect(_on_add_property_pressed)
	vbox.add_child(add_btn)

	# Close button
	var close_btn = Button.new()
	close_btn.text = "Close"
	close_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	close_btn.offset_left = -80
	close_btn.offset_top = -40
	close_btn.offset_right = -10
	close_btn.offset_bottom = -10
	close_btn.pressed.connect(_on_properties_dialog_closed)
	properties_dialog.add_child(close_btn)

	properties_dialog.popup_centered()


func _on_property_changed(new_value: String, key: String) -> void:
	if properties_node_id < 0:
		return

	var node_data = _find_node_data(properties_node_id)
	if node_data.is_empty():
		return

	var props = node_data.get("properties", {})

	# Try to parse as number
	if new_value.is_valid_float():
		props[key] = float(new_value)
	elif new_value.is_valid_int():
		props[key] = int(new_value)
	else:
		props[key] = new_value

	node_data["properties"] = props
	print("Property updated: %s = %s" % [key, new_value])


func _on_add_property_pressed() -> void:
	# Simple implementation - add a new property with default name
	if properties_node_id < 0:
		return

	var node_data = _find_node_data(properties_node_id)
	if node_data.is_empty():
		return

	var props = node_data.get("properties", {})
	var new_key = "newProperty"
	var counter = 1
	while props.has(new_key):
		new_key = "newProperty" + str(counter)
		counter += 1

	props[new_key] = ""
	node_data["properties"] = props

	# Refresh the dialog
	_show_properties_dialog(properties_node_id, node_data)


func _on_properties_dialog_closed() -> void:
	properties_dialog.hide()


func _on_hierarchy_add_node_requested(parent_id: int, node_type: String) -> void:
	# Determine if this is a container, widget, or 2D node
	if node_type in SceneHierarchyScript.NODE_CATEGORIES["Control"]:
		_add_container_node(parent_id, node_type)
	elif node_type in SceneHierarchyScript.NODE_CATEGORIES["UI"]:
		_add_widget_node(parent_id, node_type)
	elif node_type in SceneHierarchyScript.NODE_CATEGORIES["2D"]:
		_add_2d_node(parent_id, node_type)
	elif node_type in SceneHierarchyScript.NODE_CATEGORIES["Animation"]:
		_add_animation_node(parent_id, node_type)


func _add_container_node(parent_id: int, container_type: String) -> void:
	var node_id = _get_next_node_id()
	var node_data = {
		"id": node_id,
		"type": container_type,
		"name": container_type,
		"children": [],
		"widgets": [],
		"properties": {
			"positionX": 100.0 + spawn_offset,
			"positionY": 100.0 + spawn_offset,
			"sizeX": 200.0,
			"sizeY": 150.0
		}
	}

	# Create actual container
	var container = _create_container(container_type)
	container.global_position = viewport_offset + Vector2(node_data["properties"]["positionX"], node_data["properties"]["positionY"])
	container.set_meta("node_id", node_id)
	all_nodes[node_id] = container

	# Add to scene tree data
	var parent_data = _find_node_data(parent_id)
	if not parent_data.is_empty():
		if not parent_data.has("children"):
			parent_data["children"] = []
		parent_data["children"].append(node_data)

	spawn_offset += 30
	if spawn_offset > 150:
		spawn_offset = 0

	_refresh_hierarchy()


func _add_widget_node(parent_id: int, widget_type: String) -> void:
	# Find parent container
	if not all_nodes.has(parent_id):
		print("Parent not found for widget")
		return

	var parent = all_nodes[parent_id]
	if parent is DraggableContainer:
		var widget = parent._spawn_widget(widget_type)
		if widget:
			var node_id = _get_next_node_id()
			widget.set_meta("node_id", node_id)

			# Add to tree data
			var parent_data = _find_node_data(parent_id)
			if not parent_data.is_empty():
				if not parent_data.has("widgets"):
					parent_data["widgets"] = []
				parent_data["widgets"].append({
					"id": node_id,
					"type": widget_type,
					"name": widget_type,
					"properties": {}
				})

			_refresh_hierarchy()


func _add_2d_node(parent_id: int, node_type: String) -> void:
	var node_id = _get_next_node_id()
	var node_data = {
		"id": node_id,
		"type": node_type,
		"name": node_type,
		"children": [],
		"properties": {
			"positionX": 400.0 + spawn_offset,
			"positionY": 300.0 + spawn_offset
		}
	}

	# Create actual 2D node
	var node: Node2D
	match node_type:
		"Node2D":
			node = Node2D.new()
		"Sprite2D":
			node = Sprite2D.new()
		"AnimatedSprite2D":
			node = AnimatedSprite2D.new()
		_:
			node = Node2D.new()

	node.name = node_type + "_" + str(node_id)
	node.position = Vector2(node_data["properties"]["positionX"], node_data["properties"]["positionY"])
	node.set_meta("node_id", node_id)

	# Add to scene tree
	add_child(node)
	all_nodes[node_id] = node

	# Add to data tree
	var parent_data = _find_node_data(parent_id)
	if not parent_data.is_empty():
		if not parent_data.has("children"):
			parent_data["children"] = []
		parent_data["children"].append(node_data)

	spawn_offset += 30
	if spawn_offset > 150:
		spawn_offset = 0

	_refresh_hierarchy()


func _add_animation_node(parent_id: int, node_type: String) -> void:
	var node_id = _get_next_node_id()
	var node_data = {
		"id": node_id,
		"type": node_type,
		"name": node_type,
		"children": [],
		"properties": {}
	}

	# Create AnimationPlayer
	var anim_player = AnimationPlayer.new()
	anim_player.name = "AnimationPlayer_" + str(node_id)
	anim_player.set_meta("node_id", node_id)

	# Add to parent node
	if all_nodes.has(parent_id):
		var parent = all_nodes[parent_id]
		if parent is Node:
			parent.add_child(anim_player)
	else:
		add_child(anim_player)

	all_nodes[node_id] = anim_player

	# Add to data tree
	var parent_data = _find_node_data(parent_id)
	if not parent_data.is_empty():
		if not parent_data.has("children"):
			parent_data["children"] = []
		parent_data["children"].append(node_data)

	_refresh_hierarchy()


func _on_node_spawn_requested(node_type: String) -> void:
	# Add to selected node, or root if nothing selected
	var parent_id = selected_node_id if selected_node_id > 0 else scene_root.get("id", 1)

	# Determine node category and call appropriate function
	if node_type in SceneHierarchyScript.NODE_CATEGORIES["Control"]:
		_add_container_node(parent_id, node_type)
	elif node_type in SceneHierarchyScript.NODE_CATEGORIES["UI"]:
		_add_widget_node(parent_id, node_type)
	elif node_type in SceneHierarchyScript.NODE_CATEGORIES["2D"]:
		_add_2d_node(parent_id, node_type)
	elif node_type in SceneHierarchyScript.NODE_CATEGORIES["Animation"]:
		_add_animation_node(parent_id, node_type)

	print("Spawned node: ", node_type, " under parent ID: ", parent_id)


func _create_container(container_type: String) -> DraggableContainer:
	var container = DraggableContainerScene.instantiate()
	add_child(container)

	# Set the container type
	container.set_container_type(container_type)

	# Connect signals
	container.closed.connect(_on_container_closed.bind(container))
	container.drag_ended.connect(_on_container_drag_ended)
	container.unlinked.connect(_on_container_unlinked)
	container.selected.connect(_on_container_selected_in_viewport)

	# Track this container
	all_containers.append(container)

	return container


func _create_standalone_widget(widget_type: String, props: Dictionary, node_name: String = "") -> DraggableContainer:
	"""Create a DraggableContainer wrapping a widget for display in viewport"""
	var container = DraggableContainerScene.instantiate()
	add_child(container)

	# Set as PanelContainer internally but display widget type
	container.set_container_type("PanelContainer")

	# Apply widget-specific color
	var color = SceneHierarchyScript.NODE_COLORS.get(widget_type, Color(0.5, 0.5, 0.5))
	container._apply_color(color)

	# Set the display name
	if node_name.is_empty():
		container.title_label.text = widget_type
	else:
		container.title_label.text = node_name + " (" + widget_type + ")"

	# Connect signals
	container.closed.connect(_on_container_closed.bind(container))
	container.drag_ended.connect(_on_container_drag_ended)
	container.unlinked.connect(_on_container_unlinked)
	container.selected.connect(_on_container_selected_in_viewport)

	# Track this container
	all_containers.append(container)

	# Add the actual widget to the container
	var size_x = props.get("sizeX", props.get("minSizeX", 64))
	var size_y = props.get("sizeY", props.get("minSizeY", 64))
	container.add_widget_from_data(widget_type, props)

	# Set container size based on widget
	container.size = Vector2(size_x + 20, size_y + 40)  # Add padding for title bar

	return container


func _create_2d_node_container(node_type: String, props: Dictionary, node_name: String = "") -> DraggableContainer:
	"""Create a DraggableContainer with placeholder for 2D nodes (Sprite2D, etc.)"""
	var container = DraggableContainerScene.instantiate()
	add_child(container)

	# Set as PanelContainer internally
	container.set_container_type("PanelContainer")

	# Apply 2D node color
	var color = SceneHierarchyScript.NODE_COLORS.get(node_type, Color(0.4, 0.6, 0.8))
	container._apply_color(color)

	# Set the display name
	if node_name.is_empty():
		container.title_label.text = node_type
	else:
		container.title_label.text = node_name + " (" + node_type + ")"

	# Connect signals
	container.closed.connect(_on_container_closed.bind(container))
	container.drag_ended.connect(_on_container_drag_ended)
	container.unlinked.connect(_on_container_unlinked)
	container.selected.connect(_on_container_selected_in_viewport)

	# Track this container
	all_containers.append(container)

	# Create placeholder based on node type
	var size_x = props.get("sizeX", 64)
	var size_y = props.get("sizeY", 64)
	var placeholder = ColorRect.new()

	match node_type:
		"Sprite2D", "AnimatedSprite2D":
			placeholder.color = Color(0.5, 0.8, 0.5, 0.7)  # Green for sprites
		"Node2D":
			placeholder.color = Color(0.4, 0.6, 0.8, 0.7)  # Blue for Node2D
		_:
			placeholder.color = Color(0.5, 0.5, 0.5, 0.7)  # Gray default

	placeholder.custom_minimum_size = Vector2(size_x, size_y)
	placeholder.mouse_filter = Control.MOUSE_FILTER_STOP
	placeholder.gui_input.connect(_on_placeholder_gui_input.bind(container))
	container.inner_container.add_child(placeholder)

	# Set container size
	container.size = Vector2(size_x + 20, size_y + 40)

	return container


func _on_placeholder_gui_input(event: InputEvent, container: DraggableContainer) -> void:
	"""Handle clicks on placeholder elements to select their container"""
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			container.selected.emit(container)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			# Show properties for the container
			var node_id = container.get_meta("node_id", -1)
			if node_id >= 0:
				var node_data = _find_node_data(node_id)
				if not node_data.is_empty():
					_show_properties_dialog(node_id, node_data)


func _on_container_closed(container: Node) -> void:
	all_containers.erase(container)

	# Remove from hierarchy
	var node_id = container.get_meta("node_id", -1)
	if node_id >= 0:
		_remove_node_from_tree(node_id)
		_refresh_hierarchy()

	print("Container closed")


func _on_container_selected_in_viewport(container: DraggableContainer) -> void:
	# Get node ID from container
	var node_id = container.get_meta("node_id", -1)
	if node_id < 0:
		return

	# Highlight container visually
	_highlight_container(container)

	# Select in hierarchy without pruning
	selected_node_id = node_id
	if scene_hierarchy:
		scene_hierarchy.select_node(node_id)


func _on_container_unlinked(container: DraggableContainer) -> void:
	if container.parent_container:
		var old_parent = container.parent_container
		old_parent.remove_child_container(container)

		# Add back to main scene
		add_child(container)
		all_containers.append(container)
		print("Unlinked ", container.container_type, " from parent")


func _on_container_drag_ended(dragged_container: DraggableContainer) -> void:
	# Check if this container was dropped inside another container
	var target_container = _find_container_at_position(dragged_container)

	if target_container and target_container != dragged_container:
		# Check if target is not a child of dragged (prevent circular nesting)
		if not _is_descendant_of(target_container, dragged_container):
			print("Dropping ", dragged_container.container_type, " into ", target_container.container_type)

			# Remove from tracking if it's a top-level container
			if dragged_container in all_containers:
				all_containers.erase(dragged_container)

			# Reparent to the target container
			target_container.add_child_container(dragged_container)
	else:
		# Dropped outside any container - if it has a parent, remove it from parent
		if dragged_container.parent_container:
			var old_parent = dragged_container.parent_container
			old_parent.remove_child_container(dragged_container)

			# Add back to main scene
			add_child(dragged_container)
			all_containers.append(dragged_container)
			print("Removed ", dragged_container.container_type, " from parent")


func _find_container_at_position(exclude_container: DraggableContainer) -> DraggableContainer:
	var mouse_pos = get_global_mouse_position()
	var best_container: DraggableContainer = null
	var smallest_area := INF

	# Check all top-level containers and their children
	for container in all_containers:
		var found = _find_deepest_container_at(container, mouse_pos, exclude_container)
		if found:
			var area = found.size.x * found.size.y
			if area < smallest_area:
				smallest_area = area
				best_container = found

	return best_container


func _find_deepest_container_at(container: DraggableContainer, pos: Vector2, exclude: DraggableContainer) -> DraggableContainer:
	if container == exclude:
		return null

	var content_rect = container.get_content_panel().get_global_rect()

	if not content_rect.has_point(pos):
		return null

	# Check children first (they're on top)
	for child in container.get_child_containers():
		var found = _find_deepest_container_at(child, pos, exclude)
		if found:
			return found

	# No child contains the point, return this container
	return container


func _is_descendant_of(potential_child: DraggableContainer, potential_parent: DraggableContainer) -> bool:
	var current = potential_child.parent_container
	while current:
		if current == potential_parent:
			return true
		current = current.parent_container
	return false


func _on_project_selected(project_data: Dictionary) -> void:
	current_project_id = project_data.get("ID", -1)
	current_project_name = project_data.get("Name", "Unknown")
	print("Main received project: ", current_project_name, " (ID: ", current_project_id, ")")


# ==================== SAVE ====================

func _on_save_requested() -> void:
	if current_project_id < 0:
		print("No project selected. Please select a project first.")
		return

	var layout_data = _serialize_layout()
	_save_to_dynamodb(layout_data)


func _serialize_layout() -> Dictionary:
	# Serialize the full scene tree with updated node positions
	var scene_data = _serialize_scene_tree(scene_root)

	return {
		"projectID": current_project_id,
		"projectName": current_project_name,
		"sceneRoot": scene_data,
		"savedAt": Time.get_datetime_string_from_system()
	}


func _serialize_scene_tree(node_data: Dictionary) -> Dictionary:
	var data := {
		"id": node_data.get("id", 0),
		"type": node_data.get("type", "Node2D"),
		"name": node_data.get("name", ""),
		"children": [],
		"widgets": [],
		"properties": node_data.get("properties", {}).duplicate()
	}

	# Update properties from actual node if it exists
	var node_id = node_data.get("id", -1)
	if all_nodes.has(node_id):
		var node = all_nodes[node_id]
		if node is DraggableContainer:
			data["properties"]["positionX"] = node.global_position.x
			data["properties"]["positionY"] = node.global_position.y
			data["properties"]["sizeX"] = node.size.x
			data["properties"]["sizeY"] = node.size.y
			data["name"] = node.container_name if not node.container_name.is_empty() else node.container_type

			# Serialize layout properties
			if node.inner_container:
				var inner = node.inner_container
				if inner is GridContainer:
					data["properties"]["columns"] = inner.columns
				if inner is BoxContainer:
					data["properties"]["alignment"] = inner.alignment
					data["properties"]["separation"] = inner.get_theme_constant("separation")

			# Serialize widgets from actual container
			for widget in node.get_widgets():
				var widget_data = _serialize_widget(widget)
				data["widgets"].append(widget_data)

		elif node is Node2D:
			data["properties"]["positionX"] = node.position.x
			data["properties"]["positionY"] = node.position.y
			if node is Sprite2D and node.texture:
				data["properties"]["texture"] = node.texture.resource_path

	# Serialize children recursively
	for child in node_data.get("children", []):
		var child_data = _serialize_scene_tree(child)
		data["children"].append(child_data)

	return data


func _serialize_container(container: DraggableContainer, parent_id: int) -> Dictionary:
	var container_id = container.get_meta("container_id", 0)

	var data := {
		"id": container_id,
		"type": container.container_type,
		"name": container.container_name,
		"positionX": container.global_position.x,
		"positionY": container.global_position.y,
		"sizeX": container.size.x,
		"sizeY": container.size.y,
		"parentID": parent_id,
		"children": [],
		"widgets": [],
		"layoutProperties": {}
	}

	# Serialize layout properties from inner_container
	if container.inner_container:
		var inner = container.inner_container
		if inner is GridContainer:
			data["layoutProperties"]["columns"] = inner.columns
		if inner is BoxContainer:
			data["layoutProperties"]["alignment"] = inner.alignment
			data["layoutProperties"]["separation"] = inner.get_theme_constant("separation")

	# Serialize widgets
	for widget in container.get_widgets():
		var widget_data = _serialize_widget(widget)
		data["widgets"].append(widget_data)

	# Serialize children
	for child in container.get_child_containers():
		var child_data = _serialize_container(child, container_id)
		data["children"].append(child_data)

	return data


func _serialize_widget(widget: Control) -> Dictionary:
	var widget_type = widget.get_meta("widget_type", "Unknown")

	var data := {
		"type": widget_type,
		"properties": {}
	}

	# Common size properties
	data["properties"]["minSizeX"] = widget.custom_minimum_size.x
	data["properties"]["minSizeY"] = widget.custom_minimum_size.y

	# Save properties based on widget type
	if "text" in widget:
		data["properties"]["text"] = widget.text
	if "placeholder_text" in widget:
		data["properties"]["placeholder_text"] = widget.placeholder_text
	if "value" in widget:
		data["properties"]["value"] = widget.value
	if "min_value" in widget:
		data["properties"]["min_value"] = widget.min_value
	if "max_value" in widget:
		data["properties"]["max_value"] = widget.max_value
	if "step" in widget:
		data["properties"]["step"] = widget.step
	if "color" in widget and widget_type in ["ColorRect", "ColorPickerButton"]:
		data["properties"]["color"] = widget.color.to_html()
	if "button_pressed" in widget:
		data["properties"]["button_pressed"] = widget.button_pressed
	if "bbcode_enabled" in widget:
		data["properties"]["bbcode_enabled"] = widget.bbcode_enabled

	# OptionButton items
	if widget is OptionButton:
		var items := []
		for i in range(widget.item_count):
			items.append(widget.get_item_text(i))
		data["properties"]["items"] = items
		data["properties"]["selected"] = widget.selected

	return data


# ==================== DYNAMODB TYPE CONVERSION ====================

# Convert GDScript value to DynamoDB attribute format
func _to_dynamodb_attr(value) -> Dictionary:
	if value == null:
		return {"NULL": true}
	elif value is bool:
		return {"BOOL": value}
	elif value is int or value is float:
		return {"N": str(value)}
	elif value is String:
		return {"S": value}
	elif value is Array:
		var list_items := []
		for item in value:
			list_items.append(_to_dynamodb_attr(item))
		return {"L": list_items}
	elif value is Dictionary:
		var map_items := {}
		for key in value.keys():
			map_items[str(key)] = _to_dynamodb_attr(value[key])
		return {"M": map_items}
	else:
		# Fallback to string representation
		return {"S": str(value)}


# Convert DynamoDB attribute format to GDScript value
func _from_dynamodb_attr(attr: Dictionary):
	if attr.has("S"):
		return attr["S"]
	elif attr.has("N"):
		var num_str = attr["N"]
		if "." in num_str:
			return float(num_str)
		else:
			return int(num_str)
	elif attr.has("BOOL"):
		return attr["BOOL"]
	elif attr.has("NULL"):
		return null
	elif attr.has("L"):
		var result := []
		for item in attr["L"]:
			result.append(_from_dynamodb_attr(item))
		return result
	elif attr.has("M"):
		var result := {}
		for key in attr["M"].keys():
			result[key] = _from_dynamodb_attr(attr["M"][key])
		return result
	else:
		return null


func _save_to_dynamodb(layout_data: Dictionary) -> void:
	var endpoint := "http://zycroft.duckdns.org:8001"

	var headers := [
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.PutItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	]

	# Convert layout to DynamoDB format using native Map type
	var item := {
		"projectID": {"N": str(layout_data["projectID"])},
		"projectName": {"S": layout_data["projectName"]},
		"sceneRoot": _to_dynamodb_attr(layout_data["sceneRoot"]),
		"savedAt": {"S": layout_data["savedAt"]}
	}

	var body := JSON.stringify({
		"TableName": "SceneLayout",
		"Item": item
	})

	print("Saving scene to DynamoDB...")
	var error = save_http_request.request(endpoint, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		print("Failed to send save request: ", error)


func _on_save_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code == 200:
		print("Layout saved successfully!")
	else:
		var error_body = body.get_string_from_utf8()
		print("Failed to save layout: ", response_code, " - ", error_body)


# ==================== LOAD ====================

func _on_load_requested() -> void:
	if current_project_id < 0:
		print("No project selected. Please select a project first.")
		return

	_load_from_dynamodb()


func _load_from_dynamodb() -> void:
	var endpoint := "http://zycroft.duckdns.org:8001"

	var headers := [
		"Content-Type: application/x-amz-json-1.0",
		"X-Amz-Target: DynamoDB_20120810.GetItem",
		"Authorization: AWS4-HMAC-SHA256 Credential=placeholder/20250101/us-east-1/dynamodb/aws4_request, SignedHeaders=host;x-amz-date;x-amz-target, Signature=placeholder",
		"X-Amz-Date: 20250101T000000Z"
	]

	var body := JSON.stringify({
		"TableName": "SceneLayout",
		"Key": {
			"projectID": {"N": str(current_project_id)}
		}
	})

	print("Loading scene from DynamoDB...")
	var error = load_http_request.request(endpoint, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		print("Failed to send load request: ", error)


func _on_load_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json and json.has("Item"):
			var item = json["Item"]

			# Parse scene root from DynamoDB Map type
			var scene_root_attr = item.get("sceneRoot", {})
			var scene_data

			# Support both Map type (new) and String type (legacy)
			if scene_root_attr.has("M"):
				scene_data = _from_dynamodb_attr(scene_root_attr)
			elif scene_root_attr.has("S"):
				# Legacy: parse JSON string
				scene_data = JSON.parse_string(scene_root_attr["S"])

			if scene_data and not scene_data.is_empty():
				_clear_all_scene_nodes()
				_deserialize_scene_tree(scene_data)
				# Bring panels to front after loading
				if scene_hierarchy:
					scene_hierarchy.move_to_front()
				if controls_panel:
					controls_panel.move_to_front()
		else:
			print("No saved scene found for this project")
	else:
		var error_body = body.get_string_from_utf8()
		print("Failed to load scene: ", response_code, " - ", error_body)


func _clear_all_containers() -> void:
	# Remove all existing containers
	for container in all_containers.duplicate():
		if is_instance_valid(container):
			container.queue_free()
	all_containers.clear()


func _clear_all_scene_nodes() -> void:
	# Remove all containers
	for container in all_containers.duplicate():
		if is_instance_valid(container):
			container.queue_free()
	all_containers.clear()

	# Remove all tracked nodes
	for node_id in all_nodes.keys():
		var node = all_nodes[node_id]
		if is_instance_valid(node) and node is Node:
			node.queue_free()
	all_nodes.clear()

	# Reset counters
	node_id_counter = 0

	# Initialize fresh root
	_initialize_scene_root()


func _deserialize_scene_tree(scene_data: Dictionary) -> void:
	# Set scene root data
	scene_root = scene_data.duplicate(true)

	# Track max ID to avoid conflicts
	_update_max_node_id(scene_root)

	# Create actual nodes from the scene data
	_create_nodes_from_tree(scene_root, null)

	# Refresh hierarchy display
	_refresh_hierarchy()


func _update_max_node_id(node_data: Dictionary) -> void:
	var node_id = node_data.get("id", 0)
	if node_id > node_id_counter:
		node_id_counter = node_id

	for child in node_data.get("children", []):
		_update_max_node_id(child)

	for widget in node_data.get("widgets", []):
		var widget_id = widget.get("id", 0)
		if widget_id > node_id_counter:
			node_id_counter = widget_id


func _create_nodes_from_tree(node_data: Dictionary, _parent_node) -> void:
	var node_type = node_data.get("type", "Node2D")
	var node_id = node_data.get("id", 0)
	var props = node_data.get("properties", {})

	# Skip root node creation (it's just a virtual container)
	if node_id == scene_root.get("id"):
		all_nodes[node_id] = scene_root
		# Process widgets of root node
		for widget_data in node_data.get("widgets", []):
			var widget_type = widget_data.get("type", "Label")
			var widget_props = widget_data.get("properties", {})
			var widget_name = widget_data.get("name", widget_type)
			var container = _create_standalone_widget(widget_type, widget_props, widget_name)
			if container:
				var widget_id = widget_data.get("id", _get_next_node_id())
				container.set_meta("node_id", widget_id)
				var pos_x = widget_props.get("positionX", 0)
				var pos_y = widget_props.get("positionY", 0)
				container.global_position = viewport_offset + Vector2(pos_x, pos_y)
				all_nodes[widget_id] = container
		# Process children directly
		for child in node_data.get("children", []):
			_create_nodes_from_tree(child, null)
		return

	# Create node based on type
	if node_type in SceneHierarchyScript.NODE_CATEGORIES["Control"]:
		# Create container
		var container = _create_container(node_type)
		container.set_meta("node_id", node_id)
		container.global_position = viewport_offset + Vector2(props.get("positionX", 100), props.get("positionY", 100))
		container.size = Vector2(props.get("sizeX", 200), props.get("sizeY", 150))

		var node_name = node_data.get("name", "")
		if node_name and node_name != node_type:
			container.set_container_name(node_name)

		# Restore layout properties
		if container.inner_container:
			var inner = container.inner_container
			if inner is GridContainer and props.has("columns"):
				inner.columns = props["columns"]
			if inner is BoxContainer:
				if props.has("alignment"):
					inner.alignment = props["alignment"]
				if props.has("separation"):
					inner.add_theme_constant_override("separation", props["separation"])

		all_nodes[node_id] = container

		# Create widgets
		for widget_data in node_data.get("widgets", []):
			var widget_type = widget_data.get("type", "Label")
			var widget_props = widget_data.get("properties", {})
			var widget = container.add_widget_from_data(widget_type, widget_props)
			if widget:
				var widget_id = widget_data.get("id", _get_next_node_id())
				widget.set_meta("node_id", widget_id)
				all_nodes[widget_id] = widget

	elif node_type in SceneHierarchyScript.NODE_CATEGORIES["2D"]:
		# Create 2D node in draggable container
		var node_name = node_data.get("name", node_type)
		var container = _create_2d_node_container(node_type, props, node_name)
		container.set_meta("node_id", node_id)
		var pos_x = props.get("positionX", 100)
		var pos_y = props.get("positionY", 100)
		container.global_position = viewport_offset + Vector2(pos_x, pos_y)
		all_nodes[node_id] = container

		# Create widgets for 2D nodes (positioned relative to parent)
		for widget_data in node_data.get("widgets", []):
			var widget_type = widget_data.get("type", "Label")
			var widget_props = widget_data.get("properties", {})
			var widget_name_inner = widget_data.get("name", widget_type)
			var widget_container = _create_standalone_widget(widget_type, widget_props, widget_name_inner)
			if widget_container:
				var widget_id = widget_data.get("id", _get_next_node_id())
				widget_container.set_meta("node_id", widget_id)
				var wpos_x = widget_props.get("positionX", 0)
				var wpos_y = widget_props.get("positionY", 0)
				widget_container.global_position = viewport_offset + Vector2(pos_x + wpos_x, pos_y + wpos_y)
				all_nodes[widget_id] = widget_container

	elif node_type == "AnimationPlayer":
		var anim_player = AnimationPlayer.new()
		anim_player.name = "AnimationPlayer_" + str(node_id)
		anim_player.set_meta("node_id", node_id)
		add_child(anim_player)
		all_nodes[node_id] = anim_player

	elif node_type == "AudioStreamPlayer":
		var audio_player = AudioStreamPlayer.new()
		audio_player.name = node_data.get("name", "AudioStreamPlayer") + "_" + str(node_id)
		audio_player.set_meta("node_id", node_id)
		add_child(audio_player)
		all_nodes[node_id] = audio_player

	elif node_type in SceneHierarchyScript.NODE_CATEGORIES["UI"]:
		# Standalone widget selected - create in draggable container
		var widget_name = node_data.get("name", node_type)
		var container = _create_standalone_widget(node_type, props, widget_name)
		if container:
			container.set_meta("node_id", node_id)
			# Position the container in viewport
			var pos_x = props.get("positionX", 100)
			var pos_y = props.get("positionY", 100)
			container.global_position = viewport_offset + Vector2(pos_x, pos_y)
			all_nodes[node_id] = container

	# Process children recursively
	for child in node_data.get("children", []):
		_create_nodes_from_tree(child, all_nodes.get(node_id))


func _deserialize_layout(containers_data: Array) -> void:
	# First pass: create all top-level containers
	for container_data in containers_data:
		_create_container_from_data(container_data, null)


func _create_container_from_data(data: Dictionary, parent: DraggableContainer) -> DraggableContainer:
	var container_type = data.get("type", "VBoxContainer")
	var container: DraggableContainer

	if parent == null:
		# Top-level container
		container = _create_container(container_type)
	else:
		# Child container - create and add to parent first, then configure
		container = DraggableContainerScene.instantiate()

		# Add to parent's content panel FIRST so @onready vars are initialized
		parent.get_content_panel().add_child(container)

		# Now we can safely configure
		container.set_meta("container_id", data.get("id", 0))
		node_id_counter = max(node_id_counter, data.get("id", 0))
		container.set_container_type(container_type)
		container.parent_container = parent
		container.unlink_button.visible = true

		# Connect signals
		container.closed.connect(_on_container_closed.bind(container))
		container.drag_ended.connect(_on_container_drag_ended)
		container.unlinked.connect(_on_container_unlinked)
		container.selected.connect(_on_container_selected_in_viewport)

	# Set position and size (with viewport offset)
	container.global_position = viewport_offset + Vector2(data.get("positionX", 0), data.get("positionY", 0))
	container.size = Vector2(data.get("sizeX", 200), data.get("sizeY", 150))

	# Set container name if present
	var saved_name = data.get("name", "")
	if saved_name:
		container.set_container_name(saved_name)

	# Update node_id_counter to avoid ID conflicts
	var data_id = data.get("id", 0)
	if data_id > 0:
		container.set_meta("container_id", data_id)
		node_id_counter = max(node_id_counter, data_id)

	# Restore layout properties
	var layout_props = data.get("layoutProperties", {})
	if container.inner_container:
		var inner = container.inner_container
		if inner is GridContainer and layout_props.has("columns"):
			inner.columns = layout_props["columns"]
		if inner is BoxContainer:
			if layout_props.has("alignment"):
				inner.alignment = layout_props["alignment"]
			if layout_props.has("separation"):
				inner.add_theme_constant_override("separation", layout_props["separation"])

	# Restore widgets
	var widgets = data.get("widgets", [])
	for widget_data in widgets:
		var widget_type = widget_data.get("type", "Label")
		var properties = widget_data.get("properties", {})
		container.add_widget_from_data(widget_type, properties)

	# Recursively create children
	var children = data.get("children", [])
	for child_data in children:
		_create_container_from_data(child_data, container)

	return container
