extends Node
class_name DayNightColors

@export var enabled: bool = true:
	set(value):
		enabled = value
		if is_inside_tree():
			_apply_enabled_state()

@export var day_color: Color = Color(1, 1, 1, 1)
@export var night_color: Color = Color(0.25, 0.32, 0.55, 1)
@export_range(0.0, 60.0, 0.1, "or_greater") var transition_duration: float = 3.0
@export var start_at_night: bool = false
@export var apply_on_ready: bool = true
@export var debug_toggle_action: StringName = &""
@export var transition_ease: Tween.EaseType = Tween.EASE_IN_OUT
@export var transition_trans: Tween.TransitionType = Tween.TRANS_SINE
@export var sync_with_game_state: bool = true

var _canvas_modulate: CanvasModulate
var _tween: Tween
var _night_active: bool = false


func _ready() -> void:
	_canvas_modulate = get_node_or_null("CanvasModulate") as CanvasModulate
	if not _canvas_modulate:
		push_warning("dayNightColors requires a CanvasModulate child.")
		return

	if not enabled:
		_apply_enabled_state()
		return

	_night_active = start_at_night
	if apply_on_ready:
		_set_color(night_color if _night_active else day_color)

	_connect_game_state()


func _unhandled_input(event: InputEvent) -> void:
	if debug_toggle_action == &"":
		return
	if event.is_action_pressed(debug_toggle_action):
		toggle_day_night()


func set_day(instant: bool = false) -> void:
	_night_active = false
	_transition_to(day_color, instant)


func set_night(instant: bool = false) -> void:
	_night_active = true
	_transition_to(night_color, instant)


func toggle_day_night(instant: bool = false) -> void:
	if _night_active:
		set_day(instant)
	else:
		set_night(instant)


func is_night() -> bool:
	return _night_active


func _connect_game_state() -> void:
	if not sync_with_game_state:
		return

	var game_state: Node = get_node_or_null("/root/GameState")
	if not game_state or not game_state.has_signal("mode_changed"):
		return

	var mode_changed_callable: Callable = Callable(self, "_on_game_mode_changed")
	if not game_state.is_connected(&"mode_changed", mode_changed_callable):
		game_state.connect(&"mode_changed", mode_changed_callable)

	var game_state_is_night: bool = bool(game_state.get("is_night"))
	if game_state_is_night != _night_active:
		if game_state_is_night:
			set_night(true)
		else:
			set_day(true)


func _on_game_mode_changed(game_state_is_night: bool) -> void:
	if game_state_is_night:
		set_night()
	else:
		set_day()


func _transition_to(target_color: Color, instant: bool) -> void:
	if not _canvas_modulate:
		return

	_kill_tween()

	if not enabled:
		_apply_enabled_state()
		return

	if instant or transition_duration <= 0.0:
		_set_color(target_color)
		return

	_tween = create_tween()
	_tween.set_ease(transition_ease)
	_tween.set_trans(transition_trans)
	_tween.tween_property(_canvas_modulate, "color", target_color, transition_duration)
	_tween.finished.connect(_on_tween_finished)


func _apply_enabled_state() -> void:
	_night_active = false
	_kill_tween()
	if _canvas_modulate:
		_set_color(day_color)


func _set_color(color: Color) -> void:
	_canvas_modulate.color = color


func _kill_tween() -> void:
	if _tween:
		_tween.kill()
		_tween = null


func _on_tween_finished() -> void:
	_tween = null
