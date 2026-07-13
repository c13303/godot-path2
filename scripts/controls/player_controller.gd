extends Node2D
class_name PlayerController

const CONTROL_MODE_MANUAL: int = 1
const SMASH_CLASS_PLAYER: int = 1
const RUSH_BLOCKED_PROGRESS_EPSILON: float = 0.5
const INPUT_MODE_PAD: String = "pad"
const INPUT_MODE_KMOUSE: String = "kmouse"
const DEFAULT_LANCE_THROW_OFFSET: float = 8.0
const LANCE_VISUAL_ANCHOR_OFFSET: Vector2 = Vector2(0.0, -2.0)

@onready var steering: Node = $"../../CPP/SteeringSystemNative"
@onready var agent_manager: Node = $"../../CPP/AgentManagerNative"
@onready var projectile_system: Node = $"../../CPP/ProjectileSystemNative"
@onready var fight_system: FightSystem = $"../../fightSystem"
@onready var game_ui: CanvasLayer = $"../../GameUI"
@onready var toolbuild: Control = $"../../GameUI/Toolbuild"
@onready var build_system: Node = $"../../Map/BuildSystem"
@onready var pause_overlay: PauseOverlay = $"../../GameUI/CanvasLayer/PauseOverlay"
@onready var watersources: WaterSources = $"../../Map/MonTilemap/watersources"
@onready var fences: TileMapLayer = $"../../Map/MonTilemap/fences"

@onready var camera_controller: CameraController = $"../../Camera2D"
@onready var smoke_trail: SmokeTrail = $"../../SmokeTrail"



@export var zoom_speed: float = 0.125
@export var lock_mouse_to_view: bool = true
@export var gamepad_stick_deadzone: float = 0.2
@export var gamepad_cursor_speed: float = 900.0
@export var gamepad_trigger_threshold: float = 0.5
@export var gamepad_cursor_initial_repeat_delay: float = 0.20
@export var gamepad_cursor_repeat_interval: float = 0.075

@export_group("Rush", "rush_")
@export var rush_duration: float = 0.1
@export var rush_speed_mult: float = 3.0
@export var rush_allow_direction: bool = false
## Distance the player must travel between smoke trail puffs while rushing.
@export var rush_trail_spacing: float = 18.0
@export_group("")

