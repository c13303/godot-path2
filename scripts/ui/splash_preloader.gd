extends Control

# ---------------------------------------------------------------------------
# Startup splash shown while the heavy mainRun scene loads in the background.
#
# The image and music are prewired in splash_preloader.tscn (no hot loading);
# this script only covers the disk load and the transition into the game:
#   * mainRun is loaded on a worker thread as soon as the splash appears (this
#     only overlaps the disk read/parse with the splash; the scene's own
#     instantiation and _ready init still run on the main thread on entry).
#   * A click or any key requests entering the game. If the parse is already
#     done it happens instantly; otherwise the request is remembered and
#     honored the moment the parse finishes.
#   * With no input, the splash stays up (it never auto-advances).
# ---------------------------------------------------------------------------

const MAIN_RUN_SCENE: String = "res://mainRun.tscn"

var _load_requested: bool = false
var _loaded_scene: PackedScene = null
var _skip_requested: bool = false
var _advancing: bool = false


func _ready() -> void:
	var request_error: Error = ResourceLoader.load_threaded_request(MAIN_RUN_SCENE)
	if request_error == OK:
		_load_requested = true
	else:
		push_error("Splash preloader: failed to start loading %s (error %d)" % [MAIN_RUN_SCENE, int(request_error)])
		# Fall back to a blocking load so the game still starts.
		_loaded_scene = load(MAIN_RUN_SCENE) as PackedScene


func _process(_delta: float) -> void:
	_poll_loading()
	_try_advance()


func _unhandled_input(event: InputEvent) -> void:
	if not _is_skip_event(event):
		return
	get_viewport().set_input_as_handled()
	# A click/key requests entering the game. It only takes effect once the scene
	# has finished loading; until then the request is simply remembered.
	_skip_requested = true
	_try_advance()


func _is_skip_event(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).pressed
	if event is InputEventKey:
		var key_event: InputEventKey = event as InputEventKey
		return key_event.pressed and not key_event.echo
	if event is InputEventJoypadButton:
		return (event as InputEventJoypadButton).pressed
	return false


func _poll_loading() -> void:
	if _loaded_scene != null or not _load_requested:
		return
	var status: int = ResourceLoader.load_threaded_get_status(MAIN_RUN_SCENE)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		_loaded_scene = ResourceLoader.load_threaded_get(MAIN_RUN_SCENE) as PackedScene
	elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		push_error("Splash preloader: loading %s failed (status %d)" % [MAIN_RUN_SCENE, status])
		_load_requested = false
		_loaded_scene = load(MAIN_RUN_SCENE) as PackedScene


func _try_advance() -> void:
	if _advancing or not _skip_requested or _loaded_scene == null:
		return
	_advancing = true
	var change_error: Error = get_tree().change_scene_to_packed(_loaded_scene)
	if change_error != OK:
		push_error("Splash preloader: failed to enter %s (error %d)" % [MAIN_RUN_SCENE, int(change_error)])
