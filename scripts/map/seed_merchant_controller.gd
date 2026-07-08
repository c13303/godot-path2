extends RefCounted
class_name SeedMerchantController

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const MERCHANT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/merchent.png")
const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const SPAWNER_KIND_MERCHANT: StringName = &"merchant"
const INTERACT_RADIUS_TILES: int = 2

var _manager: BuildingManager
var _active: bool = false
var _agent: Node2D
var _nav_id: int = -1
var _target_cell: Vector2i = INVALID_CELL
var _waiting: bool = false
# True once the merchant is walking back out to an exit. This only happens when
# night starts; finishing a merchant visit keeps the sprite parked until nightfall.
var _leaving: bool = false
var _leave_at_night_pending: bool = false
# True while the merchant is frozen because the player is within interaction range.
# Mirrors the native per-agent pause; cleared when the player walks away.
var _paused: bool = false


func setup(manager: BuildingManager) -> void:
	_manager = manager


func on_night_started() -> void:
	_leave_at_night_pending = _active and is_instance_valid(_agent)
	GameState.set_seed_merchant_phase(false)


func start_pending_leave_if_needed() -> void:
	if _leave_at_night_pending:
		start_leave_for_night()


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
	_active = true
	GameState.set_seed_merchant_phase(true)


func process_arrival() -> void:
	# Only the walk-in toward the authored spot uses the A* path; while leaving
	# (escape flow) or already parked at the spot there is nothing to arrive at here.
	if not _active or _waiting or _leaving:
		return
	if not is_instance_valid(_agent):
		end_phase()
		return
	var agent_manager: Node = _agent_manager()
	if _nav_id < 0 or not (agent_manager != null and agent_manager.has_method("agent_path_arrived")):
		return
	if not bool(agent_manager.call("agent_path_arrived", _nav_id)):
		return
	if agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", _nav_id)
	if _agent.has_method("stop_astar_in"):
		_agent.call("stop_astar_in")
	_waiting = true


func process_phase() -> void:
	if not _active:
		return
	if not is_instance_valid(_agent):
		end_phase()
		return
	# The client sale can finish before the player has watered every rose. When that
	# happens client sale does NOT start the night and the merchant lingers. Re-check
	# here so finishing the watering afterwards still ends the day.
	if not GameState.is_night and not GameState.is_morning_phase and _manager.can_start_night_after_clients():
		_manager.start_night_after_clients()
		return
	if GameState.is_seed_merchant_phase and GameState.seed_merchant_purchase_made and not is_player_near():
		GameState.set_seed_merchant_phase(false)
		if not _manager.is_client_sale_active() and not GameState.is_client_phase and not GameState.is_morning_phase:
			GameState.set_building_phase(true)


func process_proximity() -> void:
	# Once the merchant is leaving it must never re-pause: night has already started,
	# and walking back into the departing merchant should not freeze it.
	if not _active or _leaving or not is_instance_valid(_agent):
		return
	var near: bool = is_player_near()
	if near and not GameState.is_night and not GameState.is_seed_merchant_phase:
		GameState.set_building_phase(false)
		GameState.set_seed_merchant_phase(true)
	if near == _paused:
		return
	_set_paused(near)


func is_player_near() -> bool:
	if not _active or not is_instance_valid(_agent):
		return false
	var player: Node2D = _manager.get_tree().get_first_node_in_group("player") as Node2D
	var floorz: TileMapLayer = _floorz()
	if player == null or floorz == null:
		return false
	var player_cell: Vector2i = floorz.local_to_map(floorz.to_local(player.global_position))
	var merchant_cell: Vector2i = floorz.local_to_map(floorz.to_local(_agent.global_position))
	var delta: Vector2i = player_cell - merchant_cell
	return abs(delta.x) <= INTERACT_RADIUS_TILES and abs(delta.y) <= INTERACT_RADIUS_TILES


func is_paused_agent(agent: Node2D) -> bool:
	return agent == _agent and _paused


func request_leave() -> void:
	if not _active or not is_instance_valid(_agent):
		end_phase()
		return
	if not GameState.is_night:
		GameState.set_seed_merchant_phase(false)
		if not GameState.is_morning_phase and not GameState.is_client_phase:
			GameState.set_building_phase(true)
		return
	start_leave_for_night()


