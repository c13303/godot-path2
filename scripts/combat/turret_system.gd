extends Node2D
class_name TurretSystem

const TURRET_ID: String = "turret1"
const TURRET_SHOW_RADIUS: bool = true
const LOS_PRECOMPUTE_BUDGET_MS: float = 1.5
const LOS_PENDING: int = 0
const LOS_READY: int = 1

# Fill drawn over the tiles a hovered turret can actually see (LOS-aware coverage),
# shown only while hovering a single turret and never for all turrets at once.
@export var visible_by_turret_color: Color = Color(0.55, 0.55, 0.55, 0.2)
# Fill drawn over the union of every existing turret's range while placing a turret:
# the whole no-build zone (placing inside any turret's range is forbidden).
@export var forbidden_color: Color = Color(1.0, 0.1, 0.1, 0.35)

var _fight_system: FightSystem
var _building_objects: BuildingObjectManager
var _build_system: Node
var _wall_layer: TileMapLayer
var _turrets: Dictionary = {}
var _los_generation: int = 0
var _has_hovered_turret: bool = false
var _hovered_turret_cell: Vector2i = Vector2i.ZERO
var _has_preview_turret: bool = false

func _ready() -> void:
	_fight_system = get_parent() as FightSystem
	_building_objects = get_node_or_null("../../Map/BuildingObjectManager") as BuildingObjectManager
	_build_system = get_node_or_null("../../Map/BuildSystem")
	_wall_layer = get_node_or_null("../../Map/MonTilemap/wallz") as TileMapLayer
	if _fight_system == null or _building_objects == null:
		push_error("TurretSystem: FightSystem or BuildingObjectManager is missing.")
		set_process(false)
		return
	z_as_relative = false
	z_index = 4095
	_building_objects.building_added.connect(_on_building_added)
	_building_objects.building_removed.connect(_on_building_removed)
	for cell: Vector2i in _building_objects.get_building_cells():
		var building: Dictionary = _building_objects.get_building(cell)
		if str(building.get("item_id", "")) == TURRET_ID:
			_register_turret(cell)
	if TURRET_SHOW_RADIUS:
		queue_redraw()

func _process(delta: float) -> void:
	_update_hovered_turret()
	_update_preview_turret()
	if _fight_system and _fight_system.has_method("is_paused") and bool(_fight_system.call("is_paused")):
		return
	for raw_cell: Variant in _turrets.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var state: Dictionary = _turrets[cell] as Dictionary
		var origin: Vector2 = _turret_world_position(cell)
		var activation_range: float = float(state.get("range", 0.0))
		# A spray burst is in progress: keep aiming at (and damaging) the nearest enemy
		# until the duration elapses. `elapsed` keeps counting so the next burst starts
		# exactly shoot_frequency seconds after this one began.
		if bool(state.get("spraying", false)):
			_advance_turret_spray(cell, state, origin, activation_range, delta)
			continue
		var elapsed: float = float(state.get("elapsed", 0.0)) + delta
		var shoot_frequency: float = float(state.get("shoot_frequency", 3.0))
		if elapsed < shoot_frequency:
			state["elapsed"] = elapsed
			continue
		var target: Node2D = _nearest_enemy_in_range(cell, origin, activation_range)
		if target == null:
			# Ready to fire but nothing in range; stay primed and retry next frame.
			state["elapsed"] = shoot_frequency
			continue
		var direction: Vector2 = target.global_position - origin
		state["spraying"] = true
		state["spray_time_left"] = float(state.get("shoot_duration", 1.0))
		state["last_direction"] = direction
		state["elapsed"] = elapsed - shoot_frequency
		_fight_system.update_turret_spray(cell, str(state.get("weapon", "spray")), origin, direction, delta)

func _advance_turret_spray(cell: Vector2i, state: Dictionary, origin: Vector2, activation_range: float, delta: float) -> void:
	var target: Node2D = _nearest_enemy_in_range(cell, origin, activation_range)
	var direction: Vector2 = (target.global_position - origin) if target != null else (state.get("last_direction", Vector2.RIGHT) as Vector2)
	state["last_direction"] = direction
	_fight_system.update_turret_spray(cell, str(state.get("weapon", "spray")), origin, direction, delta)
	state["elapsed"] = float(state.get("elapsed", 0.0)) + delta
	var time_left: float = float(state.get("spray_time_left", 0.0)) - delta
	if time_left <= 0.0:
		state["spraying"] = false
		state["spray_time_left"] = 0.0
		_fight_system.stop_turret_spray(cell)
	else:
		state["spray_time_left"] = time_left

# Two mutually exclusive overlays:
#  - While placing a turret, the whole no-build zone (union of every existing turret's
#    range) is filled red, matching the placement rule in buildsystem.
#  - Otherwise, hovering a single turret fills only that turret's visible tiles
#    (LOS-aware), so you can inspect exactly what one turret covers.
func _draw() -> void:
	if not TURRET_SHOW_RADIUS:
		return
	var layer: TileMapLayer = _building_objects.blocking_buildings
	if layer == null:
		return
	if _has_preview_turret:
		_draw_forbidden_zone(layer)
	elif _has_hovered_turret:
		_draw_visible_by_turret(layer)

