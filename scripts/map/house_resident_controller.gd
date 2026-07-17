extends HouseResidentHandler
class_name HouseResidentController

## Reusable lifecycle for one ordinary one-house/one-resident villager (the seed merchant, the
## future Inventor, ...). It owns everything a normal villager shares:
##   * one resident reconstructed from one completed house (never serialized independently);
##   * first-time walk-in from the shared town entrance and dawn emergence from the house;
##   * association with that house;
##   * night return-home / departure;
##   * house-destruction evacuation toward the shared exit;
##   * repathing after walkability changes;
##   * agent-removal cleanup and duplicate-reconciliation prevention;
##   * canonical resident identity (group + metadata) for generic systems.
##
## It reuses DayVisitorMovementController for all movement (never re-implements pathing) and
## delegates every role-specific side effect (shop phase, dialogs, purchases, ...) to an
## optional HouseResidentRole. No shop/dialog/invention/Builder/tutorial logic lives
## here. One HouseResidentController instance is registered per ordinary resident_type in
## AllyHousingController.
##
## Most villagers walk in once and park at their idle spot for the whole day. A role may instead
## send its villager on daytime errands (see send_on_errand / SheepGardenRole); the night return,
## evacuation and removal stay owned here, so an errand can never outlive the day.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
## Shared authored town entrance / exit markers used by every arriving/leaving villager.
## (Named for the fundamental Builder for historical reasons; they are generic town gates.)
const ENTER_MARKER_ID: StringName = &"fundamental_builder_in"
const EXIT_MARKER_ID: StringName = &"fundamental_builder_out"
const HOUSE_RESIDENTS_GROUP: StringName = &"house_residents"
const IDLE_HOME_CHECK_INTERVAL_SECONDS: float = 0.5
const IDLE_HOME_DISPLACEMENT_GRACE_SECONDS: float = 1.0
const IDLE_HOME_RETRY_COOLDOWN_SECONDS: float = 1.0
const IDLE_HOME_DISPLACEMENT_TILE_FACTOR: float = 0.45

var _manager: BuildingManager = null
var _house_manager: HouseManager = null
var _config: HouseResidentConfig = null
var _visitor: DayVisitorMovementController = DayVisitorMovementController.new()
var _resident_house_id: StringName = &""
var _home_entrance_cell: Vector2i = INVALID_CELL
var _idle_cell: Vector2i = INVALID_CELL
var _has_reached_idle_spot: bool = false
var _returning_home: bool = false
var _evacuating: bool = false
var _idle_home_check_elapsed: float = 0.0
var _idle_displacement_seconds: float = 0.0
var _idle_return_retry_cooldown: float = 0.0
var _idle_return_pending: bool = false
var _interaction_held: bool = false


func setup(manager: BuildingManager, house_manager: HouseManager, config: HouseResidentConfig) -> void:
	_manager = manager
	_house_manager = house_manager
	_config = config
	_visitor.setup(manager, "%s resident" % String(config.resident_type))
	if _config.role != null:
		_config.role.setup(manager)
	if CppDebugOptions.logs_enabled and not _config.is_valid():
		push_warning("HouseResidentController: incomplete config for resident_type '%s'." % String(_config.resident_type))


# ---------------------------------------------------------------------------
# HouseResidentHandler contract.
# ---------------------------------------------------------------------------

func reconcile_houses() -> void:
	if GameState.is_night or _house_manager == null:
		return
	if _visitor.is_active():
		return
	var ids: Array[StringName] = _house_manager.get_completed_normal_resident_house_ids(_config.house_item_id)
	if ids.is_empty():
		return
	var snapshot: HouseManager.HouseSnapshot = _house_manager.get_house_snapshot(ids[0])
	if snapshot == null:
		return
	spawn_for_house(snapshot.id, snapshot.entrance_cell)


func process(_delta: float) -> void:
	if _config.role != null:
		_config.role.process(self, _delta)
	_process_arrival()
	_process_interaction_hold()
	_process_idle_home_correction(_delta)


func process_phase(_delta: float) -> void:
	if _config.role != null:
		_config.role.process_phase(self)


func on_night_started() -> void:
	_set_interaction_hold(false)
	if _config.role != null:
		_config.role.on_night_started(self)
	_evacuating = false
	if _visitor.is_active() and _idle_cell != INVALID_CELL and _visitor.repath_to_target(_idle_cell):
		_returning_home = true
	else:
		_visitor.mark_leave_pending()


