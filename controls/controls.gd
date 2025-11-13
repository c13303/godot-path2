extends Node2D

@onready var floorz: TileMapLayer = $"../MonTilemap/floor"
@onready var wallz: TileMapLayer = $"../MonTilemap/wallz"
@onready var flow: Node = $"../FlowFieldNative"
@onready var steering: Node = $"../SteeringSystemNative"
@onready var marker: Node2D = preload("res://UI_elements/green_circle.tscn").instantiate()
@onready var ui_layer: CanvasLayer = $"../CanvasLayer"

@export var camera: Camera2D
@export var speed: float = 400.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0

var current_flow: Node = null
var dragging: bool = false
var drag_start_pos: Vector2
var camera_start_pos: Vector2
var MainCharScene: PackedScene = preload("res://character/character.tscn")

# Rectangle de sélection
var selecting: bool = false
var selection_start: Vector2 = Vector2.ZERO
var selection_rect: ColorRect
var selected_units: Array[Node2D] = []
var preview_units: Array[Node2D] = []  # Unités en prévisualisation

signal mouse_goal_set(world_pos: Vector2)

func _ready() -> void:
	add_child(marker)
	marker.visible = false
	marker.z_index = 1

	# Créer le rectangle de sélection dans le CanvasLayer
	if ui_layer:
		selection_rect = ColorRect.new()
		selection_rect.color = Color(0, 1, 0, 0.25)
		selection_rect.visible = false
		selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui_layer.add_child(selection_rect)
	else:
		var canvas = CanvasLayer.new()
		canvas.layer = 100
		add_child(canvas)
		
		selection_rect = ColorRect.new()
		selection_rect.color = Color(0, 1, 0, 0.25)
		selection_rect.visible = false
		selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		canvas.add_child(selection_rect)

	print("Controls initialized")

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				selecting = true
				selection_start = get_viewport().get_mouse_position()
				selection_rect.position = selection_start
				selection_rect.size = Vector2.ZERO
				selection_rect.visible = true
				_clear_selection()
			else:
				selecting = false
				selection_rect.visible = false
				_clear_preview()  # Nettoyer la prévisualisation
				
				# Traiter la sélection finale
				var mouse_end: Vector2 = get_viewport().get_mouse_position()
				var rect_pos: Vector2 = Vector2(
					min(selection_start.x, mouse_end.x),
					min(selection_start.y, mouse_end.y)
				)
				var rect_size: Vector2 = Vector2(
					abs(mouse_end.x - selection_start.x),
					abs(mouse_end.y - selection_start.y)
				)
				var selection_rectangle := Rect2(rect_pos, rect_size)
				_process_selection(selection_rectangle)

		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_on_click_set_goal()

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed and camera:
			camera.zoom = Vector2(
				clamp(camera.zoom.x - zoom_speed, min_zoom, max_zoom),
				clamp(camera.zoom.y - zoom_speed, min_zoom, max_zoom)
			)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed and camera:
			camera.zoom = Vector2(
				clamp(camera.zoom.x + zoom_speed, min_zoom, max_zoom),
				clamp(camera.zoom.y + zoom_speed, min_zoom, max_zoom)
			)

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_A:
			_on_key_spawn_chars()
		elif event.keycode == KEY_Z:
			_on_key_spawn_chars_massive(10)
		elif event.keycode == KEY_E:
			_on_key_spawn_chars_massive(50)

func _process(delta: float) -> void:
	if camera == null:
		return

	var input: Vector2 = Vector2.ZERO

	if Input.is_action_pressed("ui_right"):
		input.x += 1.0
	if Input.is_action_pressed("ui_left"):
		input.x -= 1.0
	if Input.is_action_pressed("ui_down"):
		input.y += 1.0
	if Input.is_action_pressed("ui_up"):
		input.y -= 1.0

	if input != Vector2.ZERO:
		camera.position += input.normalized() * speed * delta

	if dragging and camera:
		var mouse_pos: Vector2 = get_viewport().get_mouse_position()
		var offset: Vector2 = (drag_start_pos - mouse_pos) * camera.zoom
		camera.position = camera_start_pos + offset

	# Mise à jour du rectangle et prévisualisation
	if selecting:
		var mouse_pos: Vector2 = get_viewport().get_mouse_position()

		var rect_pos: Vector2 = Vector2(
			min(selection_start.x, mouse_pos.x),
			min(selection_start.y, mouse_pos.y)
		)
		var rect_size: Vector2 = Vector2(
			abs(mouse_pos.x - selection_start.x),
			abs(mouse_pos.y - selection_start.y)
		)

		selection_rect.position = rect_pos
		selection_rect.size = rect_size
		
		# Prévisualiser la sélection en temps réel
		var preview_rect := Rect2(rect_pos, rect_size)
		_preview_selection(preview_rect)

