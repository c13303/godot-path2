extends Node2D

@onready var floorz: TileMapLayer = $"../Map/MonTilemap/floor"
@onready var wallz: TileMapLayer = $"../Map/MonTilemap/wallz"
@onready var blood_layer: Node2D = $"../Map/MonTilemap/BloodLayer"
@onready var blood_texture_rect: TextureRect = $"../Map/MonTilemap/BloodLayer/bloodtexture"
@onready var flow: Node = $"../CPP/FlowFieldNative"
@onready var steering: Node = $"../CPP/SteeringSystemNative"
@onready var agent_manager: Node = $"../CPP/AgentManagerNative"
@onready var marker: Node2D = preload("res://UI_elements/green_circle.tscn").instantiate()
@onready var ui_layer: CanvasLayer = $"../UI/CanvasLayer"
var global_config_node: Node = null
const EXPLOSION_DEBUG_SCENE := preload("res://sprites/bomb/bomb.tscn")

@export var explosion_radius: float = 100
@export var explosion_intensity: float = 200
@export var explosion_friction: float = 0.91 # perte de vitesse par seconde appliquée à cette explosion
@export var explosion_debug_duration: float = 1.0 #visuel

@export var camera: Camera2D
@export var speed: float = 400.0
var scroll_margin_pixel: float = 100.0
@export var lock_mouse_to_view: bool = true
var _mouse_locked: bool = false
var _mouse_was_locked_before_pause: bool = false
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0

const BLOOD_COLORS: Array[Color] = [
	Color(0.6, 0.1, 0.1, 0.75),
	Color(0.45, 0.2, 0.08, 0.7),
	Color(0.65, 0.2, 0.08, 0.6)
]
const BLOOD_RADIUS := 6
const BLOOD_DOTS := 14

var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var blood_image: Image
var blood_image_texture: ImageTexture

var current_flow: Node = null
var current_group: int = -1
@onready var fps_label: Label = $"../UI/CanvasLayer/Label"
var mouse_outline: Line2D

var selecting: bool = false
var selection_start: Vector2
var selection_rect: ColorRect
var pause_outline: Panel

var selected_units: Array[Node2D] = []
var preview_units: Array[Node2D] = []

#signal mouse_goal_set(world_pos: Vector2)

func _ready() -> void:
	print("Controls _ready: ui_layer=", ui_layer)
	add_child(marker)
	marker.visible = false

	mouse_outline = Line2D.new()
	mouse_outline.default_color = Color(1, 1, 1, 1)
	mouse_outline.width = 1.0
	mouse_outline.closed = true
	mouse_outline.visible = false
	if flow and flow is Node2D:
		flow.add_child(mouse_outline)
	else:
		add_child(mouse_outline)

	if ui_layer:
		selection_rect = ColorRect.new()
		selection_rect.color = Color(0, 1, 0, 0.25)
		selection_rect.visible = false
		selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui_layer.add_child(selection_rect)
		print("Controls: using existing ui_layer=", ui_layer)
	else:
		var canvas := CanvasLayer.new()
		canvas.layer = 100
		add_child(canvas)
		ui_layer = canvas
		selection_rect = ColorRect.new()
		selection_rect.color = Color(0, 1, 0, 0.25)
		selection_rect.visible = false
		selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		canvas.add_child(selection_rect)
		print("Controls: created fallback ui_layer=", ui_layer)
	_initialize_pause_outline()
	var scene = get_tree().get_current_scene()
	if scene:
		global_config_node = scene.get_node_or_null("GlobalConfigNative")
	if lock_mouse_to_view:
		_set_mouse_locked(true)
	rng.randomize()
	_initialize_blood_canvas()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_A:
			_on_key_spawn_chars()
		elif event.keycode == KEY_Z:
			_on_key_spawn_chars_massive(10)
		elif event.keycode == KEY_E:
			_on_key_spawn_chars_massive(50)
		elif event.keycode == KEY_B:
			_on_key_trig_bomb()
		elif event.keycode == KEY_N:
			_on_key_trig_blood()
		elif event.keycode == KEY_SPACE:
			_toggle_pause()
		elif event.keycode == KEY_ESCAPE:
			_set_mouse_locked(false)
		elif event.keycode == KEY_TAB:
			_set_mouse_locked(true)
			
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
				_clear_preview()
				var mouse_end := get_viewport().get_mouse_position()
				var rect_pos := Vector2(min(selection_start.x, mouse_end.x), min(selection_start.y, mouse_end.y))
				var rect_size := Vector2(abs(mouse_end.x - selection_start.x), abs(mouse_end.y - selection_start.y))
				_process_selection(Rect2(rect_pos, rect_size))

		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_on_click_set_goal()

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_towards_mouse(zoom_speed)

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_towards_mouse(-zoom_speed)