var global_config_node: Node = null
var _paused: bool = false
var _pause_hold_count: int = 0
var _cutscene_input_locked: bool = false
var _mouse_was_locked_before_pause: bool = false
var player_nav_id: int = -1
var _reported_missing_manual_api: bool = false
var _active_gamepad_device: int = -1
var _control_mode: String = INPUT_MODE_KMOUSE
var _dpad_left_pressed: bool = false
var _dpad_right_pressed: bool = false
var _dpad_up_pressed: bool = false
var _dpad_down_pressed: bool = false
var _pad_cursor_repeat_direction: Vector2i = Vector2i.ZERO
var _pad_cursor_repeat_time: float = 0.0
# Tracks whether the pad build cursor was active last frame, so equipping the toolbuild
# (an inactive->active transition in pad mode) can snap the cursor next to the player.
var _pad_build_controls_active_prev: bool = false
var _right_stick_weapon_active: bool = false
var _rush_active: bool = false
var _rush_input_was_pressed: bool = false
var _rush_time_left: float = 0.0
var _rush_direction: Vector2 = Vector2.ZERO
var _rush_sample_position: Vector2 = Vector2.ZERO
var _trail_last_emit_pos: Vector2 = Vector2.ZERO
var _last_move_direction: Vector2 = Vector2.ZERO
var _last_lance_facing: Vector2 = Vector2.RIGHT
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
	if _cutscene_input_locked:
		return

	if event is InputEventJoypadButton:
		var joy_button_event: InputEventJoypadButton = event
		_active_gamepad_device = joy_button_event.device
		if joy_button_event.pressed:
			_set_control_mode(INPUT_MODE_PAD)
		if joy_button_event.button_index == JOY_BUTTON_START:
			if joy_button_event.pressed:
				_toggle_pause()
			get_viewport().set_input_as_handled()
		elif joy_button_event.button_index == JOY_BUTTON_A:
			if joy_button_event.pressed:
				_handle_pad_accept()
			get_viewport().set_input_as_handled()
		elif joy_button_event.button_index == JOY_BUTTON_B:
			if joy_button_event.pressed:
				_handle_pad_cancel()
			get_viewport().set_input_as_handled()
		elif joy_button_event.button_index == JOY_BUTTON_Y:
			if joy_button_event.pressed:
				# At the merchant, Y opens/closes the shop; else it rotates the build preview.
				if not _try_toggle_merchant_shop():
					_handle_pad_rotate_build()
			get_viewport().set_input_as_handled()
		elif joy_button_event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			if joy_button_event.pressed:
				_handle_pad_rotate_build()
			get_viewport().set_input_as_handled()
		return

	if event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and not key_event.echo:
			_set_control_mode(INPUT_MODE_KMOUSE)
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == KEY_P:
			_toggle_pause()
			get_viewport().set_input_as_handled()
			return
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == KEY_E:
			if _try_toggle_merchant_shop():
				get_viewport().set_input_as_handled()
				return

	if event is InputEventJoypadMotion:
		var joy_motion_event: InputEventJoypadMotion = event
		_active_gamepad_device = joy_motion_event.device
		if absf(joy_motion_event.axis_value) > gamepad_stick_deadzone:
			_set_control_mode(INPUT_MODE_PAD)

	if event is InputEventMouseMotion:
		var mouse_motion: InputEventMouseMotion = event
		if mouse_motion.relative.length_squared() > 0.0:
			_set_control_mode(INPUT_MODE_KMOUSE)

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		_set_control_mode(INPUT_MODE_KMOUSE)
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and not _paused and not _is_inventory_open():
			if _is_quickbar_active() or _in_build_mode() or _unbuild_selected():
				_clear_build_selection()
				_deactivate_quickbar()
				get_viewport().set_input_as_handled()
				return
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and not _paused and not _is_inventory_open():
			# While build quickbar menus are active, a click in the world dismisses the menu
			# without placing. The weapon menu returns to play mode and lets this same click fire.
			if _is_quickbar_active():
				if get_viewport().gui_get_hovered_control() != null:
					return
				var active_menu_kind: String = _active_quickbar_menu_kind()
				if active_menu_kind == "weapon":
					_clear_build_selection()
				_deactivate_quickbar()
				if active_menu_kind != "weapon":
					get_viewport().set_input_as_handled()
					return
			# In build preview mode, the click belongs to the build system, not the weapon.
			if _in_build_mode():
				return
			# With the unbuild tool equipped, left-click drives removal (handled by the build
			# system's input controller), so the weapon must not fire.
			if _unbuild_selected():
				return
			var weapon_id: String = _selected_item_id()
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
	if _cutscene_input_locked:
		_update_player_input(delta)
		_update_gun_fire(delta)
		_update_lance_sprite()
		return

	_update_toolbuild_equip_cursor()
	_update_pad_cursor(delta)
	_update_pad_navigation_input()
	_update_player_input(delta)
	_update_gun_fire(delta)
	_update_lance_sprite()
	camera_controller.process(delta, _paused)

func _set_control_mode(mode: String) -> void:
	if _control_mode == mode:
		return
	_control_mode = mode
	if _control_mode == INPUT_MODE_PAD:
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_deactivate_pad_build_cursor()

func get_control_mode() -> String:
	return _control_mode

## Snaps the pad build cursor to one tile right of the player the moment the toolbuild
## becomes the active build tool in pad mode (an inactive->active transition), so re-equipping
## it relocates the cursor next to the player instead of leaving it at the hidden mouse.
func _update_toolbuild_equip_cursor() -> void:
	var active: bool = _control_mode == INPUT_MODE_PAD and _build_controls_active()
	if active and not _pad_build_controls_active_prev:
		if build_system != null and build_system.has_method("pad_place_cursor_right_of_player"):
			build_system.call("pad_place_cursor_right_of_player")
	_pad_build_controls_active_prev = active

