extends Node2D

const FADE_DURATION_SECONDS: float = 10.0

var _fade_started: bool = false


func _ready() -> void:
	GameState.mode_changed.connect(_on_game_mode_changed)
	if not GameState.is_night:
		_start_fade()


func _on_game_mode_changed(is_night: bool) -> void:
	if not is_night:
		_start_fade()


func _start_fade() -> void:
	if _fade_started:
		return
	_fade_started = true
	var fade_tween: Tween = create_tween()
	fade_tween.set_trans(Tween.TRANS_LINEAR)
	fade_tween.tween_property(self, "modulate:a", 0.0, FADE_DURATION_SECONDS)
	fade_tween.tween_callback(Callable(self, "queue_free"))
