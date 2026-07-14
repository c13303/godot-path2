extends Node2D
class_name KrakenSystem

const KRAKEN_ITEM_ID: String = "kraken"
const CATEGORY_MONSTERS: StringName = &"monsters"
const STATE_READY: StringName = &"ready"
const STATE_EXTENDING: StringName = &"extending"
const STATE_RETRACTING: StringName = &"retracting"
const STATE_EATING: StringName = &"eating"
const STATE_DIGESTING: StringName = &"digesting"
const RANGE_CANCEL_TOLERANCE: float = 1.25

var _fight_system: FightSystem
var _building_objects: BuildingObjectManager
var _building_manager: BuildingManager
var _krakens: Dictionary = {}
var _reserved_target_ids: Dictionary = {}


func _ready() -> void:
	_fight_system = get_parent() as FightSystem
	_building_objects = get_node_or_null("../../Map/BuildingObjectManager") as BuildingObjectManager
	_building_manager = get_node_or_null("../../Map/BuildingManager") as BuildingManager
	if _fight_system == null or _building_objects == null or _building_manager == null:
		push_error("KrakenSystem: required gameplay owners are missing.")
		set_process(false)
		return
	_building_objects.building_added.connect(_on_building_added)
	_building_objects.building_removed.connect(_on_building_removed)
	for cell: Vector2i in _building_objects.get_building_cells():
		var building: Dictionary = _building_objects.get_building(cell)
		if str(building.get("item_id", "")) == KRAKEN_ITEM_ID:
			_register_kraken(cell)


func _exit_tree() -> void:
	var cells: Array = _krakens.keys()
	for raw_cell: Variant in cells:
		_cancel_and_remove(raw_cell as Vector2i)


func _process(delta: float) -> void:
	var paused: bool = _fight_system != null and _fight_system.has_method("is_paused") and bool(_fight_system.call("is_paused"))
	for raw_cell: Variant in _krakens.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var state: Dictionary = _krakens[cell] as Dictionary
		var visual: KrakenVisual = _visual_from_state(state)
		if visual == null:
			_cancel_and_remove(cell)
			continue
		visual.set_animation_paused(paused)
		if paused:
			continue
		var kraken_state: StringName = state.get("state", STATE_READY) as StringName
		if kraken_state == STATE_READY:
			_process_ready(cell, state, delta)
		elif kraken_state == STATE_EXTENDING:
			_process_extending(cell, state)
		elif kraken_state == STATE_RETRACTING:
			_pin_target_to_tip(state)
		elif kraken_state == STATE_EATING:
			_pin_target_to_capture_anchor(state)
		_krakens[cell] = state


func _on_building_added(cell: Vector2i, item_id: String) -> void:
	if item_id == KRAKEN_ITEM_ID:
		_register_kraken(cell)


func _on_building_removed(cell: Vector2i, item_id: String) -> void:
	if item_id == KRAKEN_ITEM_ID:
		_cancel_and_remove(cell)


func _register_kraken(cell: Vector2i) -> void:
	if _krakens.has(cell):
		return
	var item_def: Dictionary = ItemCatalog.get_item_def(KRAKEN_ITEM_ID)
	var data: KrakenData = item_def.get("kraken_data", null) as KrakenData
	if data == null:
		push_warning("KrakenSystem: missing KrakenData.")
		return
	var visual: KrakenVisual = _building_objects.get_runtime_node(cell) as KrakenVisual
	if visual == null:
		return
	visual.maximum_grab_reach = data.capture_range
	visual.eating_duration = 3.0
	visual.reset_to_idle()
	visual.grab_contacted.connect(_on_grab_contacted.bind(cell))
	visual.grab_retract_finished.connect(_on_grab_retract_finished.bind(cell))
	visual.eating_finished.connect(_on_eating_finished.bind(cell))
	visual.digestion_finished.connect(_on_digestion_finished.bind(cell))
	_krakens[cell] = {
		"cell": cell,
		"visual": weakref(visual),
		"data": data,
		"state": STATE_READY,
		"target": null,
		"target_nav_id": -1,
		"resume_state": {},
		"scan_timer": _initial_scan_offset(cell, data.target_scan_interval),
		"captured": false,
	}