func _update_pad_cursor(delta: float) -> void:
	if _control_mode != INPUT_MODE_PAD or not _build_controls_active():
		_reset_pad_cursor_repeat()
		_deactivate_pad_build_cursor()
		return
	var stick: Vector2 = _gamepad_stick_vector(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y)
	if _pad_build_preview_active():
		var left_stick: Vector2 = _gamepad_stick_vector(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y)
		if left_stick != Vector2.ZERO:
			stick = left_stick
		var dpad_direction: Vector2i = _dpad_cell_direction()
		if dpad_direction != Vector2i.ZERO:
			_update_pad_cursor_repeat(dpad_direction, delta)
			return
	if stick == Vector2.ZERO:
		_reset_pad_cursor_repeat()
		return
	var step_direction: Vector2i = _stick_to_cell_direction(stick)
	if step_direction == Vector2i.ZERO:
		_reset_pad_cursor_repeat()
		return
	_update_pad_cursor_repeat(step_direction, delta)

func _update_pad_cursor_repeat(step_direction: Vector2i, delta: float) -> void:
	if step_direction != _pad_cursor_repeat_direction:
		_move_pad_build_cursor(step_direction)
		_pad_cursor_repeat_direction = step_direction
		_pad_cursor_repeat_time = maxf(gamepad_cursor_initial_repeat_delay, 0.0)
		return
	_pad_cursor_repeat_time -= delta
	while _pad_cursor_repeat_time <= 0.0:
		_move_pad_build_cursor(step_direction)
		_pad_cursor_repeat_time += maxf(gamepad_cursor_repeat_interval, 0.001)

func _stick_to_cell_direction(stick: Vector2) -> Vector2i:
	if absf(stick.x) >= absf(stick.y):
		return Vector2i(1 if stick.x > 0.0 else -1, 0)
	return Vector2i(0, 1 if stick.y > 0.0 else -1)

func _dpad_cell_direction() -> Vector2i:
	if _active_gamepad_device < 0:
		return Vector2i.ZERO
	var x: int = 0
	var y: int = 0
	if Input.is_joy_button_pressed(_active_gamepad_device, JOY_BUTTON_DPAD_LEFT):
		x -= 1
	if Input.is_joy_button_pressed(_active_gamepad_device, JOY_BUTTON_DPAD_RIGHT):
		x += 1
	if Input.is_joy_button_pressed(_active_gamepad_device, JOY_BUTTON_DPAD_UP):
		y -= 1
	if Input.is_joy_button_pressed(_active_gamepad_device, JOY_BUTTON_DPAD_DOWN):
		y += 1
	if x != 0:
		return Vector2i(x, 0)
	if y != 0:
		return Vector2i(0, y)
	return Vector2i.ZERO

func _move_pad_build_cursor(direction: Vector2i) -> void:
	if build_system != null and build_system.has_method("pad_move_cursor"):
		build_system.call("pad_move_cursor", direction)

func _reset_pad_cursor_repeat() -> void:
	_pad_cursor_repeat_direction = Vector2i.ZERO
	_pad_cursor_repeat_time = 0.0

func _deactivate_pad_build_cursor() -> void:
	if build_system != null and build_system.has_method("pad_set_cursor_active"):
		build_system.call("pad_set_cursor_active", false)