func _process(delta: float) -> void:
	if selecting:
		var mouse_pos := get_viewport().get_mouse_position()
		selection_rect.position = Vector2(min(selection_start.x, mouse_pos.x), min(selection_start.y, mouse_pos.y))
		selection_rect.size = Vector2(abs(mouse_pos.x - selection_start.x), abs(mouse_pos.y - selection_start.y))
		_preview_selection(selection_rect.get_rect())

	_update_mouse_tile_ui()

	var mov := Vector2.ZERO
	if Input.is_key_pressed(KEY_UP):
		mov.y -= 1
	if Input.is_key_pressed(KEY_DOWN):
		mov.y += 1
	if Input.is_key_pressed(KEY_LEFT):
		mov.x -= 1
	if Input.is_key_pressed(KEY_RIGHT):
		mov.x += 1
	if mov != Vector2.ZERO:
		camera.position += mov.normalized() * speed * delta
	_scroll_camera_via_mouse(delta)

var _paused: bool = false
var _saved_animation_speed: Dictionary[int, float] = {}
func _scroll_camera_via_mouse(delta: float) -> void:
	if _paused:
		return
	if not camera or scroll_margin_pixel <= 0.0:
		return

	var viewport_rect: Rect2 = get_viewport().get_visible_rect()
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var scroll_vec: Vector2 = Vector2.ZERO

	scroll_vec.x = _scroll_axis(mouse_pos.x, viewport_rect.size.x)
	scroll_vec.y = _scroll_axis(mouse_pos.y, viewport_rect.size.y)

	if scroll_vec == Vector2.ZERO:
		return

	camera.position += scroll_vec * delta

func _scroll_axis(coord: float, dimension: float) -> float:
	if coord < 0.0 or coord > dimension:
		return 0.0

	var factor := 0.0
	if coord <= scroll_margin_pixel:
		var progress: float = clamp((scroll_margin_pixel - coord) / scroll_margin_pixel, 0.0, 1.0)
		factor = 0.2 + 0.8 * progress
		return -speed * factor
	elif coord >= dimension - scroll_margin_pixel:
		var dist: float = dimension - coord
		var progress: float = clamp((scroll_margin_pixel - dist) / scroll_margin_pixel, 0.0, 1.0)
		factor = 0.2 + 0.8 * progress
		return speed * factor

	return 0.0

func _set_mouse_locked(enabled: bool) -> void:
	if _mouse_locked == enabled:
		return

	_mouse_locked = enabled
	var mode: int = Input.MOUSE_MODE_VISIBLE
	if enabled:
		mode = Input.MOUSE_MODE_CONFINED
	Input.set_mouse_mode(mode)
func _initialize_pause_outline() -> void:
	if not ui_layer:
		print("Controls: ui_layer is null, cannot create pause_outline")
		return
	pause_outline = Panel.new()
	pause_outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pause_outline.visible = false
	pause_outline.z_index = 100
	pause_outline.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_outline.offset_left = 0.0
	pause_outline.offset_top = 0.0
	pause_outline.offset_right = 0.0
	pause_outline.offset_bottom = 0.0
	var style := StyleBoxFlat.new()
	style.border_color = Color(1, 0, 0, 1)
	style.border_width_top = 4
	style.border_width_bottom = 4
	style.border_width_left = 4
	style.border_width_right = 4
	style.bg_color = Color(0, 0, 0, 0)
	pause_outline.add_theme_stylebox_override("panel", style)
	ui_layer.add_child(pause_outline)
	print("Controls: pause_outline created, parent ui_layer=", ui_layer)