func _preview_selection(rect: Rect2) -> void:
	if camera == null:
		return
	
	# Liste temporaire des unités dans le rectangle
	var units_in_rect: Array[Node2D] = []
	
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var n2d := node as Node2D
			var canvas_transform = get_viewport().get_canvas_transform()
			var screen_pos: Vector2 = canvas_transform * n2d.global_position
			
			if rect.has_point(screen_pos):
				units_in_rect.append(n2d)
	
	# Retirer la prévisualisation des unités qui ne sont plus dans le rectangle
	for unit in preview_units:
		if is_instance_valid(unit) and not units_in_rect.has(unit):
			if unit.has_method("set_previewed"):
				unit.set_previewed(false)
			else:
				unit.modulate = Color(1.0, 1.0, 1.0, 1.0)
	
	# Ajouter la prévisualisation aux nouvelles unités
	for unit in units_in_rect:
		if not preview_units.has(unit):
			if unit.has_method("set_previewed"):
				unit.set_previewed(true)
			else:
				# Couleur jaune/dorée pour la prévisualisation
				unit.modulate = Color(1.3, 1.3, 0.8, 1.0)
	
	# Mettre à jour la liste
	preview_units = units_in_rect

func _clear_preview() -> void:
	for unit in preview_units:
		if is_instance_valid(unit):
			if unit.has_method("set_previewed"):
				unit.set_previewed(false)
			else:
				unit.modulate = Color(1.0, 1.0, 1.0, 1.0)
	preview_units.clear()

func _process_selection(rect: Rect2) -> void:
	if camera == null:
		return
	
	if rect.size.x < 3 and rect.size.y < 3:
		return

	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var n2d := node as Node2D
			var canvas_transform = get_viewport().get_canvas_transform()
			var screen_pos: Vector2 = canvas_transform * n2d.global_position
			
			if rect.has_point(screen_pos):
				_select_unit(n2d)

func _select_unit(unit: Node2D) -> void:
	if not selected_units.has(unit):
		selected_units.append(unit)
		if unit.has_method("set_selected"):
			unit.set_selected(true)
		else:
			# Couleur verte pour la sélection finale
			unit.modulate = Color(0.8, 1.5, 0.8, 1.0)
		print("Unité sélectionnée : ", unit.name)

func _clear_selection() -> void:
	for unit in selected_units:
		if is_instance_valid(unit):
			if unit.has_method("set_selected"):
				unit.set_selected(false)
			else:
				unit.modulate = Color(1.0, 1.0, 1.0, 1.0)
	selected_units.clear()

func _on_click_set_goal() -> void:
	if floorz == null:
		print("Erreur : le TileMapLayer 'floor' est introuvable.")
		return

	var mouse_pos: Vector2 = get_global_mouse_position()
	var local_pos: Vector2 = floorz.to_local(mouse_pos)
	var cell: Vector2i = floorz.local_to_map(local_pos)

	var cell_center: Vector2 = floorz.to_global(floorz.map_to_local(cell))

	marker.global_position = cell_center
	marker.visible = false

	emit_signal("mouse_goal_set", cell_center)

	if flow and flow.has_method("rebuild_async"):
		flow.rebuild_async(cell_center)
		current_flow = flow
	else:
		print("FlowField non trouvé ou inactif.")

func _on_key_spawn_chars() -> void:
	var mouse_pos: Vector2 = get_global_mouse_position()
	_spawn_mainchar(mouse_pos)

func _on_key_spawn_chars_massive(grappe: int) -> void:
	var mouse_pos: Vector2 = get_global_mouse_position()
	for i in range(grappe):
		_spawn_mainchar(mouse_pos)

func _spawn_mainchar(pos: Vector2) -> void:
	if floorz == null:
		print("Erreur : floorz introuvable.")
		return

	var target_cell: Vector2i = floorz.local_to_map(floorz.to_local(pos))
	var occupied: Array[Vector2i] = []

	for node in get_tree().get_nodes_in_group("main_chars"):
		var c: Vector2i = floorz.local_to_map(floorz.to_local(node.global_position))
		occupied.append(c)

	var free_cell: Vector2i = _find_free_cell_near(target_cell, occupied)
	var free_pos: Vector2 = floorz.to_global(floorz.map_to_local(free_cell))

	var agent: Node2D = MainCharScene.instantiate()
	get_parent().add_child(agent)
	agent.global_position = free_pos
	agent.z_index = int(free_pos.y)
	agent.add_to_group("main_chars")

	if steering and steering.has_method("register_agent"):
		var flow_ref = current_flow if current_flow != null else null
		steering.register_agent(agent, 120.0, flow_ref)

func _find_free_cell_near(start_cell: Vector2i, occupied: Array[Vector2i], max_radius: int = 6) -> Vector2i:
	if not occupied.has(start_cell) and _is_walkable(start_cell):
		return start_cell

	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var c: Vector2i = start_cell + Vector2i(dx, dy)
				if occupied.has(c):
					continue
				if _is_walkable(c):
					return c

	return start_cell

func _is_walkable(cell: Vector2i) -> bool:
	var has_floor := floorz.get_cell_tile_data(cell) != null
	var has_wall := wallz != null and wallz.get_cell_tile_data(cell) != null
	return has_floor and not has_wall
