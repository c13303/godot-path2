extends RefCounted
class_name DawnHarvestController

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const PLAYER_HARVEST_RADIUS_TILES: int = 1
const IMPERIAL_ROSE_ITEM_ID: String = "imperial_rose"
const ADD_COUNTERS_TUTORIAL_KEY: String = "tutorial.add_counters_to_sell_roses"

var _manager: BuildingManager
var _active: bool = false
var _counter_room_alert_cell: Vector2i = INVALID_CELL


func setup(manager: BuildingManager) -> void:
	_manager = manager


func clear_active() -> void:
	_active = false
	_counter_room_alert_cell = INVALID_CELL


func is_active() -> bool:
	return _active


func on_counter_capacity_added() -> void:
	if _active:
		return
	if not GameState.is_dawn_phase and not GameState.is_client_phase:
		return
	if _manager.grownup_rose_count() <= 0:
		return
	if not _manager.has_counter_room_for_harvest():
		return
	_active = true


## Keep grown roses collectable after the player starts the client sale early. The
## controller must stay awake even while every counter is full: clients can free a
## slot later, and walkover harvesting should resume without another lifecycle event.
func on_client_sale_started() -> void:
	if GameState.is_night:
		return
	_active = _manager.grownup_rose_count() > 0


func begin_phase() -> void:
	_manager.reset_client_state_for_dawn()
	var has_grownup_roses: bool = _manager.grownup_rose_count() > 0
	var plant_manager: Node = _plant_manager()
	var has_pending_imperial_growth: bool = (
		plant_manager != null
		and plant_manager.has_method("has_pending_imperial_growth")
		and bool(plant_manager.call("has_pending_imperial_growth"))
	)
	var has_harvestable_imperials: bool = _harvestable_imperial_count() > 0
	_active = false
	if not has_grownup_roses and not has_pending_imperial_growth and not has_harvestable_imperials:
		_manager.request_client_sale_start()
		return
	if plant_manager != null and plant_manager.has_method("bloom_grownup_roses"):
		await plant_manager.call("bloom_grownup_roses")
	if GameState.is_night:
		return
	var harvestable_imperials: int = _harvestable_imperial_count()
	if _manager.grownup_rose_count() <= 0 and harvestable_imperials <= 0:
		_manager.request_client_sale_start()
		return
	_active = true
	if _manager.grownup_rose_count() > 0 and harvestable_imperials <= 0 and not _manager.has_counter_room_for_harvest() and not _manager.can_install_new_counter():
		if _manager.rose_shop_counter_count() <= 0:
			_manager.auto_select_hammer()
			return
		_active = false
		_manager.request_client_sale_start()
		return
	if _manager.grownup_rose_count() > 0 and not _manager.has_counter_room_for_harvest():
		_manager.auto_select_hammer()


func process_walkover() -> void:
	if not _active:
		return
	var plant_manager: Node = _plant_manager()
	if plant_manager == null:
		return
	var harvest_cell: Vector2i = _player_harvestable_plant_cell(GameState.is_client_phase)
	if harvest_cell == INVALID_CELL:
		_show_counter_room_alert_if_blocked(plant_manager)
		return
	_counter_room_alert_cell = INVALID_CELL
	if plant_manager.has_method("is_imperial_harvestable") and bool(plant_manager.call("is_imperial_harvestable", harvest_cell)):
		_harvest_imperial_rose(plant_manager, harvest_cell)
		return
	_harvest_grownup_rose(plant_manager, harvest_cell)


func has_grownup_roses_to_harvest() -> bool:
	return _active and (_manager.grownup_rose_count() > 0 or _harvestable_imperial_count() > 0)


func check_finished() -> void:
	if _manager.grownup_rose_count() > 0:
		# During the sale, full counters are temporary capacity rather than the end of
		# the harvest window. A client may consume stock on any later frame.
		if GameState.is_client_phase:
			_active = true
			return
		if not _manager.has_counter_room_for_harvest() and not _manager.can_install_new_counter():
			if _manager.rose_shop_counter_count() <= 0:
				return
			if _harvestable_imperial_count() > 0:
				return
			_active = false
			_manager.request_client_sale_start()
		return
	if GameState.is_client_phase:
		# Starting clients early still ends imperial-rose collection, as before this
		# controller learned to keep only regular grown roses active during the sale.
		_active = false
		return
	if _harvestable_imperial_count() > 0:
		return
	_active = false
	_manager.request_client_sale_start()


func _harvest_grownup_rose(plant_manager: Node, rose_cell: Vector2i) -> void:
	if not plant_manager.has_method("harvest_grownup_rose"):
		return
	var counter_cells: Array[Vector2i] = _manager.rose_shop_counter_cells_with_room()
	if counter_cells.is_empty():
		return
	var target_counter: Vector2i = counter_cells[randi_range(0, counter_cells.size() - 1)]
	var rose_world: Vector2 = _manager.cell_center(rose_cell)
	if not bool(plant_manager.call("harvest_grownup_rose", rose_cell)):
		return
	_manager.add_counter_stock(target_counter, 1)
	_manager.animate_harvested_rose_to_counter(rose_world, target_counter)
	_manager.auto_save_after_rose_harvest()
	check_finished()


