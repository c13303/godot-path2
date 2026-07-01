extends Panel

const SEED_KEY: StringName = &"seeds"
const LEVEL_MENU_SCENE: String = "res://scenes/menus/level_loader.tscn"

const KEY_RESTART: String = "game_over.restart"
const KEY_MAIN_MENU: String = "game_over.main_menu"
const KEY_QUIT: String = "game_over.quit"

@onready var _restart_button: Button = $MarginContainer/Buttons/RestartButton
@onready var _main_menu_button: Button = $MarginContainer/Buttons/MainMenuButton
@onready var _quit_button: Button = $MarginContainer/Buttons/QuitButton

var _plant_manager: Node
var _progression: Node
var _building_manager: Node
var _game_over_shown: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_resolve_nodes()
	_apply_translations()
	if not Translations.locale_changed.is_connected(_on_locale_changed):
		Translations.locale_changed.connect(_on_locale_changed)
	_restart_button.pressed.connect(_on_restart_pressed)
	_main_menu_button.pressed.connect(_on_main_menu_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	visible = false


func _process(_delta: float) -> void:
	if _game_over_shown:
		return
	if _plant_manager == null or _progression == null:
		_resolve_nodes()
	if _is_game_over():
		_show()


func _resolve_nodes() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	_plant_manager = scene.get_node_or_null("Map/PlantManager")
	_progression = scene.get_node_or_null("progression")
	_building_manager = scene.get_node_or_null("Map/BuildingManager")


func _is_game_over() -> bool:
	if _plant_manager == null or _progression == null:
		return false
	# Never end the run while the player is placing the shop (morning) or selling
	# to clients: roses may still be waiting on the counters to convert into seeds.
	if GameState.is_morning_phase or GameState.is_client_phase:
		return false
	var planted: int = int(_plant_manager.call("rose_count"))
	var seeds: int = int(_progression.call("get_value", SEED_KEY))
	var counter_stock: int = 0
	if _building_manager != null and _building_manager.has_method("total_counter_stock"):
		counter_stock = int(_building_manager.call("total_counter_stock"))
	return planted == 0 and seeds == 0 and counter_stock == 0


func _show() -> void:
	_game_over_shown = true
	visible = true
	var modals: Control = get_parent() as Control
	if modals != null:
		for child: Node in modals.get_children():
			var sibling: CanvasItem = child as CanvasItem
			if sibling != null and sibling != self:
				sibling.visible = false
		modals.visible = true
		modals.mouse_filter = Control.MOUSE_FILTER_STOP
	_restart_button.grab_focus()


func _hide() -> void:
	visible = false
	var modals: Control = get_parent() as Control
	if modals != null:
		modals.visible = false
		modals.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _apply_translations() -> void:
	_restart_button.text = Translations.t(KEY_RESTART)
	_main_menu_button.text = Translations.t(KEY_MAIN_MENU)
	_quit_button.text = Translations.t(KEY_QUIT)


func _on_locale_changed(_locale: String) -> void:
	_apply_translations()


func _on_restart_pressed() -> void:
	_hide()
	if _progression != null and _progression.has_method("reset_game"):
		_progression.call("reset_game")
		return
	GameState.skip_startup_autosave_once()
	GameState.set_night(false)
	var reload_error: Error = get_tree().reload_current_scene()
	if reload_error != OK:
		push_error("Game over: failed to restart current level (error %d)" % int(reload_error))


func _on_main_menu_pressed() -> void:
	GameState.set_night(false)
	var change_error: Error = get_tree().change_scene_to_file(LEVEL_MENU_SCENE)
	if change_error != OK:
		push_error("Game over: failed to load %s (error %d)" % [LEVEL_MENU_SCENE, int(change_error)])


func _on_quit_pressed() -> void:
	get_tree().quit()