func _set_pause_outline_visible(enabled: bool) -> void:
	if not pause_outline:
		print("Controls: pause_outline is null in _set_pause_outline_visible, enabled=", enabled)
		return
	pause_outline.visible = enabled
	print("Controls: pause_outline visible=", pause_outline.visible)
	
func _toggle_pause() -> void:
	_paused = not _paused
	if steering and steering.has_method("set_paused"):
		steering.set_paused(_paused)
	if _paused:
		_mouse_was_locked_before_pause = _mouse_locked
		if _mouse_locked:
			_set_mouse_locked(false)
	else:
		if lock_mouse_to_view and _mouse_was_locked_before_pause:
			_set_mouse_locked(true)
	var hide_units := _paused
	if hide_units and global_config_node and global_config_node.has_method("get_draw_claimed_path"):
		if not global_config_node.get_draw_claimed_path():
			hide_units = false
	_toggle_units_visible(not hide_units)
	_set_character_animations_playing(not _paused)
	_set_pause_outline_visible(_paused)

func _toggle_units_visible(isvisible: bool) -> void:
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			node.visible = isvisible

func _set_character_animations_playing(play: bool) -> void:
	for main_char in get_tree().get_nodes_in_group("main_chars"):
		if main_char is Node:
			for child in main_char.get_children():
				if child is AnimatedSprite2D:
					var child_id := child.get_instance_id()
					if play:
						if _saved_animation_speed.has(child_id):
							child.speed_scale = _saved_animation_speed[child_id]
							_saved_animation_speed.erase(child_id)
						elif child.speed_scale == 0.0:
							child.speed_scale = 1.0
					else:
						if child.is_playing():
							_saved_animation_speed[child_id] = child.speed_scale
						child.speed_scale = 0.0

func _update_mouse_tile_ui() -> void:
	if not floorz:
		return

	var mouse_world := get_global_mouse_position()
	var cell := floorz.local_to_map(floorz.to_local(mouse_world))
	var center := floorz.to_global(floorz.map_to_local(cell))

	if fps_label and fps_label.has_method("set_hover_cell_text"):
		var lines := ["Tile: (%d, %d)" % [cell.x, cell.y]]
		if steering and steering.has_method("get_agents_in_map_cell"):
			var agents: Array = steering.get_agents_in_map_cell(cell)
			for a in agents:
				var id: int = a.get("id", -1)
				var dir: int = a.get("dir_code", -1)
				var moving: bool = a.get("is_moving", false)
				var vel_len: float = a.get("velocity_len", 0.0)
				var anim: String
				if moving:
					match dir:
						0: anim = "Walk_E"
						1: anim = "Walk_W"
						2: anim = "Walk_S"
						3: anim = "Walk_N"
						_: anim = "Walk_S"
				else:
					match dir:
						0: anim = "Idle_E"
						1: anim = "Idle_W"
						2: anim = "Idle_S"
						3: anim = "Idle_N"
						_: anim = "Idle_S"
				lines.append("Agent %d : dir %d, moving=%s, vel=%.2f, anim=%s" % [id, dir, moving, vel_len, anim])
		fps_label.call("set_hover_cell_text", "\n".join(lines))

	if mouse_outline:
		var tile_size := floorz.tile_set.get_tile_size()
		var half := Vector2(tile_size.x * 0.5, tile_size.y * 0.5)
		mouse_outline.points = [
			Vector2(-half.x, -half.y),
			Vector2(half.x, -half.y),
			Vector2(half.x, half.y),
			Vector2(-half.x, half.y)
		]
		mouse_outline.global_position = center
		mouse_outline.visible = true

