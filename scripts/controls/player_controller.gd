extends Node2D
class_name PlayerController

const CONTROL_MODE_MANUAL: int = 1
const SMASH_CLASS_PLAYER: int = 1
const RUSH_BLOCKED_PROGRESS_EPSILON: float = 0.5

@onready var steering: Node = $"../../CPP/SteeringSystemNative"
@onready var agent_manager: Node = $"../../CPP/AgentManagerNative"
@onready var projectile_system: Node = $"../../CPP/ProjectileSystemNative"
@onready var fight_system: FightSystem = $"../../fightSystem"
@onready var game_ui: CanvasLayer = $"../../GameUI"
@onready var pause_overlay: PauseOverlay = $"../../GameUI/CanvasLayer/PauseOverlay"
@onready var watersources: WaterSources = $"../../Map/MonTilemap/watersources"

@onready var camera_controller: CameraController = $"../../Camera2D"



@export var zoom_speed: float = 0.125
@export var lock_mouse_to_view: bool = true
@export var gamepad_stick_deadzone: float = 0.2
@export var gamepad_cursor_speed: float = 900.0
@export var gamepad_trigger_threshold: float = 0.5

@export_group("Rush", "rush_")
@export var rush_duration: float = 0.1
@export var rush_speed_mult: float = 3.0
@export var rush_allow_direction: bool = false
@export_group("")

var global_config_node: Node = null
var _paused: bool = false
var _mouse_was_locked_before_pause: bool = false
var player_nav_id: int = -1
var _reported_missing_manual_api: bool = false
var _active_gamepad_device: int = -1
var _left_trigger_pressed: bool = false
var _right_trigger_pressed: bool = false
var _emulated_mouse_button_mask: int = 0
var _rush_active: bool = false
var _rush_shift_was_pressed: bool = false
var _rush_time_left: float = 0.0
var _rush_direction: Vector2 = Vector2.ZERO
var _rush_sample_position: Vector2 = Vector2.ZERO
var _last_move_direction: Vector2 = Vector2.ZERO
var _player_in_water: bool = false

func _ready() -> void:
	var scene: Node = get_tree().get_current_scene()
	if scene:
		global_config_node = scene.get_node_or_null("CPP/GlobalConfigNative")

	call_deferred("_setup_player")

func _input(event: InputEvent) -> void:
	if _startup_loading_active():
		get_viewport().set_input_as_handled()
		return

	if event is InputEventJoypadButton:
		var joy_button_event: InputEventJoypadButton = event
		_active_gamepad_device = joy_button_event.device
		if joy_button_event.button_index == JOY_BUTTON_A:
			_emulate_mouse_button(MOUSE_BUTTON_LEFT, joy_button_event.pressed)
			get_viewport().set_input_as_handled()
		elif joy_button_event.button_index == JOY_BUTTON_B:
			_emulate_mouse_button(MOUSE_BUTTON_RIGHT, joy_button_event.pressed)
			get_viewport().set_input_as_handled()
		return

	if event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == KEY_P:
			_toggle_pause()
			get_viewport().set_input_as_handled()
			return

	if event is InputEventJoypadMotion:
		var joy_motion_event: InputEventJoypadMotion = event
		_active_gamepad_device = joy_motion_event.device

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and not _paused and not _is_inventory_open():
			if _selected_item_places_tile():
				return
			var weapon_id := _selected_item_id()
			if fight_system and fight_system.is_held_weapon(weapon_id):
				if fight_system.is_gun(weapon_id):
					fight_system.reset_gun_cooldown(weapon_id)
			else:
				_try_use_equipped_item()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.ctrl_pressed and not _paused and not _is_inventory_open():
			camera_controller.handle_mouse_wheel(zoom_speed)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.ctrl_pressed and not _paused and not _is_inventory_open():
			camera_controller.handle_mouse_wheel(-zoom_speed)