func _harvest_imperial_rose(plant_manager: Node, imperial_cell: Vector2i) -> void:
	if not plant_manager.has_method("harvest_imperial_rose"):
		return
	var imperial_world: Vector2 = _manager.cell_center(imperial_cell)
	var game_ui: Node = _game_ui()
	if game_ui == null or not game_ui.has_method("can_add_inventory") or not game_ui.has_method("collect_inventory_item_from_world"):
		return
	if not bool(game_ui.call("can_add_inventory", IMPERIAL_ROSE_ITEM_ID, 1)):
		return
	if not bool(plant_manager.call("harvest_imperial_rose", imperial_cell)):
		return
	game_ui.call("collect_inventory_item_from_world", IMPERIAL_ROSE_ITEM_ID, imperial_world, 1)
	check_finished()


func _player_harvestable_plant_cell(roses_only: bool = false) -> Vector2i:
	var floorz: TileMapLayer = _floorz()
	var player: Node2D = _manager.get_tree().get_first_node_in_group("player") as Node2D
	if player == null or floorz == null:
		return INVALID_CELL
	var plant_manager: Node = _plant_manager()
	if plant_manager == null:
		return INVALID_CELL
	var player_cell: Vector2i = floorz.local_to_map(floorz.to_local(player.global_position))
	if _is_harvestable_plant_cell(plant_manager, player_cell, roses_only):
		return player_cell
	for dy: int in range(-PLAYER_HARVEST_RADIUS_TILES, PLAYER_HARVEST_RADIUS_TILES + 1):
		for dx: int in range(-PLAYER_HARVEST_RADIUS_TILES, PLAYER_HARVEST_RADIUS_TILES + 1):
			if dx == 0 and dy == 0:
				continue
			var cell: Vector2i = player_cell + Vector2i(dx, dy)
			if _is_harvestable_plant_cell(plant_manager, cell, roses_only):
				return cell
	return INVALID_CELL


func _is_harvestable_plant_cell(plant_manager: Node, cell: Vector2i, roses_only: bool = false) -> bool:
	if plant_manager.has_method("is_rose_grownup") and bool(plant_manager.call("is_rose_grownup", cell)):
		return _manager.has_counter_room_for_harvest()
	if roses_only:
		return false
	if plant_manager.has_method("is_imperial_harvestable") and bool(plant_manager.call("is_imperial_harvestable", cell)):
		return true
	return false


func _show_counter_room_alert_if_blocked(plant_manager: Node) -> void:
	if _manager.has_counter_room_for_harvest():
		_counter_room_alert_cell = INVALID_CELL
		return
	if _manager.rose_shop_counter_count() <= 0:
		_counter_room_alert_cell = INVALID_CELL
		return
	var rose_cell: Vector2i = _player_grownup_rose_cell(plant_manager)
	if rose_cell == INVALID_CELL:
		_counter_room_alert_cell = INVALID_CELL
		return
	if rose_cell == _counter_room_alert_cell:
		return
	_counter_room_alert_cell = rose_cell
	_manager.show_tutorial_alert(ADD_COUNTERS_TUTORIAL_KEY)


func _player_grownup_rose_cell(plant_manager: Node) -> Vector2i:
	var floorz: TileMapLayer = _floorz()
	var player: Node2D = _manager.get_tree().get_first_node_in_group("player") as Node2D
	if player == null or floorz == null:
		return INVALID_CELL
	if not plant_manager.has_method("is_rose_grownup"):
		return INVALID_CELL
	var player_cell: Vector2i = floorz.local_to_map(floorz.to_local(player.global_position))
	if bool(plant_manager.call("is_rose_grownup", player_cell)):
		return player_cell
	for dy: int in range(-PLAYER_HARVEST_RADIUS_TILES, PLAYER_HARVEST_RADIUS_TILES + 1):
		for dx: int in range(-PLAYER_HARVEST_RADIUS_TILES, PLAYER_HARVEST_RADIUS_TILES + 1):
			if dx == 0 and dy == 0:
				continue
			var cell: Vector2i = player_cell + Vector2i(dx, dy)
			if bool(plant_manager.call("is_rose_grownup", cell)):
				return cell
	return INVALID_CELL


func _harvestable_imperial_count() -> int:
	var plant_manager: Node = _plant_manager()
	if plant_manager == null or not plant_manager.has_method("harvestable_imperial_count"):
		return 0
	return int(plant_manager.call("harvestable_imperial_count"))


func _game_ui() -> Node:
	var scene: Node = _manager.get_tree().current_scene if _manager != null else null
	return scene.get_node_or_null("GameUI") if scene != null else null


func _plant_manager() -> Node:
	return _manager.get_plant_manager() if _manager != null else null


func _floorz() -> TileMapLayer:
	return _manager.get_floorz() if _manager != null else null