func _update_pad_navigation_input() -> void:
	if _active_gamepad_device < 0:
		_dpad_left_pressed = false
		_dpad_right_pressed = false
		_dpad_up_pressed = false
		_dpad_down_pressed = false
		return

	var left_pressed: bool = Input.is_joy_button_pressed(_active_gamepad_device, JOY_BUTTON_DPAD_LEFT)
	var right_pressed: bool = Input.is_joy_button_pressed(_active_gamepad_device, JOY_BUTTON_DPAD_RIGHT)
	var up_pressed: bool = Input.is_joy_button_pressed(_active_gamepad_device, JOY_BUTTON_DPAD_UP)
	var down_pressed: bool = Input.is_joy_button_pressed(_active_gamepad_device, JOY_BUTTON_DPAD_DOWN)
	var any_new_press: bool = (
		(left_pressed and not _dpad_left_pressed)
		or (right_pressed and not _dpad_right_pressed)
		or (up_pressed and not _dpad_up_pressed)
		or (down_pressed and not _dpad_down_pressed)
	)
	if _pad_build_preview_active():
		_dpad_left_pressed = left_pressed
		_dpad_right_pressed = right_pressed
		_dpad_up_pressed = up_pressed
		_dpad_down_pressed = down_pressed
		return
	if any_new_press and _should_pad_open_quickbar_from_dpad():
		_activate_last_quickbar_slot()
		_dpad_left_pressed = left_pressed
		_dpad_right_pressed = right_pressed
		_dpad_up_pressed = up_pressed
		_dpad_down_pressed = down_pressed
		return
	# While the seed-merchant shop is open it owns the whole d-pad: every direction browses its
	# vertical item list (left/up step up, right/down step down) and quick-slot switching is
	# suppressed so the shop keeps focus until it closes.
	if _is_merchant_shop_open():
		var merchant_step: int = 0
		if (up_pressed and not _dpad_up_pressed) or (left_pressed and not _dpad_left_pressed):
			merchant_step = -1
		elif (down_pressed and not _dpad_down_pressed) or (right_pressed and not _dpad_right_pressed):
			merchant_step = 1
		if merchant_step != 0:
			_step_pad_shop_selection(merchant_step)
		_dpad_left_pressed = left_pressed
		_dpad_right_pressed = right_pressed
		_dpad_up_pressed = up_pressed
		_dpad_down_pressed = down_pressed
		return
	if left_pressed and not _dpad_left_pressed and game_ui and game_ui.has_method("step_selected_quick_slot"):
		game_ui.call("step_selected_quick_slot", -1)
	if right_pressed and not _dpad_right_pressed and game_ui and game_ui.has_method("step_selected_quick_slot"):
		game_ui.call("step_selected_quick_slot", 1)
	if up_pressed and not _dpad_up_pressed:
		_step_pad_shop_selection(-1)
	if down_pressed and not _dpad_down_pressed:
		_step_pad_shop_selection(1)
	_dpad_left_pressed = left_pressed
	_dpad_right_pressed = right_pressed
	_dpad_up_pressed = up_pressed
	_dpad_down_pressed = down_pressed

func _step_pad_shop_selection(direction: int) -> void:
	if toolbuild != null and toolbuild.has_method("step_pad_selection"):
		toolbuild.call("step_pad_selection", direction)

func _is_merchant_shop_open() -> bool:
	return toolbuild != null and toolbuild.has_method("is_merchant_shop_open") and bool(toolbuild.call("is_merchant_shop_open"))

func _should_pad_open_quickbar_from_dpad() -> bool:
	if _paused or _cutscene_input_locked or _is_inventory_open():
		return false
	if _is_quickbar_active():
		return false
	if _is_merchant_shop_open():
		return false
	return game_ui != null and game_ui.has_method("activate_last_quickbar_slot")

func _activate_last_quickbar_slot() -> void:
	if game_ui != null and game_ui.has_method("activate_last_quickbar_slot"):
		game_ui.call("activate_last_quickbar_slot")

func _handle_pad_accept() -> void:
	if _paused or _cutscene_input_locked or _is_inventory_open():
		return
	if toolbuild != null and toolbuild.has_method("activate_pad_selection") and bool(toolbuild.call("activate_pad_selection")):
		return
	# A validates the unbuild selection like placing a building: first press anchors the removal
	# rectangle, a second press commits it.
	if _unbuild_selected():
		if build_system != null and build_system.has_method("pad_confirm_remove_at_cursor"):
			build_system.call("pad_confirm_remove_at_cursor")
		return
	if _in_build_mode() and build_system != null and build_system.has_method("pad_place_selected_at_cursor"):
		build_system.call("pad_place_selected_at_cursor")