func _zoom_towards_mouse(amount: float) -> void:
	var mouse_screen: Vector2 = get_viewport().get_mouse_position()

	var xform_before: Transform2D = get_viewport().get_canvas_transform()
	var world_before: Vector2 = xform_before.affine_inverse() * mouse_screen

	var old_zoom: Vector2 = camera.zoom
	var new_zoom: Vector2 = Vector2(
		clamp(old_zoom.x + amount, min_zoom, max_zoom),
		clamp(old_zoom.y + amount, min_zoom, max_zoom)
	)
	camera.zoom = new_zoom

	var xform_after: Transform2D = get_viewport().get_canvas_transform()
	var world_after: Vector2 = xform_after.affine_inverse() * mouse_screen

	camera.position += world_before - world_after








func _preview_selection(rect: Rect2) -> void:
	_clear_preview()
	var xform = get_viewport().get_canvas_transform()
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var screen_pos: Vector2 = xform * node.global_position
			if rect.has_point(screen_pos):
				if node.has_method("set_previewed"):
					node.set_previewed(true)
				else:
					node.modulate = Color(1.2, 1.2, 1.2, 1)
				preview_units.append(node)

func _clear_preview() -> void:
	for unit in preview_units:
		if unit.has_method("set_previewed"):
			unit.set_previewed(false)
		else:
			unit.modulate = Color(1, 1, 1, 1)
	preview_units.clear()

func _process_selection(rect: Rect2) -> void:
	if rect.size.x < 3 and rect.size.y < 3:
		return

	agent_manager.cleanup_groups()
	current_group = agent_manager.create_group()
	selected_units.clear()

	var xform = get_viewport().get_canvas_transform()
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var screen_pos: Vector2 = xform * node.global_position
			if rect.has_point(screen_pos):
				_select_unit(node)
				agent_manager.assign_agent(node, current_group)

	agent_manager.set_current_selected_group(current_group)

func _select_unit(unit: Node2D) -> void:
	if unit not in selected_units:
		selected_units.append(unit)
		if unit.has_method("set_selected"):
			unit.set_selected(true)
		else:
			unit.modulate = Color(0.8, 1.5, 0.8, 1.0)

func _clear_selection() -> void:
	for unit in selected_units:
		if unit.has_method("set_selected"):
			unit.set_selected(false)
		else:
			unit.modulate = Color(1, 1, 1, 1)
	selected_units.clear()

func _on_click_set_goal() -> void:
	if current_group < 0:
		return
	agent_manager.mark_group_has_order(current_group)
	var mouse_pos := get_global_mouse_position()
	var local_pos := floorz.to_local(mouse_pos)
	var cell := floorz.local_to_map(local_pos)
	var center := floorz.to_global(floorz.map_to_local(cell))
	marker.global_position = center
	marker.visible = false
	if flow and flow.has_method("rebuild_async"):
		flow.assign_flow_to_group(current_group, center)
		current_flow = flow

func _on_key_spawn_chars() -> void:
	var mouse_pos := get_global_mouse_position()
	_spawn_mainchar(mouse_pos)

func _on_key_spawn_chars_massive(grappe: int) -> void:
	var mouse_pos := get_global_mouse_position()
	for i in range(grappe):
		_spawn_mainchar(mouse_pos)

func _spawn_mainchar(pos: Vector2) -> void:
	if current_group < 1:
		current_group = agent_manager.create_group()
	var target_cell := floorz.local_to_map(floorz.to_local(pos))
	var occupied: Array[Vector2i] = []
	for node in get_tree().get_nodes_in_group("main_chars"):
		occupied.append(floorz.local_to_map(floorz.to_local(node.global_position)))
	var free_cell := _find_free_cell_near(target_cell, occupied)
	var free_pos := floorz.to_global(floorz.map_to_local(free_cell))
	var agent := preload("res://sprites/character/character.tscn").instantiate()
	get_parent().add_child(agent)
	agent.global_position = free_pos
	agent.z_index = int(free_pos.y)
	agent.add_to_group("main_chars")
	var nav_id = agent_manager.spawn_agent(agent, 0)
	agent.nav_id = nav_id

