extends RichTextLabel

@export var default_duration_seconds: float = 5.0

var _hide_after_seconds: float = 0.0

func _ready() -> void:
	visible = false
	set_process(false)

func show_notif(message: String, duration_seconds: float = -1.0) -> void:
	text = message
	visible = true
	_hide_after_seconds = duration_seconds if duration_seconds >= 0.0 else default_duration_seconds
	set_process(_hide_after_seconds > 0.0)

func _process(delta: float) -> void:
	_hide_after_seconds -= delta
	if _hide_after_seconds > 0.0:
		return
	visible = false
	set_process(false)
