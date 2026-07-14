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
const OVERLAY_Z_INDEX: int = 4094

@export var capture_range_color: Color = Color(0.35, 0.65, 0.78, 0.22)

var _fight_system: FightSystem
var _building_objects: BuildingObjectManager
var _building_manager: BuildingManager
var _build_system: Node
var _krakens: Dictionary = {}
var _reserved_target_ids: Dictionary = {}
var _has_hovered_kraken: bool = false
var _hovered_kraken_cell: Vector2i = Vector2i.ZERO
var _has_preview_kraken: bool = false
var _preview_kraken_cell: Vector2i = Vector2i.ZERO


func _ready() -> void:
	_fight_system = get_parent() as FightSystem
	_building_objects = get_node_or_null("../../Map/BuildingObjectManager") as BuildingObjectManager
	_building_manager = get_node_or_null("../../Map/BuildingManager") as BuildingManager
	_build_system = get_node_or_null("../../Map/BuildSystem")
	if _fight_system == null or _building_objects == null or _building_manager == null:
		push_error("KrakenSystem: required gameplay owners are missing.")
		set_process(false)
		return
	z_as_relative = false
	z_index = OVERLAY_Z_INDEX
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
	_update_hovered_kraken()
	_update_preview_kraken()
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


func _draw() -> void:
	var layer: TileMapLayer = _kraken_layer()
	if layer == null:
		return
	if _has_preview_kraken:
		_draw_kraken_range(layer, _preview_kraken_cell, _kraken_capture_range())
	elif _has_hovered_kraken:
		var state: Dictionary = _krakens.get(_hovered_kraken_cell, {}) as Dictionary
		var data: KrakenData = state.get("data", null) as KrakenData
		if data != null:
			_draw_kraken_range(layer, _hovered_kraken_cell, data.capture_range)


func _on_building_added(cell: Vector2i, item_id: String) -> void:
	if item_id == KRAKEN_ITEM_ID:
		_register_kraken(cell)
		queue_redraw()


func _on_building_removed(cell: Vector2i, item_id: String) -> void:
	if item_id == KRAKEN_ITEM_ID:
		_cancel_and_remove(cell)
		if _has_hovered_kraken and _hovered_kraken_cell == cell:
			_has_hovered_kraken = false
		queue_redraw()


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
		"target_z_saved": false,
		"target_z_as_relative": false,
		"target_z_index": 0,
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
	_save_target_draw_order(state, target)
	_apply_captured_target_draw_order(state, target)
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
	var death_position: Vector2 = visual.get_capture_anchor_global_position()
	target.global_position = death_position
	var drop_target: Vector2 = _building_manager.nearest_valid_dry_floor_world(death_position)
	_building_manager.remove_dead_monster_with_forced_currency_drop(target, data.forced_drop_currency, drop_target)
	_release_target_reservation(state)
	state["target"] = null
	state["target_nav_id"] = -1
	state["resume_state"] = {}
	state["captured"] = false
	state["target_z_saved"] = false
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
		_apply_captured_target_draw_order(state, target)
		target.global_position = visual.get_tip_global_position()


func _pin_target_to_capture_anchor(state: Dictionary) -> void:
	var target: Node2D = _target_from_state(state)
	var visual: KrakenVisual = _visual_from_state(state)
	if target != null and visual != null:
		_apply_captured_target_draw_order(state, target)
		target.global_position = visual.get_capture_anchor_global_position()


func _cancel_attack(cell: Vector2i, state: Dictionary) -> void:
	var target: Node2D = _target_from_state(state)
	var nav_id: int = int(state.get("target_nav_id", -1))
	if bool(state.get("captured", false)) and target != null and nav_id >= 0:
		var resume_state: Dictionary = state.get("resume_state", {}) as Dictionary
		_restore_target_draw_order(state, target)
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
	state["target_z_saved"] = false
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


func _save_target_draw_order(state: Dictionary, target: Node2D) -> void:
	if bool(state.get("target_z_saved", false)):
		return
	state["target_z_saved"] = true
	state["target_z_as_relative"] = target.z_as_relative
	state["target_z_index"] = target.z_index


