extends Node2D

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
	spawn_controller.setup(floorz, wallz, agent_manager, get_parent())
	fx_controller.setup(steering)
	tile_hover_info.setup(floorz, steering, fps_label, flow)

	var scene: Node = get_tree().get_current_scene()
	if scene:
		global_config_node = scene.get_node_or_null("GlobalConfigNative")

func _input(event: InputEvent) -> void:
	selection_controller.on_input(event)

	if event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and not key_event.echo:
			if key_event.keycode == KEY_A:
				_spawn_chars(1)
			elif key_event.keycode == KEY_Z:
				_spawn_chars(10)
			elif key_event.keycode == KEY_E:
				_spawn_chars(50)
			elif key_event.keycode == KEY_B:
				fx_controller.trigger_bomb(get_global_mouse_position())
			elif key_event.keycode == KEY_SPACE:
				_toggle_pause()
			elif key_event.keycode == KEY_ESCAPE:
				camera_controller.set_mouse_locked(false)
			elif key_event.keycode == KEY_TAB:
				camera_controller.set_mouse_locked(true)

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_on_click_set_goal()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_controller.handle_mouse_wheel(zoom_speed)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_controller.handle_mouse_wheel(-zoom_speed)

func _process(delta: float) -> void:
	selection_controller.process(delta)
	tile_hover_info.process()
	camera_controller.process(delta, _paused)

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
