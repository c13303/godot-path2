extends Node

func _ready() -> void:
	call_deferred("_apply_startup_window_mode")

func _apply_startup_window_mode() -> void:
	var window: Window = get_window()
	if not window:
		return
	window.mode = Window.MODE_FULLSCREEN
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
