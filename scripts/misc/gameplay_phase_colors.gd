extends Node
class_name GameplayPhaseColors

@export var enabled: bool = true:
	set(value):
		enabled = value
		if is_inside_tree():
			_apply_enabled_state()

@export var afternoon_color: Color = Color(1.0, 0.94, 0.86, 1.0)
@export var night_color: Color = Color(0.25, 0.32, 0.55, 1)
@export var dawn_color: Color = Color(0.92, 0.96, 1.0, 1.0)
@export var morning_color: Color = Color.WHITE
@export_range(0.0, 60.0, 0.1, "or_greater") var transition_duration: float = 3.0
@export var start_at_night: bool = false
@export var apply_on_ready: bool = true
@export var debug_toggle_action: StringName = &""
@export var transition_ease: Tween.EaseType = Tween.EASE_IN_OUT
@export var transition_trans: Tween.TransitionType = Tween.TRANS_SINE
@export var sync_with_game_state: bool = true

var _canvas_modulate: CanvasModulate
var _tween: Tween
var _active_phase: int = GameState.GameplayPhase.AFTERNOON


func _ready() -> void:
	_canvas_modulate = get_node_or_null("CanvasModulate") as CanvasModulate
	if not _canvas_modulate:
		push_warning("GameplayPhaseColors requires a CanvasModulate child.")
		return

	if not enabled:
		_apply_enabled_state()
		return

	_active_phase = GameState.GameplayPhase.NIGHT if start_at_night else GameState.GameplayPhase.AFTERNOON
	if apply_on_ready:
		_set_color(_color_for_phase(_active_phase))

	_connect_game_state()


func _unhandled_input(event: InputEvent) -> void:
	if debug_toggle_action == &"":
		return
	if event.is_action_pressed(debug_toggle_action):
		toggle_afternoon_night()


func set_afternoon(instant: bool = false) -> void:
	set_gameplay_phase(GameState.GameplayPhase.AFTERNOON, instant)


func set_night(instant: bool = false) -> void:
	set_gameplay_phase(GameState.GameplayPhase.NIGHT, instant)


func set_dawn(instant: bool = false) -> void:
	set_gameplay_phase(GameState.GameplayPhase.DAWN, instant)


func set_morning(instant: bool = false) -> void:
	set_gameplay_phase(GameState.GameplayPhase.MORNING, instant)


func set_gameplay_phase(phase: int, instant: bool = false) -> void:
	_active_phase = phase
	_transition_to(_color_for_phase(phase), instant)


func toggle_afternoon_night(instant: bool = false) -> void:
	if _active_phase == GameState.GameplayPhase.NIGHT:
		set_afternoon(instant)
	else:
		set_night(instant)


func is_night() -> bool:
	return _active_phase == GameState.GameplayPhase.NIGHT


func _connect_game_state() -> void:
	if not sync_with_game_state:
		return

	var game_state: Node = get_node_or_null("/root/GameState")
	if not game_state or not game_state.has_signal("gameplay_phase_changed"):
		return

	var phase_changed_callable: Callable = Callable(self, "_on_gameplay_phase_changed")
	if not game_state.is_connected(&"gameplay_phase_changed", phase_changed_callable):
		game_state.connect(&"gameplay_phase_changed", phase_changed_callable)

	var current_phase: int = int(game_state.get("gameplay_phase"))
	if current_phase != _active_phase:
		set_gameplay_phase(current_phase, true)


func _on_gameplay_phase_changed(phase: int) -> void:
	set_gameplay_phase(phase)


func _color_for_phase(phase: int) -> Color:
	match phase:
		GameState.GameplayPhase.NIGHT:
			return night_color
		GameState.GameplayPhase.DAWN:
			return dawn_color
		GameState.GameplayPhase.MORNING:
			return morning_color
		_:
			return afternoon_color


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
	_kill_tween()
	if _canvas_modulate:
		_set_color(Color.WHITE)


func _set_color(color: Color) -> void:
	_canvas_modulate.color = color


func _kill_tween() -> void:
	if _tween:
		_tween.kill()
		_tween = null


func _on_tween_finished() -> void:
	_tween = null