func _handle_pad_cancel() -> void:
	if _paused or _cutscene_input_locked or _is_inventory_open():
		return
	if _is_quickbar_active():
		_clear_build_selection()
		_deactivate_quickbar()
		return
	if build_system == null:
		return
	# The seed-merchant shop owns B while it is open; don't let it double as the unbuild button.
	if _is_merchant_shop_open():
		return
	# Cancel an in-progress placement preview first.
	if build_system.has_method("pad_cancel_build_preview") and bool(build_system.call("pad_cancel_build_preview")):
		return
	# Abort any in-progress removal drag, but do NOT return: B then falls through to the toggle so
	# a single press both cancels the drag and puts the unbuild icon away (like right-click).
	if build_system.has_method("pad_cancel_remove_drag"):
		build_system.call("pad_cancel_remove_drag")
	# B toggles the unbuild tool, mirroring right-click: select it, or deselect it if it is already
	# the equipped tool. Removal itself is validated with A, not B.
	if _unbuild_selected():
		_clear_build_selection()
	else:
		_select_unbuild_tool()

func _handle_pad_rotate_build() -> void:
	if _paused or _cutscene_input_locked or _is_inventory_open():
		return
	if not _build_controls_active() or build_system == null:
		return
	if build_system.has_method("pad_rotate_selected_at_cursor"):
		build_system.call("pad_rotate_selected_at_cursor")

func _pad_build_preview_active() -> bool:
	return build_system != null and build_system.has_method("pad_is_build_preview_active") and bool(build_system.call("pad_is_build_preview_active"))

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
	var pad_aim: Vector2 = _gamepad_stick_vector(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y)
	var direction: Vector2 = pad_aim if _control_mode == INPUT_MODE_PAD else get_global_mouse_position() - origin
	var weapon_id: String = ""
	var trigger_allowed: bool = not _paused and not _cutscene_input_locked and not _is_inventory_open()
	if _control_mode == INPUT_MODE_PAD:
		trigger_allowed = trigger_allowed and pad_aim != Vector2.ZERO
	else:
		trigger_allowed = trigger_allowed and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		trigger_allowed = trigger_allowed and get_viewport().gui_get_hovered_control() == null
	trigger_allowed = trigger_allowed and not _in_build_mode() and not _unbuild_selected()
	if trigger_allowed:
		var selected_id: String = _selected_item_id()
		if not _selected_item_disabled_for_placement(selected_id) and direction.length_squared() >= 0.000001:
			weapon_id = selected_id
			if _control_mode == INPUT_MODE_PAD and not fight_system.is_held_weapon(weapon_id) and not _right_stick_weapon_active:
				fight_system.use_weapon(weapon_id, origin, direction, player_nav_id, _weapon_origin_offset(player))
			_right_stick_weapon_active = _control_mode == INPUT_MODE_PAD
	else:
		_right_stick_weapon_active = false
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
			"contact_push_power": 216.0,
			"contact_push_resist": 2.0,
			"contact_push_cooldown": 0.16,
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
	_apply_camera_map_bounds()

## Clamp the camera to the level's authored map bounds (mapBounds). No-op when the level
## has no mapBounds node or the loader is unavailable.
func _apply_camera_map_bounds() -> void:
	if camera_controller == null or not camera_controller.has_method("set_world_bounds"):
		return
	var scene: Node = get_tree().current_scene
	var loader: Node = scene.get_node_or_null("LevelLoader") if scene else null
	if loader == null or not loader.has_method("get_loaded_map_bounds_world"):
		return
	var world_rect: Rect2 = loader.call("get_loaded_map_bounds_world")
	camera_controller.set_world_bounds(world_rect)

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
	var parent: Node = get_parent()
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
	if not player:
		return
	var lance: Sprite2D = player.get_node_or_null("lance") as Sprite2D
	if not lance:
		return

	var weapon_id: String = _selected_item_id()
	var origin: Vector2 = _weapon_origin(player)
	var pad_aim: Vector2 = _gamepad_stick_vector(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y)
	var direction: Vector2 = pad_aim if _control_mode == INPUT_MODE_PAD and pad_aim != Vector2.ZERO else get_global_mouse_position() - origin
	var facing: Vector2 = _last_lance_facing
	if direction.length_squared() > 0.000001:
		facing = direction.normalized()
		_last_lance_facing = facing
	var throw_offset: float = _lance_throw_offset(weapon_id)
	var local_origin: Vector2 = _weapon_origin_offset(player)
	var visual_anchor: Vector2 = _lance_visual_anchor(player, local_origin)
	lance.position = visual_anchor + facing * throw_offset
	lance.rotation = facing.angle() + PI * 0.5
	lance.visible = true