func _process_ready(cell: Vector2i, state: Dictionary, delta: float) -> void:
	var data: KrakenData = state.get("data", null) as KrakenData
	if data == null:
		return
	var scan_timer: float = float(state.get("scan_timer", 0.0)) - delta
	if scan_timer > 0.0:
		state["scan_timer"] = scan_timer
		return
	state["scan_timer"] = maxf(0.02, data.target_scan_interval)
	var target: Node2D = _nearest_eligible_target(cell, data.capture_range)
	if target == null:
		return
	var visual: KrakenVisual = _visual_from_state(state)
	if visual == null:
		return
	var target_id: int = target.get_instance_id()
	_reserved_target_ids[target_id] = cell
	state["state"] = STATE_EXTENDING
	state["target"] = weakref(target)
	state["target_nav_id"] = int(target.get("nav_id"))
	state["captured"] = false
	visual.play_grab_retract(target.global_position)


func _process_extending(cell: Vector2i, state: Dictionary) -> void:
	var target: Node2D = _target_from_state(state)
	var data: KrakenData = state.get("data", null) as KrakenData
	var visual: KrakenVisual = _visual_from_state(state)
	if target == null or data == null or visual == null:
		_cancel_attack(cell, state)
		return
	var origin: Vector2 = visual.global_position
	if origin.distance_to(target.global_position) > data.capture_range * RANGE_CANCEL_TOLERANCE:
		_cancel_attack(cell, state)
		return
	if not _is_target_still_eligible(target, int(state.get("target_nav_id", -1)), true):
		_cancel_attack(cell, state)
		return
	visual.update_grab_target_global_position(target.global_position)


func _on_grab_contacted(cell: Vector2i) -> void:
	if not _krakens.has(cell):
		return
	var state: Dictionary = _krakens[cell] as Dictionary
	var target: Node2D = _target_from_state(state)
	var visual: KrakenVisual = _visual_from_state(state)
	var nav_id: int = int(state.get("target_nav_id", -1))
	if target == null or visual == null or not _is_target_still_eligible(target, nav_id, true):
		_cancel_attack(cell, state)
		return
	var resume_state: Dictionary = _building_manager.suspend_agent_for_external_capture(nav_id, target)
	state["resume_state"] = resume_state
	state["captured"] = true
	state["state"] = STATE_RETRACTING
	target.global_position = visual.get_tip_global_position()
	_krakens[cell] = state


func _on_grab_retract_finished(cell: Vector2i) -> void:
	if not _krakens.has(cell):
		return
	var state: Dictionary = _krakens[cell] as Dictionary
	var target: Node2D = _target_from_state(state)
	var visual: KrakenVisual = _visual_from_state(state)
	if target == null or visual == null or not bool(state.get("captured", false)):
		_cancel_attack(cell, state)
		return
	target.global_position = visual.get_capture_anchor_global_position()
	state["state"] = STATE_EATING
	visual.play_eating()
	_krakens[cell] = state


func _on_eating_finished(cell: Vector2i) -> void:
	if not _krakens.has(cell):
		return
	var state: Dictionary = _krakens[cell] as Dictionary
	var target: Node2D = _target_from_state(state)
	var visual: KrakenVisual = _visual_from_state(state)
	var data: KrakenData = state.get("data", null) as KrakenData
	if target == null or visual == null or data == null:
		_cancel_attack(cell, state)
		return
	var drop_target: Vector2 = _building_manager.nearest_valid_dry_floor_world(visual.get_capture_anchor_global_position())
	_building_manager.remove_dead_monster_with_forced_currency_drop(target, data.forced_drop_currency, drop_target)
	_release_target_reservation(state)
	state["target"] = null
	state["target_nav_id"] = -1
	state["resume_state"] = {}
	state["captured"] = false
	state["state"] = STATE_DIGESTING
	visual.play_digestion(data.digestion_seconds)
	_krakens[cell] = state


func _on_digestion_finished(cell: Vector2i) -> void:
	if not _krakens.has(cell):
		return
	var state: Dictionary = _krakens[cell] as Dictionary
	var visual: KrakenVisual = _visual_from_state(state)
	var data: KrakenData = state.get("data", null) as KrakenData
	if visual != null:
		visual.reset_to_idle()
	state["state"] = STATE_READY
	state["scan_timer"] = maxf(0.02, data.target_scan_interval) if data != null else 0.1
	_krakens[cell] = state


