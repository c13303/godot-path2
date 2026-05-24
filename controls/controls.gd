extends Node2D

const CONTROL_MODE_MANUAL: int = 1
const SMASH_CLASS_PLAYER: int = 1

@onready var floorz: TileMapLayer = $"../Map/MonTilemap/floor"
@onready var wallz: TileMapLayer = $"../Map/MonTilemap/wallz"
@onready var flow: Node = $"../CPP/FlowFieldNative"
@onready var steering: Node = $"../CPP/SteeringSystemNative"
@onready var agent_manager: Node = $"../CPP/AgentManagerNative"
@onready var fight_system: FightSystem = $"../fightSystem"
@onready var ui_layer: CanvasLayer = $"../UI/CanvasLayer"
@onready var game_ui: CanvasLayer = $"../GameUI"
@onready var fps_label: Label = $"../UI/CanvasLayer/Label"
@onready var pause_overlay: PauseOverlay = $"../UI/CanvasLayer/PauseOverlay"

@onready var camera_controller: CameraController = $CameraController
@onready var selection_controller: SelectionController = $SelectionController
@onready var spawn_controller: SpawnController = $SpawnController
@onready var tile_hover_info: TileHoverInfo = get_node_or_null("TileHoverInfo") as TileHoverInfo



@onready var marker: Node2D = preload("res://UI_elements/green_circle.tscn").instantiate()

@export var camera: Camera2D
@export var speed: float = 400.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0
@export var lock_mouse_to_view: bool = true
@export var scroll_margin_pixel: float = 100.0
@export var enable_mouse_unit_commands: bool = false

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
	spawn_controller.setup(floorz, wallz, agent_manager, get_parent())
	if tile_hover_info:
		tile_hover_info.setup(floorz, steering, fps_label, flow)

	var scene: Node = get_tree().get_current_scene()
	if scene:
		global_config_node = scene.get_node_or_null("GlobalConfigNative")

	call_deferred("_setup_player")

func _input(event: InputEvent) -> void:
	if enable_mouse_unit_commands:
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

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and not _paused and not _is_inventory_open():
			if _selected_item_places_tile():
				return
			var weapon_id := _selected_item_id()
			if fight_system and fight_system.is_gun(weapon_id):
				fight_system.reset_gun_cooldown(weapon_id)
			else:
				_try_use_equipped_item()
		elif enable_mouse_unit_commands and mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_on_click_set_goal()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.ctrl_pressed and not _paused and not _is_inventory_open():
			camera_controller.handle_mouse_wheel(zoom_speed)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.ctrl_pressed and not _paused and not _is_inventory_open():
			camera_controller.handle_mouse_wheel(-zoom_speed)

func _process(delta: float) -> void:
	_update_player_input()
	_update_gun_fire(delta)
	if enable_mouse_unit_commands:
		selection_controller.process(delta)
	if tile_hover_info:
		tile_hover_info.process()
	camera_controller.process(delta, _paused)

func _update_gun_fire(delta: float) -> void:
	if _paused or _is_inventory_open():
		return
	if not fight_system:
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	if get_viewport().gui_get_hovered_control() != null:
		return
	var weapon_id := _selected_item_id()
	if weapon_id == "" or not fight_system.is_gun(weapon_id):
		return
	var player := _get_player_node()
	if not player:
		return
	var direction := get_global_mouse_position() - player.global_position
	if direction.length_squared() < 0.000001:
		return
	fight_system.fire_gun_held(weapon_id, player.global_position, direction, player_nav_id, delta)

func _setup_player() -> void:
	var player := _get_player_node()
	if not player:
		push_warning("Controls: Player node not found.")
		return

	if agent_manager and agent_manager.has_method("spawn_agent"):
		player_nav_id = int(agent_manager.call("spawn_agent", player, 0))
		player.set("nav_id", player_nav_id)

	if steering and steering.has_method("set_agent_control_mode") and player_nav_id >= 0:
		steering.call("set_agent_control_mode", player_nav_id, CONTROL_MODE_MANUAL)
	elif not _reported_missing_manual_api:
		_reported_missing_manual_api = true
		push_warning("SteeringSystemNative manual-control API is unavailable. Rebuild the GDExtension DLL.")

	if steering and steering.has_method("set_agent_manual_motion") and player_nav_id >= 0:
		steering.call("set_agent_manual_motion", player_nav_id, player.get("acceleration"), player.get("deceleration"))

	if steering and steering.has_method("set_agent_profile") and player_nav_id >= 0:
		var player_world_radius := 16.0
		var sprite := player.get_node_or_null("Sprite2D") as Sprite2D
		var fight_half_size := Vector2(32.0, 32.0)
		var fight_offset_y := -32.0
		if sprite and sprite.texture:
			var sprite_size: Vector2 = sprite.texture.get_size() * sprite.scale.abs()
			fight_half_size = sprite_size * 0.5
			fight_offset_y = sprite.position.y
		steering.call("set_agent_profile", player_nav_id, {
			"crowd_push_strength": 2.0,
			"world_radius": player_world_radius,
			"foot_offset_y": -player_world_radius,
			"fight_offset_y": fight_offset_y,
			"fight_half_w": fight_half_size.x,
			"fight_half_h": fight_half_size.y,
			"smash_class": SMASH_CLASS_PLAYER,
		})

	if player:
		camera_controller.set_follow_target(player, true)

func _get_player_node() -> Node2D:
	var scene := get_tree().get_current_scene()
	if scene:
		var root_player := scene.get_node_or_null("Player")
		if root_player is Node2D:
			return root_player
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

func _is_inventory_open() -> bool:
	return game_ui and game_ui.has_method("is_inventory_open") and bool(game_ui.call("is_inventory_open"))

func _selected_item_id() -> String:
	if not game_ui or not game_ui.has_method("get_selected_quick_item_id"):
		return ""
	return String(game_ui.call("get_selected_quick_item_id"))

func _selected_item_places_tile() -> bool:
	return game_ui and game_ui.has_method("selected_quick_item_places_tile") and bool(game_ui.call("selected_quick_item_places_tile"))

func _try_use_equipped_item() -> void:
	if get_viewport().gui_get_hovered_control() != null:
		return
	var weapon_id := _selected_item_id()
	if weapon_id == "":
		return
	var player := _get_player_node()
	if not player or not fight_system:
		return
	var direction := get_global_mouse_position() - player.global_position
	if bool(fight_system.use_weapon(weapon_id, player.global_position, direction, player_nav_id)):
		get_viewport().set_input_as_handled()

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

	_toggle_units_visible(not _paused)
	if pause_overlay:
		pause_overlay.set_paused(_paused)

func _toggle_units_visible(isvisible: bool) -> void:
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var unit: Node2D = node
			unit.visible = isvisible

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