func _process(delta: float) -> void:
	if _startup_loading_active():
		return

	_update_gamepad_cursor(delta)
	_update_gamepad_slot_input()
	_update_player_input(delta)
	_update_gun_fire(delta)
	_update_lance_sprite()
	camera_controller.process(delta, _paused)

func _emulate_mouse_button(button_index: MouseButton, pressed: bool) -> void:
	var button_mask: int = MOUSE_BUTTON_MASK_LEFT if button_index == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	if pressed:
		_emulated_mouse_button_mask |= button_mask
	else:
		_emulated_mouse_button_mask &= ~button_mask

	var mouse_event: InputEventMouseButton = InputEventMouseButton.new()
	var cursor_position: Vector2 = get_viewport().get_mouse_position()
	mouse_event.button_index = button_index
	mouse_event.pressed = pressed
	mouse_event.button_mask = _emulated_mouse_button_mask
	mouse_event.position = cursor_position
	mouse_event.global_position = cursor_position
	Input.parse_input_event(mouse_event)

func _update_gamepad_cursor(delta: float) -> void:
	var stick: Vector2 = _gamepad_stick_vector(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y)
	if stick == Vector2.ZERO:
		return
	# Work entirely in window-pixel space. The viewport uses canvas_items "expand"
	# stretch, so get_viewport().get_mouse_position() (stretched/base coords) and
	# Input.warp_mouse() (window pixels) live in different spaces; mixing them makes
	# the cursor contract into the top-left corner. DisplayServer-relative coords
	# match warp_mouse, giving a stable read/write loop.
	var window_size: Vector2 = Vector2(DisplayServer.window_get_size())
	var max_position: Vector2 = (window_size - Vector2.ONE).max(Vector2.ZERO)
	var mouse_window: Vector2 = Vector2(DisplayServer.mouse_get_position()) - Vector2(get_window().position)
	var cursor_position: Vector2 = mouse_window + stick * gamepad_cursor_speed * delta
	cursor_position = cursor_position.clamp(Vector2.ZERO, max_position)
	Input.warp_mouse(cursor_position)

func _update_gamepad_slot_input() -> void:
	if _active_gamepad_device < 0:
		_left_trigger_pressed = false
		_right_trigger_pressed = false
		return

	var left_pressed: bool = Input.get_joy_axis(_active_gamepad_device, JOY_AXIS_TRIGGER_LEFT) >= gamepad_trigger_threshold
	var right_pressed: bool = Input.get_joy_axis(_active_gamepad_device, JOY_AXIS_TRIGGER_RIGHT) >= gamepad_trigger_threshold
	if left_pressed and not _left_trigger_pressed and game_ui and game_ui.has_method("step_selected_quick_slot"):
		game_ui.call("step_selected_quick_slot", -1)
	if right_pressed and not _right_trigger_pressed and game_ui and game_ui.has_method("step_selected_quick_slot"):
		game_ui.call("step_selected_quick_slot", 1)
	_left_trigger_pressed = left_pressed
	_right_trigger_pressed = right_pressed

func _gamepad_stick_vector(x_axis: JoyAxis, y_axis: JoyAxis) -> Vector2:
	if _active_gamepad_device < 0:
		return Vector2.ZERO
	var stick: Vector2 = Vector2(
		Input.get_joy_axis(_active_gamepad_device, x_axis),
		Input.get_joy_axis(_active_gamepad_device, y_axis)
	)
	var magnitude: float = stick.length()
	if magnitude <= gamepad_stick_deadzone:
		return Vector2.ZERO
	var scaled_magnitude: float = clampf(
		(magnitude - gamepad_stick_deadzone) / maxf(1.0 - gamepad_stick_deadzone, 0.001),
		0.0,
		1.0
	)
	return stick.normalized() * scaled_magnitude