func start_pending_departures() -> void:
	_visitor.start_pending_leave_if_needed()


func repath_for_walkability_change() -> void:
	if not _visitor.is_active() or _visitor.is_waiting() or _visitor.is_leaving():
		return
	if not _visitor.repath_to_current_target():
		push_warning("HouseResidentController: %s cannot repath to spot %s after walkability change." % [
			String(_config.resident_type), _visitor.target_cell()])


func on_house_completed(snapshot: HouseManager.HouseSnapshot) -> void:
	if GameState.is_night or snapshot == null or not snapshot.completed:
		return
	if snapshot.resident_type != _config.resident_type:
		return
	# Fundamental-Builder-flagged houses are owned by the specialized Builder handler.
	if snapshot.resident_role != HouseManager.RESIDENT_ROLE_NONE:
		return
	if _visitor.is_active():
		return
	spawn_for_house(snapshot.id, snapshot.entrance_cell)


func on_house_removing(snapshot: HouseManager.HouseSnapshot) -> void:
	if snapshot == null or snapshot.resident_type != _config.resident_type:
		return
	if _resident_house_id == snapshot.id:
		evacuate()
	elif GameState.is_night and snapshot.completed and spawn_for_house(snapshot.id, snapshot.entrance_cell, true):
		evacuate()


func on_agent_removed(agent: Node2D) -> void:
	if not _visitor.owns_agent(agent):
		return
	_set_interaction_hold(false)
	_visitor.forget_agent()
	_reset_state()
	if _config.role != null:
		_config.role.on_cleared()


func owns_agent(agent: Node2D) -> bool:
	return _visitor.owns_agent(agent)


func clear(free_agents: bool) -> void:
	_set_interaction_hold(false)
	_visitor.clear(free_agents)
	_reset_state()
	if _config.role != null:
		_config.role.on_cleared()


# ---------------------------------------------------------------------------
# Spawn / reconcile.
# ---------------------------------------------------------------------------

## Spawns the resident for its house and stamps canonical identity. At dawn the resident emerges
## at the exact idle tile below its own house entrance; a first-time daytime resident still walks
## in from the shared town entrance. Returns false on any failure and refuses to create a duplicate
## while a resident is already active.
func spawn_for_house(house_id: StringName, entrance_cell: Vector2i, for_house_destruction_escape: bool = false) -> bool:
	if (GameState.is_night and not for_house_destruction_escape) or _visitor.is_active():
		return false
	if entrance_cell == INVALID_CELL:
		return false
	var idle_cell: Vector2i = _house_manager.get_resident_idle_cell(entrance_cell)
	if not _manager.is_walkable_cell(idle_cell):
		push_warning("HouseResidentController: %s house idle cell %s is not walkable; resident not spawned." % [
			String(_config.resident_type), idle_cell])
		return false
	var emerges_from_house: bool = GameState.is_dawn_phase or for_house_destruction_escape
	var source_cell: Vector2i = idle_cell if emerges_from_house else _manager.named_authored_spot_cell(ENTER_MARKER_ID)
	if source_cell == INVALID_CELL:
		push_warning("HouseResidentController: %s cannot enter; required marker '%s' is missing." % [
			String(_config.resident_type), String(ENTER_MARKER_ID)])
		return false
	var spawn_cell: Vector2i = idle_cell if emerges_from_house else _manager.find_free_cell_near_spawner(source_cell, _manager.occupied_cells_for_spawning())
	if spawn_cell == INVALID_CELL:
		push_warning("HouseResidentController: %s cannot enter; no free spawn cell near %s." % [
			String(_config.resident_type), str(source_cell)])
		return false
	if not _visitor.spawn(
			source_cell,
			spawn_cell,
			idle_cell,
			_config.agent_kind,
			_config.scene_group,
			_config.tracking_category,
			_config.visual_setup
	):
		return false
	_resident_house_id = house_id
	_home_entrance_cell = entrance_cell
	_idle_cell = idle_cell
	_has_reached_idle_spot = _visitor.is_waiting()
	_returning_home = false
	_evacuating = false
	_stamp_identity()
	if _config.role != null and not for_house_destruction_escape:
		_config.role.on_spawned(self)
	return true


