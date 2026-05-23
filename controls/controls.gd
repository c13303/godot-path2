extends Node2D

const CONTROL_MODE_MANUAL: int = 1

@onready var floorz: TileMapLayer = $"../Map/MonTilemap/floor"
@onready var wallz: TileMapLayer = $"../Map/MonTilemap/wallz"
@onready var flow: Node = $"../CPP/FlowFieldNative"
@onready var steering: Node = $"../CPP/SteeringSystemNative"
@onready var agent_manager: Node = $"../CPP/AgentManagerNative"
@onready var ui_layer: CanvasLayer = $"../UI/CanvasLayer"
@onready var fps_label: Label = $"../UI/CanvasLayer/Label"
@onready var pause_overlay: PauseOverlay = $"../UI/CanvasLayer/PauseOverlay"

@onready var camera_controller: CameraController = $CameraController
@onready var selection_controller: SelectionController = $SelectionController
@onready var spawn_controller: SpawnController = $SpawnController
@onready var fx_controller: FXController = $FXController
@onready var tile_hover_info: TileHoverInfo = $TileHoverInfo



@onready var marker: Node2D = preload("res://UI_elements/green_circle.tscn").instantiate()

@export var camera: Camera2D
@export var speed: float = 400.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0
@export var lock_mouse_to_view: bool = true
@export var scroll_margin_pixel: float = 100.0

var global_config_node: Node = null
var current_flow: Node = null
var _paused: bool = false
var _mouse_was_locked_before_pause: bool = false
var player_nav_id: int = -1
var _reported_missing_manual_api: bool = false

func _ready() -> void:
	add_child(marker)
	marker.visible = false

	if not ui_layer:
		var canvas: CanvasLayer = CanvasLayer.new()
		canvas.layer = 100
		add_child(canvas)
		ui_layer = canvas

	camera_controller.setup(
		camera,
		speed,
		zoom_speed,
		min_zoom,
		max_zoom,
		scroll_margin_pixel,
		lock_mouse_to_view
	)

	selection_controller.setup(ui_layer, agent_manager)
	spawn_controller.setup(floorz, wallz, agent_manager, get_parent(), steering)
	fx_controller.setup(steering)
	tile_hover_info.setup(floorz, steering, fps_label, flow)

	var scene: Node = get_tree().get_current_scene()
	if scene:
		global_config_node = scene.get_node_or_null("GlobalConfigNative")

	call_deferred("_spawn_player")

func _input(event: InputEvent) -> void:
	selection_controller.on_input(event)

	if event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and not key_event.echo:
			if key_event.keycode == KEY_F1:
				_spawn_chars(1)
			elif key_event.keycode == KEY_F2:
				_spawn_chars(10)
			elif key_event.keycode == KEY_F3:
				_spawn_chars(50)
			elif key_event.keycode == KEY_B:
				fx_controller.trigger_bomb(get_global_mouse_position())
			elif key_event.keycode == KEY_SPACE:
				_toggle_pause()

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_on_click_set_goal()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and not _paused:
			camera_controller.handle_mouse_wheel(zoom_speed)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and not _paused:
			camera_controller.handle_mouse_wheel(-zoom_speed)

func _process(delta: float) -> void:
	_update_player_input()
	selection_controller.process(delta)
	tile_hover_info.process()
	camera_controller.process(delta, _paused)

func _player_spawn_position() -> Vector2:
	if camera:
		return camera.get_screen_center_position()
	return global_position

func _spawn_player() -> void:
	player_nav_id = spawn_controller.spawn_player(_player_spawn_position())
	if steering and steering.has_method("set_agent_control_mode") and player_nav_id >= 0:
		steering.call("set_agent_control_mode", player_nav_id, CONTROL_MODE_MANUAL)
	elif not _reported_missing_manual_api:
		_reported_missing_manual_api = true
		push_warning("SteeringSystemNative manual-control API is unavailable. Rebuild the GDExtension DLL.")
	var player := _get_player_node()
	if player:
		camera_controller.set_follow_target(player, true)