func _update_gun_fire(delta: float) -> void:
	if not fight_system:
		return
	var player: Node2D = _get_player_node()
	if not player:
		return
	var origin: Vector2 = _weapon_origin(player)
	var direction: Vector2 = get_global_mouse_position() - origin
	var weapon_id: String = ""
	var trigger_allowed: bool = not _paused and not _is_inventory_open()
	trigger_allowed = trigger_allowed and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	trigger_allowed = trigger_allowed and get_viewport().gui_get_hovered_control() == null
	if trigger_allowed:
		var selected_id: String = _selected_item_id()
		if not _selected_item_disabled_for_placement(selected_id) and direction.length_squared() >= 0.000001:
			weapon_id = selected_id
	var player_velocity: Vector2 = _agent_velocity(player_nav_id)
	fight_system.process_held_weapon(weapon_id, origin, direction, player_nav_id, _weapon_origin_offset(player), delta, player_velocity)

func _setup_player() -> void:
	var player: Node2D = _get_player_node()
	if not player:
		push_warning("PlayerController: Player node not found.")
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
		var player_world_radius: float = _agent_world_radius()
		var sprite: Sprite2D = player.get_node_or_null("Sprite2D") as Sprite2D
		var fight_half_size: Vector2 = Vector2(32.0, 32.0)
		var fight_offset_y: float = -32.0
		if sprite and sprite.texture:
			var sprite_size: Vector2 = sprite.texture.get_size() * sprite.scale.abs()
			fight_half_size = sprite_size * 0.5
			fight_offset_y = sprite.position.y
		var profile: Dictionary = {
			"crowd_push_strength": 2.0,
			"world_radius": player_world_radius,
			"foot_offset_y": -player_world_radius,
			"fight_offset_y": fight_offset_y,
			"fight_half_w": fight_half_size.x,
			"fight_half_h": fight_half_size.y,
			"smash_class": SMASH_CLASS_PLAYER,
		}
		# Player max_speed > 0 overrides the global agent_max_speed; 0 means inherit.
		# We resolve the effective speed and multiply it explicitly so the player
		# scales with the CPP > Debug speed_multiplier without double-counting the
		# already-multiplied global agent_max_speed.
		var player_max_speed: float = float(player.get("max_speed"))
		var base_speed: float = player_max_speed if player_max_speed > 0.0 else _base_agent_max_speed()
		if base_speed > 0.0:
			_player_in_water = _is_player_in_water(player)
			profile["max_speed"] = _player_profile_speed(player, false)
		steering.call("set_agent_profile", player_nav_id, profile)

	if player:
		camera_controller.set_follow_target(player, true)

func _agent_world_radius() -> float:
	if global_config_node and global_config_node.has_method("get_agent_world_radius"):
		return float(global_config_node.call("get_agent_world_radius"))
	return 12.0

## CPP > Debug speed multiplier (1.0 if the debug node is unavailable).
func _speed_multiplier() -> float:
	var scene: Node = get_tree().get_current_scene()
	if scene:
		var debug_node: Node = scene.get_node_or_null("CPP")
		if debug_node and debug_node.has_method("get_speed_multiplier"):
			return float(debug_node.call("get_speed_multiplier"))
	return 1.0

## Unmultiplied global agent_max_speed. The native global already holds
## base * multiplier (the debug node applies it first), so divide it back out.
func _base_agent_max_speed() -> float:
	if global_config_node and global_config_node.has_method("get_agent_max_speed"):
		return float(global_config_node.call("get_agent_max_speed")) / _speed_multiplier()
	return 0.0

func _startup_loading_active() -> bool:
	if game_ui and game_ui.has_method("is_startup_loading"):
		return bool(game_ui.call("is_startup_loading"))
	return false

func _get_player_node() -> Node2D:
	var parent := get_parent()
	if parent is Node2D:
		return parent
	# Fallback for legacy placement (not nested under Player).
	for node in get_tree().get_nodes_in_group("player"):
		if node is Node2D:
			return node
	return null

func _weapon_origin(player: Node2D) -> Vector2:
	if player.has_method("get_weapon_origin"):
		return player.call("get_weapon_origin")
	return player.global_position

