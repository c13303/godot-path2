extends Node
## Game-flow / menu controller for the main run scene.
##
## Owns the in-scene confirmation prompts:
##   - R asks to reset the game and start a fresh new game.
##   - ESC asks to quit.
##
## The prompt UI is premade and themed in mainRun.tscn under `Prompts`; this
## script only drives its message and YES/NO behaviour. The actual save / load /
## reset work lives in the sibling `progression` node.

const LEVEL_MENU_SCENE: String = "res://scenes/menus/level_loader.tscn"

@onready var _progression: Node = get_node("../progression")
@onready var _player_controller: PlayerController = get_node("../Player/PlayerController") as PlayerController
@onready var _prompts: CanvasLayer = $Prompts
@onready var _message_label: Label = $Prompts/Panel/VBox/Message
@onready var _yes_button: Button = $Prompts/Panel/VBox/Buttons/YesButton
@onready var _level_selection_button: Button = $Prompts/Panel/VBox/Buttons/LevelSelectionButton
@onready var _no_button: Button = $Prompts/Panel/VBox/Buttons/NoButton

# Action run when the player confirms the currently shown prompt with YES.
var _on_confirm: Callable = Callable()
var _prompt_paused_gameplay: bool = false
var _prompt_previously_paused: bool = false
var _prompt_previously_tree_paused: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_prompts.process_mode = Node.PROCESS_MODE_ALWAYS
	_prompts.visible = false
	_yes_button.pressed.connect(_on_yes_pressed)
	_level_selection_button.pressed.connect(_on_level_selection_pressed)
	_no_button.pressed.connect(_on_no_pressed)

	# With save-loading now resolved, place the player on the level's authored
	# "player" spawn marker for a fresh start. A restored save keeps its own
	# player position, so this is a no-op after a load. Still _ready-time, so the
	# player is positioned before the first frame is drawn.
	if _progression.has_method("apply_fresh_start_player_spawn"):
		_progression.call("apply_fresh_start_player_spawn")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return

	# While a prompt is open, ESC cancels it and every other key is swallowed.
	if _prompts.visible:
		get_viewport().set_input_as_handled()
		if key_event.keycode == KEY_ESCAPE:
			_close_prompt()
		return

	match key_event.keycode:
		KEY_R:
			get_viewport().set_input_as_handled()
			_show_prompt("Reset run?\nManual saves are kept.", _confirm_reset)
		KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_show_prompt("Quit game?\nUnsaved progress will be lost.", _confirm_quit, "Return", "Quit", true)


## Show the reusable prompt with `message`; `on_confirm` runs if YES is chosen.
func _show_prompt(
	message: String,
	on_confirm: Callable,
	no_text: String = "NO",
	yes_text: String = "YES",
	show_level_selection: bool = false
) -> void:
	_message_label.text = message
	_on_confirm = on_confirm
	_no_button.text = no_text
	_yes_button.text = yes_text
	_level_selection_button.visible = show_level_selection
	_prompts.visible = true
	_pause_gameplay_for_prompt()
	_no_button.grab_focus()


func _close_prompt() -> void:
	_prompts.visible = false
	_on_confirm = Callable()
	_unpause_gameplay_after_prompt()


func _on_yes_pressed() -> void:
	var action: Callable = _on_confirm
	_close_prompt()
	if action.is_valid():
		action.call()


func _on_no_pressed() -> void:
	_close_prompt()


func _on_level_selection_pressed() -> void:
	_close_prompt()
	GameState.force_level_selection_once()
	GameState.reset_transient_run_state()
	var change_error: Error = get_tree().change_scene_to_file(LEVEL_MENU_SCENE)
	if change_error != OK:
		push_error("Menus: failed to load %s (error %d)" % [LEVEL_MENU_SCENE, int(change_error)])


## YES on the reset prompt: start a brand-new game without touching the manual save.
func _confirm_reset() -> void:
	if _progression.has_method("reset_game"):
		_progression.call("reset_game")


## YES on the quit prompt: quit without writing a save.
func _confirm_quit() -> void:
	get_tree().quit()


func _pause_gameplay_for_prompt() -> void:
	if _player_controller == null:
		_prompt_paused_gameplay = false
		return
	_prompt_previously_paused = _player_controller.is_paused()
	_prompt_previously_tree_paused = get_tree().paused
	_player_controller.push_pause_hold()
	get_tree().paused = true
	_prompt_paused_gameplay = true


func _unpause_gameplay_after_prompt() -> void:
	if not _prompt_paused_gameplay:
		return
	_prompt_paused_gameplay = false
	if _player_controller:
		_player_controller.pop_pause_hold()
	get_tree().paused = _prompt_previously_tree_paused
	if _player_controller:
		if not _prompt_previously_paused:
			_player_controller.set_paused(false)
	_prompt_previously_paused = false
	_prompt_previously_tree_paused = false