## House was destroyed: walk the resident out through the shared exit (existing escape behavior),
## falling back to an immediate leave when the exit is unreachable.
func evacuate() -> void:
	if not _visitor.is_active():
		clear(false)
		return
	_set_interaction_hold(false)
	if _config.role != null:
		_config.role.on_leaving(self)
	_returning_home = false
	var out_cell: Vector2i = _manager.named_authored_spot_cell(EXIT_MARKER_ID)
	if out_cell != INVALID_CELL and _visitor.repath_to_target(out_cell):
		_evacuating = true
		return
	_evacuating = false
	_visitor.start_leave_for_night()


# ---------------------------------------------------------------------------
# Generic queries (used by roles, interaction, prompts).
# ---------------------------------------------------------------------------

func is_active() -> bool:
	return _visitor.is_active()


func is_leaving() -> bool:
	return _visitor.is_leaving()


## True once the resident has parked at its idle spot (interaction prompt waits for this).
func has_reached_idle_spot() -> bool:
	return _visitor.is_active() and _has_reached_idle_spot


func agent_node() -> Node2D:
	return _visitor.agent_node()


func get_agent_world_position() -> Vector2:
	return _visitor.get_agent_world_position()


func resident_house_id() -> StringName:
	return _resident_house_id


## Canonical role id this controller drives, so generic callers can look it up by resident_type
## (e.g. a villager's dialog/interaction controller reaching its live agent).
func resident_type() -> StringName:
	return _config.resident_type


func is_interaction_held() -> bool:
	return _interaction_held


## The resident's own idle spot below its house, so a role can send it back home after an errand.
func idle_cell() -> Vector2i:
	return _idle_cell


## Tile the resident currently stands on. INVALID_CELL when it has no live agent.
func current_cell() -> Vector2i:
	var agent: Node2D = _visitor.agent_node()
	var floorz: TileMapLayer = _manager.get_floorz()
	if agent == null or floorz == null:
		return INVALID_CELL
	return floorz.local_to_map(floorz.to_local(agent.global_position))


# ---------------------------------------------------------------------------
# Role-driven errands.
# ---------------------------------------------------------------------------

## Sends the resident to `destination_cell` along a role-supplied path, for the roles whose villager
## works away from its idle spot instead of parking there all day. The path comes from the role
## because the routing rule is role-specific (the sheep refuses live-plant cells, see
## BuildingManager.find_sheep_path); this controller never starts an errand of its own. The role is
## told the walk finished through on_reached_spot(). Refused once the resident is leaving,
## evacuating or heading home for the night, so an errand can never fight the shared lifecycle.
func send_on_errand(destination_cell: Vector2i, path_cells: PackedVector2Array) -> bool:
	if GameState.is_night or _returning_home or _evacuating:
		return false
	if not _visitor.is_active() or _visitor.is_leaving():
		return false
	return _visitor.assign_cell_path(destination_cell, path_cells)


## True while the resident stands still (parked at its idle spot or wherever an errand ended),
## i.e. it is not currently walking anywhere.
func is_parked() -> bool:
	return _visitor.is_waiting()


## Generic Chebyshev-distance proximity test in tile space between the player and this resident.
func is_player_near(radius_tiles: int) -> bool:
	var agent: Node2D = _visitor.agent_node()
	if agent == null:
		return false
	var player: Node2D = _manager.get_tree().get_first_node_in_group("player") as Node2D
	var floorz: TileMapLayer = _manager.get_floorz()
	if player == null or floorz == null:
		return false
	var player_cell: Vector2i = floorz.local_to_map(floorz.to_local(player.global_position))
	var resident_cell: Vector2i = floorz.local_to_map(floorz.to_local(agent.global_position))
	var delta: Vector2i = player_cell - resident_cell
	return abs(delta.x) <= radius_tiles and abs(delta.y) <= radius_tiles


# ---------------------------------------------------------------------------
# Internals.
# ---------------------------------------------------------------------------

func _process_arrival() -> void:
	# Only the walk-in toward the house uses the A* path; while returning home or evacuating the
	# arrival at the destination retires the resident.
	if not _visitor.is_active():
		return
	if not _visitor.process_arrival():
		return
	if _returning_home or _evacuating:
		clear(true)
		return
	# Latched on the first arrival and never cleared by a later errand: it means "has settled in
	# town", which is what the interaction prompt and the movement hold wait for. A villager out
	# on an errand is still someone you can walk up to and talk to.
	_has_reached_idle_spot = true
	_clear_idle_return_state()
	if _config.role != null:
		_config.role.on_reached_spot(self)