# Local offset of the weapon origin relative to the player node, used so AOE
# zones keep tracking the offset point (not the agent center) while alive.
func _weapon_origin_offset(player: Node2D) -> Vector2:
	if "weapon_origin" in player:
		return player.get("weapon_origin")
	return Vector2.ZERO

func _update_lance_sprite() -> void:
	var player: Node2D = _get_player_node()
	if not player or not fight_system:
		return
	var lance: Sprite2D = player.get_node_or_null("lance") as Sprite2D
	if not lance:
		return

	var weapon_id: String = _selected_item_id()
	if not _is_lance_weapon(weapon_id):
		lance.visible = false
		return

	var origin: Vector2 = _weapon_origin(player)
	var direction: Vector2 = get_global_mouse_position() - origin
	if direction.length_squared() <= 0.000001:
		lance.visible = false
		return

	var facing: Vector2 = direction.normalized()
	var throw_offset: float = float(fight_system.call("get_spray_weapon_throw_offset", weapon_id))
	var local_origin: Vector2 = _weapon_origin_offset(player)
	lance.position = local_origin + facing * throw_offset
	lance.rotation = facing.angle() + PI * 0.5
	lance.visible = true

func _is_lance_weapon(weapon_id: String) -> bool:
	if weapon_id == "" or not fight_system:
		return false
	if fight_system.is_gun(weapon_id):
		return false
	if not fight_system.is_held_weapon(weapon_id):
		return false
	return fight_system.has_method("get_spray_weapon_throw_offset")

func _agent_velocity(agent_id: int) -> Vector2:
	if steering and agent_id >= 0 and steering.has_method("get_agent_velocity"):
		return steering.call("get_agent_velocity", agent_id) as Vector2
	return Vector2.ZERO

func _update_player_input(delta: float) -> void:
	if not steering or player_nav_id < 0:
		return
	if not steering.has_method("set_agent_input"):
		if not _reported_missing_manual_api:
			_reported_missing_manual_api = true
			push_warning("SteeringSystemNative.set_agent_input is unavailable. Rebuild the GDExtension DLL.")
		return

	var dir: Vector2 = Vector2.ZERO
	if not _paused:
		if _is_any_key_pressed([KEY_Z, KEY_W, KEY_UP]):
			dir.y -= 1.0
		if _is_any_key_pressed([KEY_S, KEY_DOWN]):
			dir.y += 1.0
		if _is_any_key_pressed([KEY_Q, KEY_A, KEY_LEFT]):
			dir.x -= 1.0
		if _is_any_key_pressed([KEY_D, KEY_RIGHT]):
			dir.x += 1.0
		dir += _gamepad_stick_vector(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y)

	if dir.length_squared() > 1.0:
		dir = dir.normalized()

	var shift_pressed: bool = _is_any_key_pressed([KEY_SHIFT])
	var rush_started: bool = false
	if _paused:
		_stop_rush()
	elif shift_pressed and not _rush_shift_was_pressed and not _rush_active:
		var start_direction: Vector2 = dir if dir.length_squared() > 0.0 else _last_move_direction
		if start_direction.length_squared() > 0.0:
			_start_rush(start_direction.normalized())
			rush_started = true
	_rush_shift_was_pressed = shift_pressed

	if _rush_active and not rush_started:
		var player: Node2D = _get_player_node()
		if not player or _rush_is_blocked(player.global_position):
			_stop_rush()
		else:
			_rush_time_left = maxf(_rush_time_left - delta, 0.0)
			if _rush_time_left <= 0.0:
				_stop_rush()

	if _rush_active:
		if rush_allow_direction and dir.length_squared() > 0.0:
			_rush_direction = dir.normalized()
		dir = _rush_direction
		var rush_player: Node2D = _get_player_node()
		if rush_player:
			_rush_sample_position = rush_player.global_position
	else:
		if dir.length_squared() > 0.0:
			_last_move_direction = dir.normalized()

	_update_water_speed_state()
	steering.call("set_agent_input", player_nav_id, dir)

