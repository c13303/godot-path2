extends Node
class_name SpawnerRevealCutsceneController

signal reveal_item(context: StringName, item_index: int, item: Dictionary)
signal completed(context: StringName, release_spawning: bool)

const SKIP_PROMPT_SCRIPT: Script = preload("res://scripts/ui/cutscene_skip_prompt.gd")
const SCROLL_SECONDS: float = 2.0
const SPAWNER_PAUSE_SECONDS: float = 1.0
const RETURN_SECONDS: float = 1.0
const SKIP_HOLD_SECONDS: float = 0.5

var _camera: CameraController
var _player: Node2D
var _player_controller: PlayerController
var _skip_prompt_layer: CanvasLayer
var _skip_prompt: CutsceneSkipPrompt
var _context: StringName = &""
var _focus_tutorial_key: String = ""
var _items: Array[Dictionary] = []
var _revealed_indices: Dictionary = {}
var _active: bool = false
var _skip_requested: bool = false
var _skip_held: bool = false
var _skip_hold_elapsed: float = 0.0
var _run_id: int = 0


func _ready() -> void:
	set_process_input(false)
	set_process(false)


func begin(context: StringName, items: Array[Dictionary], focus_tutorial_key: String = "") -> bool:
	if _active:
		_skip_requested = true
		return true
	if items.is_empty():
		return false
	if not _resolve_scene_nodes():
		return false
	_context = context
	_focus_tutorial_key = focus_tutorial_key
	_items.clear()
	for item: Dictionary in items:
		_items.append(item.duplicate())
	_revealed_indices.clear()
	_skip_requested = false
	_skip_held = false
	_skip_hold_elapsed = 0.0
	_active = true
	_run_id += 1
	set_process_input(true)
	set_process(true)
	_show_skip_prompt()
	_player_controller.set_cutscene_input_locked(true)
	_camera.set_follow_target(null)
	call_deferred("_run_cutscene", _run_id)
	return true


func abort() -> void:
	if not _active:
		return
	_skip_requested = true
	_run_id += 1
	_finish(false)


func is_active_context(context: StringName) -> bool:
	return _active and _context == context


func _input(event: InputEvent) -> void:
	if not _active or _skip_requested:
		return
	if event is InputEventMouseButton:
		var mouse_event: InputEventMouseButton = event
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			_set_skip_held(mouse_event.pressed or _is_skip_input_held())
			get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton:
		var joypad_event: InputEventJoypadButton = event
		_set_skip_held(joypad_event.pressed or _is_skip_input_held())
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _active or _skip_requested:
		return
	if not _skip_held or not _is_skip_input_held():
		_set_skip_held(false)
		return
	_skip_hold_elapsed = minf(_skip_hold_elapsed + delta, SKIP_HOLD_SECONDS)
	_update_skip_prompt_progress()
	if _skip_hold_elapsed >= SKIP_HOLD_SECONDS:
		_skip_requested = true
		get_viewport().set_input_as_handled()


func _set_skip_held(held: bool) -> void:
	_skip_held = held
	if not _skip_held and _skip_hold_elapsed > 0.0:
		_skip_hold_elapsed = 0.0
		_update_skip_prompt_progress()


func _is_skip_input_held() -> bool:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return true
	for device: int in Input.get_connected_joypads():
		for button: int in range(JOY_BUTTON_MAX):
			if Input.is_joy_button_pressed(device, button):
				return true
	return false


func _run_cutscene(run_id: int) -> void:
	for index: int in range(_items.size()):
		if run_id != _run_id:
			return
		if _skip_requested:
			break
		var item: Dictionary = _items[index]
		var target_position: Vector2 = item.get("world_position", Vector2.ZERO) as Vector2
		await _move_camera_to(target_position, SCROLL_SECONDS, true)
		if run_id != _run_id:
			return
		if _skip_requested:
			break
		_show_focus_tutorial()
		_reveal_item(index)
		await _wait_or_skip(SPAWNER_PAUSE_SECONDS)
		if run_id != _run_id:
			return
	if _skip_requested:
		_reveal_remaining_items()
		await _move_camera_to(_player.global_position, RETURN_SECONDS, false)
		if run_id != _run_id:
			return
		_finish(true)
		return
	await _move_camera_to(_player.global_position, RETURN_SECONDS, false)
	if run_id != _run_id:
		return
	_finish(true)