func _lance_visual_anchor(player: Node2D, local_origin: Vector2) -> Vector2:
	var rest_anchor: Vector2 = local_origin + LANCE_VISUAL_ANCHOR_OFFSET
	for child: Node in player.get_children():
		if child is CharacterAnimation:
			var animation: CharacterAnimation = child
			return animation.animated_parent_position(rest_anchor)
	return rest_anchor

func _lance_throw_offset(weapon_id: String) -> float:
	if _is_lance_weapon(weapon_id):
		return float(fight_system.call("get_held_weapon_throw_offset", weapon_id))
	return DEFAULT_LANCE_THROW_OFFSET

func _is_lance_weapon(weapon_id: String) -> bool:
	if weapon_id == "" or not fight_system:
		return false
	# The lance shows for any held weapon: spray weapons and guns (water, epine).
	if not fight_system.is_held_weapon(weapon_id):
		return false
	return fight_system.has_method("get_held_weapon_throw_offset")

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
	if not _paused and not _cutscene_input_locked:
		if _is_any_key_pressed([KEY_Z, KEY_W, KEY_UP]):
			dir.y -= 1.0
		if _is_any_key_pressed([KEY_S, KEY_DOWN]):
			dir.y += 1.0
		if _is_any_key_pressed([KEY_Q, KEY_A, KEY_LEFT]):
			dir.x -= 1.0
		if _is_any_key_pressed([KEY_D, KEY_RIGHT]):
			dir.x += 1.0
		if not (_control_mode == INPUT_MODE_PAD and _pad_build_preview_active()):
			dir += _gamepad_stick_vector(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y)

	if dir.length_squared() > 1.0:
		dir = dir.normalized()

	var shift_pressed: bool = _is_any_key_pressed([KEY_SHIFT])
	var rush_pressed: bool = shift_pressed or _pad_rush_pressed()
	var rush_started: bool = false
	if _paused or _cutscene_input_locked:
		_stop_rush()
	elif rush_pressed and not _rush_input_was_pressed and not _rush_active:
		var start_direction: Vector2 = dir if dir.length_squared() > 0.0 else _last_move_direction
		if start_direction.length_squared() > 0.0:
			_start_rush(start_direction.normalized())
			rush_started = true
	_rush_input_was_pressed = rush_pressed

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
			if rush_player.global_position.distance_to(_trail_last_emit_pos) >= rush_trail_spacing:
				_emit_trail_puff(rush_player.global_position)
	else:
		if dir.length_squared() > 0.0:
			_last_move_direction = dir.normalized()

	_update_player_facing(dir)
	_update_terrain_speed_state()
	steering.call("set_agent_input", player_nav_id, dir)

func _update_player_facing(direction: Vector2) -> void:
	var player: Node2D = _get_player_node()
	if player != null and player.has_method("set_facing_direction"):
		player.call("set_facing_direction", direction)

func _start_rush(direction: Vector2) -> void:
	_rush_active = true
	_rush_time_left = maxf(rush_duration, 0.0)
	_rush_direction = direction
	var player: Node2D = _get_player_node()
	if player:
		_rush_sample_position = player.global_position
		_emit_trail_puff(player.global_position)
	_set_rush_speed(true)

## Fires one pooled smoke puff at the player's feet and records the spot so the
## next puff only spawns after [member rush_trail_spacing] more travel.
func _emit_trail_puff(world_position: Vector2) -> void:
	if smoke_trail:
		smoke_trail.emit_at(world_position)
	_trail_last_emit_pos = world_position

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

func _update_terrain_speed_state() -> void:
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
	return base_speed * _speed_multiplier() * rush_multiplier

func _is_any_key_pressed(keys: Array[int]) -> bool:
	for key in keys:
		if Input.is_key_pressed(key) or Input.is_physical_key_pressed(key):
			return true
	return false

func _pad_rush_pressed() -> bool:
	if _control_mode != INPUT_MODE_PAD or _active_gamepad_device < 0:
		return false
	return Input.get_joy_axis(_active_gamepad_device, JOY_AXIS_TRIGGER_RIGHT) >= gamepad_trigger_threshold