func _find_free_cell_near(start_cell: Vector2i, occupied: Array[Vector2i], max_radius: int = 6) -> Vector2i:
	if start_cell not in occupied and _is_walkable(start_cell):
		return start_cell
	for r in range(1, max_radius + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var c := start_cell + Vector2i(dx, dy)
				if c not in occupied and _is_walkable(c):
					return c
	return start_cell

func _is_walkable(cell: Vector2i) -> bool:
	var has_floor := floorz.get_cell_tile_data(cell) != null
	var has_wall := wallz and wallz.get_cell_tile_data(cell) != null
	return has_floor and not has_wall

func _on_key_trig_bomb() -> void:
	var mouse_pos := get_global_mouse_position()
	print("bomb!", mouse_pos, "intensity",explosion_intensity)
	if steering and steering.has_method("apply_explosion"):
		steering.apply_explosion(mouse_pos, explosion_radius, explosion_intensity, explosion_friction)
	_spawn_explosion_effect(mouse_pos)
	_spawn_blood_spatter(mouse_pos)

func _on_key_trig_blood() -> void:
	var mouse_pos := get_global_mouse_position()
	_spawn_blood_spatter(mouse_pos)

func _spawn_explosion_effect(bposition: Vector2) -> void:
	var circle = EXPLOSION_DEBUG_SCENE.instantiate()
	get_tree().current_scene.add_child(circle)
	circle.global_position = bposition
	circle.z_index = 999
	circle.visible = true
	var timer = get_tree().create_timer(explosion_debug_duration)
	await timer.timeout
	var mscale = explosion_radius / 16
	circle.scale = Vector2(mscale, mscale)
	if circle.is_inside_tree():
		circle.queue_free()

func _initialize_blood_canvas() -> void:
	if not floorz or not blood_layer or not blood_texture_rect:
		return
	var used := floorz.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return
	var tile_set := floorz.tile_set
	if not tile_set:
		return
	var tile_dimensions := tile_set.get_tile_size()
	var tile_size: Vector2 = Vector2(max(tile_dimensions.x, 1), max(tile_dimensions.y, 1))
	var used_size: Vector2 = Vector2(used.size.x, used.size.y)
	var map_size: Vector2 = used_size * tile_size
	var width: int = max(1, int(ceil(map_size.x)))
	var height: int = max(1, int(ceil(map_size.y)))
	if width <= 0 or height <= 0:
		return
	blood_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	if blood_image.is_empty():
		push_warning("Blood canvas image is empty, skipping init")
		return
	blood_image.fill(Color(0, 0, 0, 0))
	blood_image_texture = ImageTexture.new()
	blood_image_texture.create_from_image(blood_image)
	blood_texture_rect.texture = blood_image_texture
	blood_texture_rect.size = Vector2(width, height)
	blood_texture_rect.position = Vector2.ZERO
	blood_texture_rect.expand = true
	var top_left_local := floorz.map_to_local(used.position)
	var top_left_global := floorz.to_global(top_left_local)
	blood_layer.position = top_left_global

func _spawn_blood_spatter(bposition: Vector2) -> void:
	if not blood_image or not blood_image_texture:
		return
	var width := blood_image.get_width()
	var height := blood_image.get_height()
	if width <= 0 or height <= 0:
		return
	var local_pos := blood_layer.to_local(bposition)
	var center := Vector2i(int(round(local_pos.x)), int(round(local_pos.y)))
	blood_image.lock()
	var dots := 0
	while dots < BLOOD_DOTS:
		var offset := Vector2i(rng.randi_range(-BLOOD_RADIUS, BLOOD_RADIUS), rng.randi_range(-BLOOD_RADIUS, BLOOD_RADIUS))
		if Vector2(offset).length() > BLOOD_RADIUS:
			dots += 1
			continue
		var sample := center + offset
		if sample.x < 0 or sample.y < 0 or sample.x >= width or sample.y >= height:
			dots += 1
			continue
		var color := BLOOD_COLORS[rng.randi_range(0, BLOOD_COLORS.size() - 1)]
		var alpha := rng.randf_range(0.3, 0.85)
		var target := Color(color.r, color.g, color.b, alpha)
		var existing := blood_image.get_pixel(sample.x, sample.y)
		var blended: Color = existing.lerp(target, clamp(target.a, 0.0, 1.0))
		blood_image.set_pixel(sample.x, sample.y, blended)
		dots += 1
	blood_image.unlock()
	blood_image_texture.set_data(blood_image)