func _resolve_scene_nodes() -> bool:
	var tree: SceneTree = get_tree()
	if tree == null:
		return false
	var scene: Node = tree.current_scene
	if scene == null:
		return false
	_camera = scene.get_node_or_null("Camera2D") as CameraController
	_player = tree.get_first_node_in_group("player") as Node2D
	_player_controller = scene.get_node_or_null("Player/PlayerController") as PlayerController
	return _camera != null and _player != null and _player_controller != null


func _move_camera_to(target_position: Vector2, duration: float, allow_skip_interrupt: bool) -> void:
	if _camera == null:
		return
	var start_position: Vector2 = _camera.global_position
	var elapsed: float = 0.0
	var safe_duration: float = maxf(duration, 0.001)
	while elapsed < safe_duration and (not allow_skip_interrupt or not _skip_requested):
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		var amount: float = clampf(elapsed / safe_duration, 0.0, 1.0)
		var eased_amount: float = amount * amount * (3.0 - 2.0 * amount)
		_camera.global_position = start_position.lerp(target_position, eased_amount)
	if not allow_skip_interrupt or not _skip_requested:
		_camera.global_position = target_position


func _wait_or_skip(duration: float) -> void:
	var elapsed: float = 0.0
	while elapsed < duration and not _skip_requested:
		await get_tree().process_frame
		elapsed += get_process_delta_time()


func _reveal_item(index: int) -> void:
	if _revealed_indices.has(index):
		return
	_revealed_indices[index] = true
	reveal_item.emit(_context, index, _items[index])


func _reveal_remaining_items() -> void:
	for index: int in range(_items.size()):
		_reveal_item(index)


func _finish(release_spawning: bool) -> void:
	if _camera != null and _player != null:
		_camera.global_position = _player.global_position
		_camera.set_follow_target(_player, true)
	if _player_controller != null:
		_player_controller.set_cutscene_input_locked(false)
	_hide_skip_prompt()
	var finished_context: StringName = _context
	_active = false
	_skip_requested = false
	_skip_held = false
	_skip_hold_elapsed = 0.0
	_context = &""
	_focus_tutorial_key = ""
	_items.clear()
	_revealed_indices.clear()
	set_process_input(false)
	set_process(false)
	completed.emit(finished_context, release_spawning)


func _show_skip_prompt() -> void:
	if _skip_prompt_layer == null:
		_skip_prompt_layer = CanvasLayer.new()
		_skip_prompt_layer.layer = 100
		add_child(_skip_prompt_layer)
	if _skip_prompt == null:
		_skip_prompt = SKIP_PROMPT_SCRIPT.new() as CutsceneSkipPrompt
		_skip_prompt.anchor_left = 1.0
		_skip_prompt.anchor_top = 1.0
		_skip_prompt.anchor_right = 1.0
		_skip_prompt.anchor_bottom = 1.0
		_skip_prompt.offset_left = -384.0
		_skip_prompt.offset_top = -84.0
		_skip_prompt.offset_right = -24.0
		_skip_prompt.offset_bottom = -28.0
		_skip_prompt_layer.add_child(_skip_prompt)
	_skip_prompt.visible = true
	_update_skip_prompt_progress()


func _hide_skip_prompt() -> void:
	if _skip_prompt != null:
		_skip_prompt.visible = false
		_skip_prompt.set_progress(0.0)


func _update_skip_prompt_progress() -> void:
	if _skip_prompt != null:
		_skip_prompt.set_progress(_skip_hold_elapsed / SKIP_HOLD_SECONDS)


func _show_focus_tutorial() -> void:
	if _focus_tutorial_key == "":
		return
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var tutorial: Node = scene.get_node_or_null("GameUI/top anchor/tutorial")
	if tutorial != null and tutorial.has_method("show_alert"):
		tutorial.call("show_alert", _focus_tutorial_key)