func _start_rush(direction: Vector2) -> void:
	_rush_active = true
	_rush_time_left = maxf(rush_duration, 0.0)
	_rush_direction = direction
	var player: Node2D = _get_player_node()
	if player:
		_rush_sample_position = player.global_position
	_set_rush_speed(true)

func _stop_rush() -> void:
	if not _rush_active:
		return
	_rush_active = false
	_rush_time_left = 0.0
	_set_rush_speed(false)

func _rush_is_blocked(current_position: Vector2) -> bool:
	var displacement: Vector2 = current_position - _rush_sample_position
	var forward_progress: float = displacement.dot(_rush_direction)
	return forward_progress <= RUSH_BLOCKED_PROGRESS_EPSILON

func _set_rush_speed(enabled: bool) -> void:
	if not steering or player_nav_id < 0 or not steering.has_method("set_agent_profile"):
		return
	var player: Node2D = _get_player_node()
	if not player:
		return
	var speed: float = _player_profile_speed(player, enabled)
	if speed <= 0.0:
		return
	var profile: Dictionary = {"max_speed": speed}
	steering.call("set_agent_profile", player_nav_id, profile)

func _update_water_speed_state() -> void:
	var player: Node2D = _get_player_node()
	if not player:
		return
	var in_water: bool = _is_player_in_water(player)
	if in_water == _player_in_water:
		return
	_player_in_water = in_water
	_set_rush_speed(_rush_active)

func _is_player_in_water(player: Node2D) -> bool:
	return watersources != null and watersources.has_water_at_foot_position(player.global_position)

func _player_profile_speed(player: Node2D, rush_enabled: bool) -> float:
	var player_max_speed: float = float(player.get("max_speed"))
	var base_speed: float = player_max_speed if player_max_speed > 0.0 else _base_agent_max_speed()
	if base_speed <= 0.0:
		return 0.0
	var rush_multiplier: float = maxf(rush_speed_mult, 0.0) if rush_enabled else 1.0
	var water_multiplier: float = _water_speed_multiplier() if _is_player_in_water(player) else 1.0
	return base_speed * _speed_multiplier() * rush_multiplier * water_multiplier

func _water_speed_multiplier() -> float:
	if watersources == null:
		return 1.0
	return clampf(watersources.player_slowdown, 0.01, 1.0)

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

func _selected_item_disabled_for_placement(item_id: String) -> bool:
	return game_ui and game_ui.has_method("is_item_disabled_for_placement") and bool(game_ui.call("is_item_disabled_for_placement", item_id))

func _try_use_equipped_item() -> void:
	if get_viewport().gui_get_hovered_control() != null:
		return
	var weapon_id: String = _selected_item_id()
	if _selected_item_disabled_for_placement(weapon_id):
		return
	if weapon_id == "":
		return
	var player := _get_player_node()
	if not player or not fight_system:
		return
	var origin := _weapon_origin(player)
	var direction := get_global_mouse_position() - origin
	if bool(fight_system.use_weapon(weapon_id, origin, direction, player_nav_id, _weapon_origin_offset(player))):
		get_viewport().set_input_as_handled()

func _toggle_pause() -> void:
	_paused = not _paused
	if steering and steering.has_method("set_paused"):
		steering.call("set_paused", _paused)
	if projectile_system and projectile_system.has_method("set_paused"):
		projectile_system.call("set_paused", _paused)
	if fight_system and fight_system.has_method("set_paused"):
		fight_system.call("set_paused", _paused)
	var building_manager: Node = get_node_or_null("../../Map/BuildingManager")
	if building_manager and building_manager.has_method("set_paused"):
		building_manager.call("set_paused", _paused)
	_toggle_group_paused(&"monsters", _paused)

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

func _toggle_group_paused(group_name: StringName, paused: bool) -> void:
	for node: Node in get_tree().get_nodes_in_group(group_name):
		if node.has_method("set_paused"):
			node.call("set_paused", paused)
