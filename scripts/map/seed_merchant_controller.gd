extends RefCounted
class_name SeedMerchantController

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"
const MERCHANT_GROUP: StringName = &"merchants"
const INTERACT_RADIUS_TILES: int = 2

var _manager: BuildingManager
var _visitor: DayVisitorMovementController = DayVisitorMovementController.new()
# True while the merchant is frozen because the player is within interaction range.
# Mirrors the native per-agent pause; cleared when the player walks away.
var _paused: bool = false


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_visitor.setup(manager, "seed merchant")


func on_night_started() -> void:
	_visitor.mark_leave_pending()
	GameState.set_seed_merchant_phase(false)


func start_pending_leave_if_needed() -> void:
	_visitor.start_pending_leave_if_needed()


func is_active() -> bool:
	return _visitor.is_active()


func begin_phase(merchant_spawners: Dictionary) -> void:
	clear_phase(false)
	if GameState.is_night:
		return
	if merchant_spawners.is_empty():
		push_warning("BuildingManager: seed merchant phase skipped; no seedmerchent spawner node was registered.")
		return
	var merchant_cells: Array[Vector2i] = []
	for raw_cell: Variant in merchant_spawners.keys():
		merchant_cells.append(raw_cell as Vector2i)
	if merchant_cells.is_empty():
		push_warning("BuildingManager: seed merchant phase skipped; no usable seedmerchent spawner cell was registered.")
		return
	var spawner_cell: Vector2i = merchant_cells[randi_range(0, merchant_cells.size() - 1)]
	if not _spawn_from(spawner_cell):
		return
	GameState.set_seed_merchant_phase(true)


func process_arrival() -> void:
	# Only the walk-in toward the authored spot uses the A* path; while leaving
	# (escape flow) or already parked at the spot there is nothing to arrive at here.
	if not _visitor.is_active():
		return
	_visitor.process_arrival()


func process_phase() -> void:
	if not _visitor.is_active():
		return
	# The client sale can finish before the player has watered every rose. When that
	# happens client sale does NOT start the night and the merchant lingers. Re-check
	# here so finishing the watering afterwards still ends the day.
	if GameState.is_afternoon_phase and _manager.can_start_night_after_clients():
		_manager.request_night_after_clients()
		return
	if GameState.is_seed_merchant_phase and GameState.seed_merchant_purchase_made and not is_player_near():
		GameState.set_seed_merchant_phase(false)


func process_proximity() -> void:
	# Once the merchant is leaving it must never re-pause: night has already started,
	# and walking back into the departing merchant should not freeze it.
	if not _visitor.is_active() or _visitor.is_leaving():
		return
	var near: bool = is_player_near()
	if near and not GameState.is_night and not GameState.is_seed_merchant_phase:
		GameState.set_seed_merchant_phase(true)
	# Keep walking to the authored spot even when the player is close; the merchant only
	# freezes for the player once it has parked (_waiting). The player can still open the
	# shop with the interact button during the walk-in.
	if not _visitor.is_waiting():
		return
	if near == _paused:
		return
	_set_paused(near)


func repath_for_walkability_change() -> void:
	if not _visitor.is_active() or _visitor.is_waiting() or _visitor.is_leaving():
		return
	if not _visitor.repath_to_current_target():
		push_warning("BuildingManager: seed merchant cannot repath to spot %s after walkability change." % _visitor.target_cell())


func is_player_near() -> bool:
	var agent: Node2D = _visitor.agent_node()
	if agent == null:
		return false
	var player: Node2D = _manager.get_tree().get_first_node_in_group("player") as Node2D
	var floorz: TileMapLayer = _floorz()
	if player == null or floorz == null:
		return false
	var player_cell: Vector2i = floorz.local_to_map(floorz.to_local(player.global_position))
	var merchant_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var delta: Vector2i = player_cell - merchant_cell
	return abs(delta.x) <= INTERACT_RADIUS_TILES and abs(delta.y) <= INTERACT_RADIUS_TILES


func is_paused_agent(agent: Node2D) -> bool:
	return _visitor.owns_agent(agent) and _paused


## True once the merchant has finished walking in and is parked at its authored idle spot.
## The interaction prompt only appears after this point; before it, the merchant keeps
## moving (and can still be interacted with via the interact button).
func has_reached_idle_spot() -> bool:
	return _visitor.is_waiting()


## World position of the merchant sprite, or Vector2.ZERO when none is spawned. The
## interaction prompt anchors above this point.
func get_agent_world_position() -> Vector2:
	return _visitor.get_agent_world_position()


func request_leave() -> void:
	if not _visitor.is_active():
		end_phase()
		return
	if not GameState.is_night:
		GameState.set_seed_merchant_phase(false)
		return
	start_leave_for_night()


func start_leave_for_night() -> void:
	if not _visitor.is_active():
		GameState.set_seed_merchant_phase(false)
		return
	if GameState.is_night and not _manager.is_night_preparation_ready():
		_visitor.mark_leave_pending()
		GameState.set_seed_merchant_phase(false)
		return
	# Unfreeze first so the merchant can actually walk out if the player paused it.
	if _paused:
		_set_paused(false)
	GameState.set_seed_merchant_phase(false)
	_visitor.start_leave_for_night()


func clear_phase(free_agent: bool) -> void:
	_visitor.clear(free_agent)
	_paused = false
	GameState.set_seed_merchant_phase(false)


func end_phase() -> void:
	clear_phase(false)


func on_agent_removed(agent: Node2D) -> void:
	if not _visitor.owns_agent(agent):
		return
	_visitor.forget_agent()
	_paused = false
	GameState.set_seed_merchant_phase(false)


func _spawn_from(spawner_cell: Vector2i) -> bool:
	var occupied: Array[Vector2i] = _manager.occupied_cells_for_spawning()
	var spawn_cell: Vector2i = _manager.find_free_cell_near_spawner(spawner_cell, occupied)
	if spawn_cell == INVALID_CELL:
		return false
	var target_cell: Vector2i = _manager.seed_merchant_spot_cell(spawner_cell)
	if target_cell == INVALID_CELL:
		push_warning("BuildingManager: seed merchant spawner %s has no authored spot child; merchant not spawned." % spawner_cell)
		return false
	if not _manager.is_walkable_cell(target_cell):
		push_warning("BuildingManager: seed merchant spot %s is not walkable; merchant not spawned." % target_cell)
		return false
	_paused = false
	return _visitor.spawn(
		spawner_cell,
		spawn_cell,
		target_cell,
		SPAWNER_KIND_MERCHANT,
		MERCHANT_GROUP,
		MERCHANT_GROUP,
		Callable(_manager, "apply_merchant_data")
	)


func _set_paused(value: bool) -> void:
	_paused = value
	var agent_manager: Node = _agent_manager()
	var agent: Node2D = _visitor.agent_node()
	var nav_id: int = int(agent.get("nav_id")) if agent != null else -1
	if nav_id >= 0 and agent_manager != null and agent_manager.has_method("set_agent_paused"):
		agent_manager.call("set_agent_paused", nav_id, value)


func _agent_manager() -> Node:
	return _manager.get_agent_manager() if _manager != null else null


func _floorz() -> TileMapLayer:
	return _manager.get_floorz() if _manager != null else null


func _parent_for_agents() -> Node:
	return _manager.get_parent_for_agents() if _manager != null else null