func _draw_forbidden_zone(layer: TileMapLayer) -> void:
	# Merge every turret's range into one cell set so overlapping ranges are filled once
	# and the transparency doesn't double-blend where zones overlap.
	var cells: Dictionary = {}
	for raw_cell: Variant in _turrets.keys():
		var turret_cell: Vector2i = raw_cell as Vector2i
		var activation_range: float = float((_turrets[turret_cell] as Dictionary).get("range", 0.0))
		_collect_range_cells(layer, turret_cell, activation_range, cells)
	_fill_cells(layer, cells.keys(), forbidden_color)

func _draw_visible_by_turret(layer: TileMapLayer) -> void:
	var state: Dictionary = _turrets.get(_hovered_turret_cell, {}) as Dictionary
	# LOS is precomputed async; until it's ready, approximate with the plain range.
	if int(state.get("los_status", LOS_PENDING)) == LOS_READY:
		var raw_visible_cells: Variant = state.get("visible_cells", {})
		if raw_visible_cells is Dictionary:
			_fill_cells(layer, (raw_visible_cells as Dictionary).keys(), visible_by_turret_color)
		return
	var cells: Dictionary = {}
	_collect_range_cells(layer, _hovered_turret_cell, float(state.get("range", 0.0)), cells)
	_fill_cells(layer, cells.keys(), visible_by_turret_color)

func _collect_range_cells(layer: TileMapLayer, cell: Vector2i, activation_range: float, out_cells: Dictionary) -> void:
	if activation_range <= 0.0:
		return
	var tile_size: float = _tile_size_pixels(layer)
	var radius_cells: int = ceili(activation_range / maxf(1.0, tile_size))
	var origin: Vector2 = _turret_world_position(cell)
	var range_squared: float = activation_range * activation_range
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

func _on_building_added(cell: Vector2i, item_id: String) -> void:
	if item_id == TURRET_ID:
		_register_turret(cell)

func _on_building_removed(cell: Vector2i, item_id: String) -> void:
	if item_id != TURRET_ID:
		return
	_fight_system.remove_turret_spray(cell)
	_turrets.erase(cell)
	if _has_hovered_turret and _hovered_turret_cell == cell:
		_has_hovered_turret = false
	if TURRET_SHOW_RADIUS:
		queue_redraw()

func _register_turret(cell: Vector2i) -> void:
	var turret_def: Dictionary = ItemCatalog.get_item_def(TURRET_ID)
	var shoot_frequency: float = maxf(0.001, float(turret_def.get("shoot_frequency", 3.0)))
	_turrets[cell] = {
		"elapsed": shoot_frequency,
		"shoot_frequency": shoot_frequency,
		"shoot_duration": maxf(0.0, float(turret_def.get("shoot_duration", 1.0))),
		"weapon": str(turret_def.get("weapon", "spray")),
		"range": float(turret_def.get("range", 200.0)),
		"spraying": false,
		"spray_time_left": 0.0,
		"last_direction": Vector2.RIGHT,
		"los_status": LOS_PENDING,
		"visible_cells": {},
		"los_generation": _next_los_generation(),
	}
	# Initialize this turret's independent spray timers.
	_fight_system.create_turret_spray(cell)
	call_deferred("_compute_turret_los_async", cell, int((_turrets[cell] as Dictionary).get("los_generation", 0)))
	if TURRET_SHOW_RADIUS:
		queue_redraw()

func _update_hovered_turret() -> void:
	if not TURRET_SHOW_RADIUS:
		return
	var layer: TileMapLayer = _building_objects.blocking_buildings
	if layer == null:
		return
	var mouse_world_position: Vector2 = get_global_mouse_position()
	var mouse_cell: Vector2i = layer.local_to_map(layer.to_local(mouse_world_position))
	var has_hovered_turret: bool = _turrets.has(mouse_cell)
	if has_hovered_turret == _has_hovered_turret and (not has_hovered_turret or mouse_cell == _hovered_turret_cell):
		return
	_has_hovered_turret = has_hovered_turret
	_hovered_turret_cell = mouse_cell
	queue_redraw()

func _update_preview_turret() -> void:
	if not TURRET_SHOW_RADIUS:
		return
	var has_preview_turret: bool = false
	if _build_system != null and _build_system.has_method("has_single_tile_preview") and bool(_build_system.call("has_single_tile_preview")):
		has_preview_turret = str(_build_system.call("get_preview_item_id")) == TURRET_ID
	if has_preview_turret == _has_preview_turret:
		return
	_has_preview_turret = has_preview_turret
	queue_redraw()

