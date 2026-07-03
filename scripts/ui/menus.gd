extends Node
## Game-flow / menu controller for the main run scene.
##
## Owns the auto-save lifecycle and the in-scene confirmation prompts:
##   - On launch the latest auto-save is restored.
##   - The plant manager auto-saves once after overnight rose growth completes.
##   - R asks to reset the game (wipe the save and start a fresh new game).
##   - ESC asks to quit without touching the auto-save slot.
##
## The prompt UI is premade and themed in mainRun.tscn under `Prompts`; this
## script only drives its message and YES/NO behaviour. The actual save / load /
## reset work lives in the sibling `progression` node.

@onready var _progression: Node = get_node("../progression")
@onready var _prompts: CanvasLayer = $Prompts
@onready var _message_label: Label = $Prompts/Panel/VBox/Message
@onready var _yes_button: Button = $Prompts/Panel/VBox/Buttons/YesButton
@onready var _no_button: Button = $Prompts/Panel/VBox/Buttons/NoButton

# Action run when the player confirms the currently shown prompt with YES.
var _on_confirm: Callable = Callable()


func _ready() -> void:
	_prompts.visible = false
	_yes_button.pressed.connect(_on_yes_pressed)
	_no_button.pressed.connect(_on_no_pressed)

	# Restore the auto-save into the freshly loaded scene. Runs after the
	# progression node's own _ready, so an F9 pending-load is not applied twice.
	if _progression.has_method("load_on_start"):
		_progression.call("load_on_start")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return

	# While a prompt is open, ESC cancels it and every other key is swallowed.
	if _prompts.visible:
		if key_event.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_close_prompt()
		return

	match key_event.keycode:
		KEY_R:
			get_viewport().set_input_as_handled()
			_show_prompt("Reset game?\nThis erases your save.", _confirm_reset)
		KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_show_prompt("Quit game?\nProgress will be saved.", _confirm_quit)


## Show the reusable prompt with `message`; `on_confirm` runs if YES is chosen.
func _show_prompt(message: String, on_confirm: Callable) -> void:
	_message_label.text = message
	_on_confirm = on_confirm
	_prompts.visible = true
	_no_button.grab_focus()


func _close_prompt() -> void:
	_prompts.visible = false
	_on_confirm = Callable()


func _on_yes_pressed() -> void:
	var action: Callable = _on_confirm
	_close_prompt()
	if action.is_valid():
		action.call()


func _on_no_pressed() -> void:
	_close_prompt()


## YES on the reset prompt: wipe the save and start a brand-new game.
func _confirm_reset() -> void:
	if _progression.has_method("reset_game"):
		_progression.call("reset_game")


## YES on the quit prompt: quit without touching the rose-growth auto-save slot.
func _confirm_quit() -> void:
	get_tree().quit()