func _nearest_eligible_target(cell: Vector2i, radius: float) -> Node2D:
	var tracker: AgentCellTracker = _building_manager.get_agent_cell_tracker()
	var origin: Vector2 = _building_manager.cell_center(cell)
	var agents: Array[Node2D] = tracker.get_agents_in_world_radius(origin, radius, CATEGORY_MONSTERS)
	var nearest: Node2D = null
	var nearest_distance_squared: float = radius * radius
	for agent: Node2D in agents:
		var nav_id: int = int(agent.get("nav_id"))
		if not _is_target_still_eligible(agent, nav_id, false):
			continue
		var distance_squared: float = origin.distance_squared_to(agent.global_position)
		if distance_squared <= nearest_distance_squared:
			nearest = agent
			nearest_distance_squared = distance_squared
	return nearest


func _is_target_still_eligible(agent: Node2D, nav_id: int, allow_own_reservation: bool) -> bool:
	if agent == null or not is_instance_valid(agent) or agent.is_queued_for_deletion():
		return false
	if not agent.is_in_group("monsters") or agent.is_in_group("clients") or agent.is_in_group("merchants"):
		return false
	if nav_id < 0:
		return false
	var id: int = agent.get_instance_id()
	if _reserved_target_ids.has(id) and not allow_own_reservation:
		return false
	if agent.has_method("is_external_capture_active") and bool(agent.call("is_external_capture_active")):
		return false
	if _building_manager.get_drowning_controller().is_drowning(nav_id):
		return false
	if _building_manager.get_turret_eating_controller().is_eating(nav_id):
		return false
	if _building_manager.is_agent_eating_plant(nav_id):
		return false
	return true


func _pin_target_to_tip(state: Dictionary) -> void:
	var target: Node2D = _target_from_state(state)
	var visual: KrakenVisual = _visual_from_state(state)
	if target != null and visual != null:
		target.global_position = visual.get_tip_global_position()


func _pin_target_to_capture_anchor(state: Dictionary) -> void:
	var target: Node2D = _target_from_state(state)
	var visual: KrakenVisual = _visual_from_state(state)
	if target != null and visual != null:
		target.global_position = visual.get_capture_anchor_global_position()


func _cancel_attack(cell: Vector2i, state: Dictionary) -> void:
	var target: Node2D = _target_from_state(state)
	var nav_id: int = int(state.get("target_nav_id", -1))
	if bool(state.get("captured", false)) and target != null and nav_id >= 0:
		var resume_state: Dictionary = state.get("resume_state", {}) as Dictionary
		_building_manager.resume_agent_after_external_capture(nav_id, target, resume_state)
	_release_target_reservation(state)
	var visual: KrakenVisual = _visual_from_state(state)
	if visual != null:
		visual.reset_to_idle()
	var data: KrakenData = state.get("data", null) as KrakenData
	state["state"] = STATE_READY
	state["target"] = null
	state["target_nav_id"] = -1
	state["resume_state"] = {}
	state["captured"] = false
	state["scan_timer"] = maxf(0.02, data.target_scan_interval) if data != null else 0.1
	_krakens[cell] = state


func _cancel_and_remove(cell: Vector2i) -> void:
	if not _krakens.has(cell):
		return
	var state: Dictionary = _krakens[cell] as Dictionary
	_cancel_attack(cell, state)
	_krakens.erase(cell)


func _release_target_reservation(state: Dictionary) -> void:
	var target: Node2D = _target_from_state(state)
	if target != null:
		_reserved_target_ids.erase(target.get_instance_id())


func _visual_from_state(state: Dictionary) -> KrakenVisual:
	var ref: WeakRef = state.get("visual", null) as WeakRef
	if ref == null:
		return null
	return ref.get_ref() as KrakenVisual


func _target_from_state(state: Dictionary) -> Node2D:
	var ref: WeakRef = state.get("target", null) as WeakRef
	if ref == null:
		return null
	return ref.get_ref() as Node2D


func _initial_scan_offset(cell: Vector2i, interval: float) -> float:
	var safe_interval: float = maxf(0.02, interval)
	var hash_value: int = absi(cell.x * 73856093 ^ cell.y * 19349663)
	return fmod(float(hash_value), 1000.0) / 1000.0 * safe_interval