func _is_inventory_open() -> bool:
	return game_ui and game_ui.has_method("is_inventory_open") and bool(game_ui.call("is_inventory_open"))

func _selected_item_id() -> String:
	if not game_ui or not game_ui.has_method("get_selected_quick_item_id"):
		return ""
	return String(game_ui.call("get_selected_quick_item_id"))

func _is_quickbar_active() -> bool:
	return game_ui and game_ui.has_method("is_quickbar_active") and bool(game_ui.call("is_quickbar_active"))

func _active_quickbar_menu_kind() -> String:
	if not game_ui or not game_ui.has_method("get_active_menu_kind"):
		return ""
	return String(game_ui.call("get_active_menu_kind"))

## Opens/closes the seed-merchant shop when the player stands at the merchant. Returns true when
## the press was consumed (at the merchant, or the shop was open), so callers can fall back to
## another action otherwise. Suppressed while paused or the inventory is open.
func _try_toggle_merchant_shop() -> bool:
	if _paused or _is_inventory_open():
		return false
	if toolbuild == null or not toolbuild.has_method("toggle_merchant_shop"):
		return false
	return bool(toolbuild.call("toggle_merchant_shop"))


func _deactivate_quickbar() -> void:
	if game_ui and game_ui.has_method("deactivate_quickbar"):
		game_ui.call("deactivate_quickbar")

func _clear_build_selection() -> void:
	if game_ui and game_ui.has_method("clear_build_selection"):
		game_ui.call("clear_build_selection")

## True while a build preview owns the click instead of the weapon.
func _in_build_mode() -> bool:
	return game_ui and game_ui.has_method("get_selected_build_item_id") and String(game_ui.call("get_selected_build_item_id")) != ""

# True while a build-tool menu or build preview is active. The unbuild tool counts too, so its
# build cursor / frame and removal input turn on the same way the placement tools do.
func _build_tool_selected() -> bool:
	if _unbuild_selected():
		return true
	return game_ui and game_ui.has_method("is_build_tool_selected") and bool(game_ui.call("is_build_tool_selected"))

func _unbuild_selected() -> bool:
	return game_ui and game_ui.has_method("is_unbuild_tool_selected") and bool(game_ui.call("is_unbuild_tool_selected"))

func _select_unbuild_tool() -> void:
	if game_ui and game_ui.has_method("select_unbuild_tool"):
		game_ui.call("select_unbuild_tool")

func _build_controls_active() -> bool:
	if not _build_tool_selected():
		return false
	if _is_merchant_shop_open():
		return false
	return true

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
	var player: Node2D = _get_player_node()
	if not player or not fight_system:
		return
	var origin: Vector2 = _weapon_origin(player)
	var direction: Vector2 = get_global_mouse_position() - origin
	if bool(fight_system.use_weapon(weapon_id, origin, direction, player_nav_id, _weapon_origin_offset(player))):
		get_viewport().set_input_as_handled()

func _toggle_pause() -> void:
	set_paused(not _paused)

func set_paused(paused: bool) -> void:
	if not paused and _pause_hold_count > 0:
		return
	if _paused == paused:
		return
	_paused = paused
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

func set_cutscene_input_locked(locked: bool) -> void:
	if _cutscene_input_locked == locked:
		return
	_cutscene_input_locked = locked
	if locked:
		_stop_rush()
		_right_stick_weapon_active = false

func is_paused() -> bool:
	return _paused

func push_pause_hold() -> void:
	_pause_hold_count += 1
	set_paused(true)

func pop_pause_hold() -> void:
	_pause_hold_count = maxi(_pause_hold_count - 1, 0)

func _toggle_units_visible(isvisible: bool) -> void:
	for node in get_tree().get_nodes_in_group("main_chars"):
		if node is Node2D:
			var unit: Node2D = node
			unit.visible = isvisible

func _toggle_group_paused(group_name: StringName, paused: bool) -> void:
	for node: Node in get_tree().get_nodes_in_group(group_name):
		if node.has_method("set_paused"):
			node.call("set_paused", paused)