func _apply_captured_target_draw_order(state: Dictionary, target: Node2D) -> void:
	var visual: KrakenVisual = _visual_from_state(state)
	if visual == null:
		return
	target.z_as_relative = false
	target.z_index = visual.z_index - 1


func _restore_target_draw_order(state: Dictionary, target: Node2D) -> void:
	if not bool(state.get("target_z_saved", false)):
		return
	target.z_as_relative = bool(state.get("target_z_as_relative", target.z_as_relative))
	target.z_index = int(state.get("target_z_index", target.z_index))


func _update_hovered_kraken() -> void:
	var layer: TileMapLayer = _kraken_layer()
	if layer == null:
		return
	var mouse_world_position: Vector2 = get_global_mouse_position()
	var mouse_cell: Vector2i = layer.local_to_map(layer.to_local(mouse_world_position))
	var has_hovered_kraken: bool = _krakens.has(mouse_cell)
	if has_hovered_kraken == _has_hovered_kraken and (not has_hovered_kraken or mouse_cell == _hovered_kraken_cell):
		return
	_has_hovered_kraken = has_hovered_kraken
	_hovered_kraken_cell = mouse_cell
	queue_redraw()


func _update_preview_kraken() -> void:
	var has_preview_kraken: bool = false
	var preview_cell: Vector2i = _preview_kraken_cell
	if _build_system != null and _build_system.has_method("has_single_tile_preview") and bool(_build_system.call("has_single_tile_preview")):
		has_preview_kraken = str(_build_system.call("get_preview_item_id")) == KRAKEN_ITEM_ID
		if has_preview_kraken and _build_system.has_method("get_preview_cell"):
			preview_cell = _build_system.call("get_preview_cell") as Vector2i
	if has_preview_kraken == _has_preview_kraken and preview_cell == _preview_kraken_cell:
		return
	_has_preview_kraken = has_preview_kraken
	_preview_kraken_cell = preview_cell
	queue_redraw()


func _draw_kraken_range(layer: TileMapLayer, cell: Vector2i, capture_range: float) -> void:
	if capture_range <= 0.0:
		return
	var cells: Dictionary = {}
	_collect_range_cells(layer, cell, capture_range, cells)
	_fill_cells(layer, cells.keys(), capture_range_color)


func _collect_range_cells(layer: TileMapLayer, cell: Vector2i, capture_range: float, out_cells: Dictionary) -> void:
	var tile_size: float = _tile_size_pixels(layer)
	var radius_cells: int = ceili(capture_range / maxf(1.0, tile_size))
	var origin: Vector2 = layer.to_global(layer.map_to_local(cell))
	var range_squared: float = capture_range * capture_range
	for y_offset: int in range(-radius_cells, radius_cells + 1):
		for x_offset: int in range(-radius_cells, radius_cells + 1):
			var target_cell: Vector2i = cell + Vector2i(x_offset, y_offset)
			var target_world: Vector2 = layer.to_global(layer.map_to_local(target_cell))
			if origin.distance_squared_to(target_world) <= range_squared:
				out_cells[target_cell] = true


func _fill_cells(layer: TileMapLayer, cells: Array, color: Color) -> void:
	var half_size: Vector2 = Vector2.ONE * (_tile_size_pixels(layer) * 0.5)
	for raw_cell: Variant in cells:
		var cell: Vector2i = raw_cell as Vector2i
		var center: Vector2 = to_local(layer.to_global(layer.map_to_local(cell)))
		draw_rect(Rect2(center - half_size, half_size * 2.0), color, true)


func _kraken_layer() -> TileMapLayer:
	return _building_objects.traversable_buildings if _building_objects != null else null


func _tile_size_pixels(layer: TileMapLayer) -> float:
	if layer == null or layer.tile_set == null:
		return 32.0
	var tile_size: Vector2i = layer.tile_set.tile_size
	return float(maxi(tile_size.x, tile_size.y))


func _kraken_capture_range() -> float:
	var data: KrakenData = ItemCatalog.get_item_def(KRAKEN_ITEM_ID).get("kraken_data", null) as KrakenData
	return data.capture_range if data != null else 0.0


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