func _process_idle_home_correction(delta: float) -> void:
	if delta <= 0.0 or GameState.is_night:
		return
	if not _eligible_for_idle_home_correction():
		_clear_idle_return_state()
		return
	_idle_home_check_elapsed += delta
	if _idle_home_check_elapsed < IDLE_HOME_CHECK_INTERVAL_SECONDS:
		return
	var elapsed: float = _idle_home_check_elapsed
	_idle_home_check_elapsed = 0.0
	if _idle_return_retry_cooldown > 0.0:
		_idle_return_retry_cooldown = maxf(0.0, _idle_return_retry_cooldown - elapsed)
		return
	if _idle_return_pending:
		_request_idle_home_return()
		return
	if not _is_idle_resident_meaningfully_displaced():
		_idle_displacement_seconds = 0.0
		return
	_idle_displacement_seconds += elapsed
	if _idle_displacement_seconds >= IDLE_HOME_DISPLACEMENT_GRACE_SECONDS:
		_request_idle_home_return()


func _eligible_for_idle_home_correction() -> bool:
	if _returning_home or _evacuating:
		return false
	if _idle_cell == INVALID_CELL:
		return false
	# A role-driven errand parks the villager away from its idle spot on purpose, so correcting it
	# home would fight the role. The role owns bringing its villager back; the night return below
	# brings it home either way.
	if _visitor.target_cell() != _idle_cell:
		return false
	if not _visitor.is_active() or _visitor.is_leaving() or not _visitor.is_waiting():
		return false
	return true


func _is_idle_resident_meaningfully_displaced() -> bool:
	if _visitor.target_cell() == INVALID_CELL:
		return false
	var tile_size: Vector2 = _manager.tile_size()
	var threshold: float = maxf(tile_size.x, tile_size.y) * IDLE_HOME_DISPLACEMENT_TILE_FACTOR
	return _visitor.get_agent_world_position().distance_to(_visitor.target_world_position()) > threshold


func _request_idle_home_return() -> void:
	_idle_displacement_seconds = 0.0
	if _visitor.repath_to_target(_idle_cell):
		_clear_idle_return_state()
		return
	_idle_return_pending = true
	_idle_return_retry_cooldown = IDLE_HOME_RETRY_COOLDOWN_SECONDS


func _clear_idle_return_state() -> void:
	_idle_displacement_seconds = 0.0
	_idle_return_retry_cooldown = 0.0
	_idle_return_pending = false


func _process_interaction_hold() -> void:
	if _config.interaction_hold_radius_tiles <= 0:
		_set_interaction_hold(false)
		return
	if not _visitor.is_active() or GameState.is_night or _visitor.is_leaving() or _evacuating or _returning_home:
		_set_interaction_hold(false)
		return
	if not _interaction_held and not has_reached_idle_spot():
		_set_interaction_hold(false)
		return
	_set_interaction_hold(is_player_near(_config.interaction_hold_radius_tiles))


func _set_interaction_hold(value: bool) -> void:
	if _interaction_held == value:
		return
	_interaction_held = value
	_visitor.set_autonomous_paused(value)


## Canonical house-resident identity so generic systems can tell an agent is house-owned, which
## house owns it, its role, that it is reconstructed (not serialized), and how to evacuate it.
func _stamp_identity() -> void:
	var agent: Node2D = _visitor.agent_node()
	if agent == null:
		return
	agent.add_to_group(HOUSE_RESIDENTS_GROUP)
	agent.set_meta("resident_type", _config.resident_type)
	agent.set_meta("resident_house_id", _resident_house_id)
	agent.set_meta("home_entrance_cell", _home_entrance_cell)
	agent.set_meta("resident_idle_cell", _idle_cell)


func _reset_state() -> void:
	_interaction_held = false
	_resident_house_id = &""
	_home_entrance_cell = INVALID_CELL
	_idle_cell = INVALID_CELL
	_has_reached_idle_spot = false
	_returning_home = false
	_evacuating = false
	_idle_home_check_elapsed = 0.0
	_clear_idle_return_state()