func _nearest_enemy_in_range(turret_cell: Vector2i, origin: Vector2, activation_range: float) -> Node2D:
	var nearest: Node2D = null
	var nearest_distance_squared: float = activation_range * activation_range
	for raw_enemy: Node in get_tree().get_nodes_in_group(&"monsters"):
		var enemy: Node2D = raw_enemy as Node2D
		if enemy == null or not is_instance_valid(enemy):
			continue
		var distance_squared: float = origin.distance_squared_to(enemy.global_position)
		if distance_squared <= nearest_distance_squared and _turret_can_see_world_position(turret_cell, enemy.global_position):
			nearest = enemy
			nearest_distance_squared = distance_squared
	return nearest

func _turret_world_position(cell: Vector2i) -> Vector2:
	var layer: TileMapLayer = _building_objects.blocking_buildings
	return layer.to_global(layer.map_to_local(cell))

func _turret_can_see_world_position(turret_cell: Vector2i, world_position: Vector2) -> bool:
	var state: Dictionary = _turrets.get(turret_cell, {}) as Dictionary
	if int(state.get("los_status", LOS_PENDING)) != LOS_READY:
		return false
	var raw_visible_cells: Variant = state.get("visible_cells", {})
	if not (raw_visible_cells is Dictionary):
		return false
	var visible_cells: Dictionary = raw_visible_cells as Dictionary
	var layer: TileMapLayer = _building_objects.blocking_buildings
	if layer == null:
		return false
	var target_cell: Vector2i = layer.local_to_map(layer.to_local(world_position))
	return visible_cells.has(target_cell)

func _compute_turret_los_async(cell: Vector2i, generation: int) -> void:
	if not _turrets.has(cell):
		return
	var state: Dictionary = _turrets[cell] as Dictionary
	if int(state.get("los_generation", 0)) != generation:
		return
	var layer: TileMapLayer = _building_objects.blocking_buildings
	if layer == null:
		return
	var activation_range: float = float(state.get("range", 0.0))
	var visible_cells: Dictionary = {}
	if activation_range <= 0.0:
		_finish_turret_los(cell, generation, visible_cells)
		return

	var tile_size: float = _tile_size_pixels(layer)
	var radius_cells: int = ceili(activation_range / maxf(1.0, tile_size))
	var origin_world: Vector2 = _turret_world_position(cell)
	var range_squared: float = activation_range * activation_range
	var budget_us: int = maxi(500, int(LOS_PRECOMPUTE_BUDGET_MS * 1000.0))
	var slice_started_us: int = Time.get_ticks_usec()

	for y_offset: int in range(-radius_cells, radius_cells + 1):
		for x_offset: int in range(-radius_cells, radius_cells + 1):
			if not _turrets.has(cell):
				return
			state = _turrets[cell] as Dictionary
			if int(state.get("los_generation", 0)) != generation:
				return
			var target_cell: Vector2i = cell + Vector2i(x_offset, y_offset)
			if _is_los_blocker_cell(target_cell):
				continue
			var target_world: Vector2 = layer.to_global(layer.map_to_local(target_cell))
			if origin_world.distance_squared_to(target_world) > range_squared:
				continue
			if _has_line_of_sight_cells(cell, target_cell):
				visible_cells[target_cell] = true
			if Time.get_ticks_usec() - slice_started_us >= budget_us:
				await get_tree().process_frame
				slice_started_us = Time.get_ticks_usec()

	_finish_turret_los(cell, generation, visible_cells)

func _finish_turret_los(cell: Vector2i, generation: int, visible_cells: Dictionary) -> void:
	if not _turrets.has(cell):
		return
	var state: Dictionary = _turrets[cell] as Dictionary
	if int(state.get("los_generation", 0)) != generation:
		return
	state["visible_cells"] = visible_cells
	state["los_status"] = LOS_READY
	# The hover overlay draws this turret's visible tiles, so refresh it once LOS lands.
	if _has_hovered_turret and _hovered_turret_cell == cell and not _has_preview_turret:
		queue_redraw()

func _has_line_of_sight_cells(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	var x0: int = from_cell.x
	var y0: int = from_cell.y
	var x1: int = to_cell.x
	var y1: int = to_cell.y
	var dx: int = absi(x1 - x0)
	var sx: int = 1 if x0 < x1 else -1
	var dy: int = -absi(y1 - y0)
	var sy: int = 1 if y0 < y1 else -1
	var error: int = dx + dy
	var x: int = x0
	var y: int = y0
	while true:
		if x == x1 and y == y1:
			return true
		var error_twice: int = error * 2
		if error_twice >= dy:
			error += dy
			x += sx
		if error_twice <= dx:
			error += dx
			y += sy
		var current_cell: Vector2i = Vector2i(x, y)
		if current_cell == to_cell:
			return true
		if current_cell != from_cell and _is_los_blocker_cell(current_cell):
			return false
	return true

func _is_los_blocker_cell(cell: Vector2i) -> bool:
	return _wall_layer != null and _wall_layer.get_cell_source_id(cell) >= 0

func _tile_size_pixels(layer: TileMapLayer) -> float:
	if layer == null or layer.tile_set == null:
		return 16.0
	var tile_size: Vector2i = layer.tile_set.tile_size
	return maxf(1.0, float(maxi(tile_size.x, tile_size.y)))

func _next_los_generation() -> int:
	_los_generation += 1
	return _los_generation