func _get_player_node() -> Node2D:
	for node in get_tree().get_nodes_in_group("player"):
		if node is Node2D:
			return node
	return null

func _update_player_input() -> void:
	if not steering or player_nav_id < 0:
		return
	if not steering.has_method("set_agent_input"):
		if not _reported_missing_manual_api:
			_reported_missing_manual_api = true
			push_warning("SteeringSystemNative.set_agent_input is unavailable. Rebuild the GDExtension DLL.")
		return

	var dir: Vector2 = Vector2.ZERO
	if not _paused:
		if _is_any_key_pressed([KEY_Z, KEY_W]):
			dir.y -= 1.0
		if _is_any_key_pressed([KEY_S]):
			dir.y += 1.0
		if _is_any_key_pressed([KEY_Q, KEY_A]):
			dir.x -= 1.0
		if _is_any_key_pressed([KEY_D]):
			dir.x += 1.0

	if dir.length_squared() > 1.0:
		dir = dir.normalized()

	steering.call("set_agent_input", player_nav_id, dir)

func _is_any_key_pressed(keys: Array[int]) -> bool:
	for key in keys:
		if Input.is_key_pressed(key) or Input.is_physical_key_pressed(key):
			return true
	return false

func _toggle_pause() -> void:
	_paused = not _paused
	if steering and steering.has_method("set_paused"):
		steering.call("set_paused", _paused)

	if _paused:
		_mouse_was_locked_before_pause = camera_controller.is_mouse_locked()
		if _mouse_was_locked_before_pause:
			camera_controller.set_mouse_locked(false)
	else:
		if lock_mouse_to_view and _mouse_was_locked_before_pause:
			camera_controller.set_mouse_locked(true)

	var hide_units: bool = _paused
	if hide_units and global_config_node and global_config_node.has_method("get_draw_claimed_path"):
		if not bool(global_config_node.call("get_draw_claimed_path")):
			hide_units = false

	_toggle_units_visible(not hide_units)
	_set_character_animations_playing(not _paused)
	if pause_overlay:
		pause_overlay.set_paused(_paused)

func _toggle_units_visible(isvisible: bool) -> void:
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var unit: Node2D = node
			unit.visible = isvisible

var _saved_animation_speed: Dictionary[int, float] = {}
func _set_character_animations_playing(play: bool) -> void:
	for main_char in get_tree().get_nodes_in_group("main_chars"):
		if main_char is Node:
			var main_node: Node = main_char
			for child in main_node.get_children():
				if child is AnimatedSprite2D:
					var sprite: AnimatedSprite2D = child
					var child_id: int = sprite.get_instance_id()
					if play:
						if _saved_animation_speed.has(child_id):
							sprite.speed_scale = _saved_animation_speed[child_id]
							_saved_animation_speed.erase(child_id)
						elif sprite.speed_scale == 0.0:
							sprite.speed_scale = 1.0
					else:
						if sprite.is_playing():
							_saved_animation_speed[child_id] = sprite.speed_scale
						sprite.speed_scale = 0.0

func _spawn_chars(count: int) -> void:
	var mouse_pos: Vector2 = get_global_mouse_position()
	var group_id: int = selection_controller.get_current_group()
	for i in range(count):
		group_id = spawn_controller.spawn_mainchar(mouse_pos, group_id)

func _on_click_set_goal() -> void:
	var group_id: int = selection_controller.get_current_group()
	if group_id < 0:
		return
	if agent_manager and agent_manager.has_method("mark_group_has_order"):
		agent_manager.call("mark_group_has_order", group_id)

	var mouse_pos: Vector2 = get_global_mouse_position()
	var local_pos: Vector2 = floorz.to_local(mouse_pos)
	var cell: Vector2i = floorz.local_to_map(local_pos)
	var center: Vector2 = floorz.to_global(floorz.map_to_local(cell))
	marker.global_position = center
	marker.visible = false

	if flow and flow.has_method("assign_flow_to_group"):
		flow.call("assign_flow_to_group", group_id, center)
		current_flow = flow