func start_leave_for_night() -> void:
	if not _active:
		_leave_at_night_pending = false
		GameState.set_seed_merchant_phase(false)
		return
	if not is_instance_valid(_agent):
		_leave_at_night_pending = false
		clear_phase(false)
		return
	if GameState.is_night and not _manager.is_night_preparation_ready():
		_leave_at_night_pending = true
		GameState.set_seed_merchant_phase(false)
		return
	_leave_at_night_pending = false
	# Unfreeze first so the merchant can actually walk out if the player paused it.
	if _paused:
		_set_paused(false)
	_leaving = true
	_waiting = false
	GameState.set_seed_merchant_phase(false)
	if not _manager.assign_agent_to_escape(_agent):
		_manager.remove_dead_monster(_agent, false)


func clear_phase(free_agent: bool) -> void:
	if free_agent and is_instance_valid(_agent):
		_manager.remove_dead_monster(_agent, false)
	_reset_state()
	GameState.set_seed_merchant_phase(false)


func end_phase() -> void:
	clear_phase(false)
	if not GameState.is_morning_phase and not GameState.is_client_phase:
		GameState.set_building_phase(true)


func on_agent_removed(agent: Node2D) -> void:
	if agent != _agent:
		return
	_reset_state()
	GameState.set_seed_merchant_phase(false)
	if not GameState.is_night and not GameState.is_morning_phase and not GameState.is_client_phase:
		GameState.set_building_phase(true)


func _spawn_from(spawner_cell: Vector2i) -> bool:
	var agent_manager: Node = _agent_manager()
	if agent_manager == null or not agent_manager.has_method("spawn_agent") or not agent_manager.has_method("assign_agent_path"):
		return false
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
	var path_cells: PackedVector2Array = _manager.find_path_on_walkable_map(spawn_cell, target_cell)
	if path_cells.is_empty():
		push_warning("BuildingManager: seed merchant cannot path from %s to spot %s." % [spawn_cell, target_cell])
		return false
	var agent: Node2D = AGENT_SCENE.instantiate() as Node2D
	var configured_parent: Node = _parent_for_agents()
	var parent: Node = configured_parent if configured_parent != null else _manager.get_tree().current_scene
	if parent == null:
		agent.queue_free()
		return false
	parent.add_child(agent)
	agent.global_position = _manager.cell_center(spawn_cell)
	agent.z_index = int(agent.global_position.y)
	agent.add_to_group("merchants")
	_manager.register_desire_agent(agent, &"merchants")
	agent.set_meta("agent_kind", SPAWNER_KIND_MERCHANT)
	agent.set_meta("spawner_cell", spawner_cell)
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = MERCHANT_TEXTURE
	var nav_id: int = int(agent_manager.call("spawn_agent", agent, IDLE_GROUP))
	agent.set("nav_id", nav_id)
	if agent_manager.has_method("set_agent_never_rest"):
		agent_manager.call("set_agent_never_rest", nav_id, true)
	var path_world: PackedVector2Array = _manager.path_cells_to_world(path_cells, nav_id, true)
	agent_manager.call("assign_agent_path", nav_id, path_world)
	_agent = agent
	_nav_id = nav_id
	_target_cell = target_cell
	_waiting = false
	_leaving = false
	_paused = false
	if agent.has_method("start_astar_in"):
		agent.call("start_astar_in")
	return true


func _set_paused(value: bool) -> void:
	_paused = value
	var agent_manager: Node = _agent_manager()
	if _nav_id >= 0 and agent_manager != null and agent_manager.has_method("set_agent_paused"):
		agent_manager.call("set_agent_paused", _nav_id, value)


func _reset_state() -> void:
	_active = false
	_agent = null
	_nav_id = -1
	_target_cell = INVALID_CELL
	_waiting = false
	_leaving = false
	_leave_at_night_pending = false
	_paused = false


func _agent_manager() -> Node:
	return _manager.get_agent_manager() if _manager != null else null


func _floorz() -> TileMapLayer:
	return _manager.get_floorz() if _manager != null else null


func _parent_for_agents() -> Node:
	return _manager.get_parent_for_agents() if _manager != null else null
