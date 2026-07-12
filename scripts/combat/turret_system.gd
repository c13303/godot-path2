extends Node2D
class_name TurretSystem

const TURRET_SHOW_RADIUS: bool = true
const LOS_PRECOMPUTE_BUDGET_MS: float = 1.5
const LOS_PENDING: int = 0
const LOS_READY: int = 1

# Fill drawn over the tiles a hovered turret can actually see (LOS-aware coverage),
# shown only while hovering a single turret and never for all turrets at once.
@export var visible_by_turret_color: Color = Color(0.55, 0.55, 0.55, 0.2)
# Fill drawn over the union of every existing turret's build range while placing a
# turret: the whole no-build zone that matches the placement rule in BuildSystem.
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
var _preview_turret_cell: Vector2i = Vector2i.ZERO
var _preview_turret_direction: Vector2i = Vector2i(1, 0)

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
		var item_id: String = str(building.get("item_id", ""))
		if _is_turret_item(item_id):
			_register_turret(cell, item_id)
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
		var activation_range: float = float(state.get("shooting_range", 0.0))
		if bool(state.get("shot_active", false)):
			_advance_turret_shot(cell, state, origin, activation_range, delta)
			continue
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
			_set_turret_refractory_visual(cell, state, true)
			continue
		_set_turret_refractory_visual(cell, state, false)
		var target: Node2D = _target_for_turret(cell, state, origin, activation_range)
		if target == null:
			# Ready to fire but nothing in range; stay primed and retry next frame.
			state["elapsed"] = shoot_frequency
			continue
		var direction: Vector2 = _fire_direction_for_target(state, origin, target)
		state["last_direction"] = direction
		state["elapsed"] = elapsed - shoot_frequency
		_start_turret_shot(cell, state, origin, direction, delta)

func _start_turret_shot(cell: Vector2i, state: Dictionary, origin: Vector2, direction: Vector2, delta: float) -> void:
	var release_delay: float = maxf(0.0, float(state.get("shot_release_delay", 0.0)))
	var cycle_duration: float = maxf(release_delay, float(state.get("shot_cycle_duration", 0.0)))
	if cycle_duration <= 0.0:
		_fire_turret_weapon(cell, state, origin, direction, delta)
		return
	state["shot_active"] = true
	state["shot_time"] = 0.0
	state["shot_fired"] = false
	_set_turret_refractory_visual(cell, state, false)
	_building_objects.play_turret_shot_animation(cell)
	if release_delay <= 0.0:
		_fire_turret_weapon(cell, state, origin, direction, delta)
		state["shot_fired"] = true
	if cycle_duration <= 0.0:
		state["shot_active"] = false


func _advance_turret_shot(cell: Vector2i, state: Dictionary, origin: Vector2, activation_range: float, delta: float) -> void:
	var shot_time: float = float(state.get("shot_time", 0.0)) + delta
	state["shot_time"] = shot_time
	state["elapsed"] = float(state.get("elapsed", 0.0)) + delta
	var fired_this_frame: bool = false
	var release_delay: float = maxf(0.0, float(state.get("shot_release_delay", 0.0)))
	if not bool(state.get("shot_fired", false)) and shot_time >= release_delay:
		var target: Node2D = _target_for_turret(cell, state, origin, activation_range)
		var direction: Vector2 = _fire_direction_for_target(state, origin, target) if target != null else (state.get("last_direction", Vector2.RIGHT) as Vector2)
		state["last_direction"] = direction
		_fire_turret_weapon(cell, state, origin, direction, delta)
		state["shot_fired"] = true
		fired_this_frame = true
	if bool(state.get("spraying", false)) and not fired_this_frame:
		_advance_turret_spray(cell, state, origin, activation_range, delta, false)
	var cycle_duration: float = maxf(release_delay, float(state.get("shot_cycle_duration", 0.0)))
	if shot_time >= cycle_duration:
		state["shot_active"] = false
		_set_turret_refractory_visual(cell, state, float(state.get("elapsed", 0.0)) < float(state.get("shoot_frequency", 3.0)))


func _fire_turret_weapon(cell: Vector2i, state: Dictionary, origin: Vector2, direction: Vector2, delta: float) -> void:
	var weapon_id: String = str(state.get("weapon", "spray"))
	if _fight_system.is_gun(weapon_id):
		_fight_system.fire_turret_gun_once(cell, weapon_id, origin, direction)
		return
	state["spraying"] = true
	state["spray_time_left"] = float(state.get("shoot_duration", 1.0))
	_fight_system.update_turret_spray(cell, weapon_id, origin, direction, delta)

func _advance_turret_spray(cell: Vector2i, state: Dictionary, origin: Vector2, activation_range: float, delta: float, count_elapsed: bool = true) -> void:
	var target: Node2D = _target_for_turret(cell, state, origin, activation_range)
	var direction: Vector2 = _fire_direction_for_target(state, origin, target) if target != null else (state.get("last_direction", Vector2.RIGHT) as Vector2)
	state["last_direction"] = direction
	_fight_system.update_turret_spray(cell, str(state.get("weapon", "spray")), origin, direction, delta)
	if count_elapsed:
		state["elapsed"] = float(state.get("elapsed", 0.0)) + delta
	var time_left: float = float(state.get("spray_time_left", 0.0)) - delta
	if time_left <= 0.0:
		state["spraying"] = false
		state["spray_time_left"] = 0.0
		_fight_system.stop_turret_spray(cell)
		_set_turret_refractory_visual(cell, state, float(state.get("elapsed", 0.0)) < float(state.get("shoot_frequency", 3.0)))
	else:
		state["spray_time_left"] = time_left


func _set_turret_refractory_visual(cell: Vector2i, state: Dictionary, active: bool) -> void:
	# refractory: visual cooldown state after firing, before the turret can shoot again.
	if bool(state.get("refractory_visual", false)) == active:
		return
	state["refractory_visual"] = active
	_building_objects.set_turret_refractory_active(cell, active)

# Two mutually exclusive overlays:
#  - While placing a turret, the whole no-build zone (union of every existing turret's
#    build range) is filled red, matching the placement rule in buildsystem.
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
		_draw_preview_turret_coverage(layer)
	elif _has_hovered_turret:
		_draw_visible_by_turret(layer)

func _draw_forbidden_zone(layer: TileMapLayer) -> void:
	var preview_data: TurretData = _preview_turret_data()
	if preview_data != null and preview_data.build_in_range:
		return
	# Merge every turret's build range into one cell set so overlapping ranges are
	# filled once and the transparency doesn't double-blend where zones overlap.
	var cells: Dictionary = {}
	for raw_cell: Variant in _turrets.keys():
		var turret_cell: Vector2i = raw_cell as Vector2i
		var state: Dictionary = _turrets[turret_cell] as Dictionary
		var turret_data: TurretData = state.get("data", null) as TurretData
		if turret_data != null and turret_data.build_in_range:
			continue
		var build_range: float = float(state.get("build_range", 0.0))
		_collect_range_cells(layer, turret_cell, build_range, cells)
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
	if bool(state.get("straight_line_detection", false)):
		_collect_line_cells(layer, _hovered_turret_cell, state.get("direction", Vector2i(1, 0)) as Vector2i, float(state.get("shooting_range", 0.0)), cells)
	else:
		_collect_range_cells(layer, _hovered_turret_cell, float(state.get("shooting_range", 0.0)), cells)
	_fill_cells(layer, cells.keys(), visible_by_turret_color)

func _draw_preview_turret_coverage(layer: TileMapLayer) -> void:
	var turret_data: TurretData = _preview_turret_data()
	if turret_data == null:
		return
	var cells: Dictionary = {}
	if turret_data.straight_line_detection:
		_collect_line_cells(layer, _preview_turret_cell, _preview_turret_direction, turret_data.shooting_range, cells)
	else:
		_collect_range_cells(layer, _preview_turret_cell, turret_data.shooting_range, cells)
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

func _collect_line_cells(layer: TileMapLayer, cell: Vector2i, direction: Vector2i, activation_range: float, out_cells: Dictionary) -> void:
	if activation_range <= 0.0 or direction == Vector2i.ZERO:
		return
	var tile_size: float = _tile_size_pixels(layer)
	var range_cells: int = ceili(activation_range / maxf(1.0, tile_size))
	for offset: int in range(1, range_cells + 1):
		var target_cell: Vector2i = cell + direction * offset
		if _is_los_blocker_cell(target_cell):
			return
		out_cells[target_cell] = true

func _fill_cells(layer: TileMapLayer, cells: Array, color: Color) -> void:
	var half_size: Vector2 = Vector2.ONE * (_tile_size_pixels(layer) * 0.5)
	for raw_cell: Variant in cells:
		var cell: Vector2i = raw_cell as Vector2i
		var center: Vector2 = to_local(layer.to_global(layer.map_to_local(cell)))
		draw_rect(Rect2(center - half_size, half_size * 2.0), color, true)

func _on_building_added(cell: Vector2i, item_id: String) -> void:
	if _is_turret_item(item_id):
		_register_turret(cell, item_id)

func _on_building_removed(cell: Vector2i, item_id: String) -> void:
	if not _is_turret_item(item_id):
		return
	_fight_system.remove_turret_spray(cell)
	_turrets.erase(cell)
	if _has_hovered_turret and _hovered_turret_cell == cell:
		_has_hovered_turret = false
	if TURRET_SHOW_RADIUS:
		queue_redraw()

func _register_turret(cell: Vector2i, item_id: String) -> void:
	var turret_data: TurretData = ItemCatalog.get_turret_data(item_id)
	if turret_data == null:
		push_warning("TurretSystem: missing TurretData for %s." % item_id)
		return
	var weapon_id: String = _weapon_id_from_resource(turret_data.weapon)
	var shoot_frequency: float = maxf(0.001, turret_data.shoot_frequency)
	var building: Dictionary = _building_objects.get_building(cell)
	var direction: Vector2i = building.get("direction", Vector2i(1, 0)) as Vector2i
	# Prefer timing derived from the shot animation so the projectile releases when the
	# last frame begins; fall back to the TurretData fields for turrets with no frames.
	var release_delay: float = maxf(0.0, turret_data.shot_release_delay)
	var cycle_duration: float = maxf(0.0, turret_data.shot_cycle_duration)
	var animation_timing: Dictionary = ItemCatalog.get_turret_shot_animation_timing(item_id)
	if not animation_timing.is_empty():
		release_delay = float(animation_timing.get("release_delay", release_delay))
		cycle_duration = float(animation_timing.get("cycle_duration", cycle_duration))
	_turrets[cell] = {
		"item_id": item_id,
		"data": turret_data,
		"elapsed": shoot_frequency,
		"shoot_frequency": shoot_frequency,
		"shoot_duration": maxf(0.0, turret_data.shoot_duration),
		"weapon": weapon_id,
		"shooting_range": turret_data.shooting_range,
		"build_range": turret_data.build_range,
		"direction": direction,
		"directional": turret_data.directional,
		"straight_line_detection": turret_data.straight_line_detection,
		"shot_release_delay": release_delay,
		"shot_cycle_duration": cycle_duration,
		"shot_active": false,
		"shot_time": 0.0,
		"shot_fired": false,
		"spraying": false,
		"spray_time_left": 0.0,
		"refractory_visual": false,
		"last_direction": Vector2(float(direction.x), float(direction.y)),
		"los_status": LOS_PENDING,
		"visible_cells": {},
		"los_generation": _next_los_generation(),
	}
	if not _fight_system.is_gun(weapon_id):
		_fight_system.create_turret_spray(cell)
	call_deferred("_compute_turret_los_async", cell, int((_turrets[cell] as Dictionary).get("los_generation", 0)))
	if TURRET_SHOW_RADIUS:
		queue_redraw()

func _is_turret_item(item_id: String) -> bool:
	if item_id == "":
		return false
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	return str(item_def.get("category", "")) == "turret" and ItemCatalog.get_turret_data(item_id) != null

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
	var preview_cell: Vector2i = _preview_turret_cell
	var preview_direction: Vector2i = _preview_turret_direction
	if _build_system != null and _build_system.has_method("has_single_tile_preview") and bool(_build_system.call("has_single_tile_preview")):
		has_preview_turret = _is_turret_item(str(_build_system.call("get_preview_item_id")))
		if has_preview_turret and _build_system.has_method("get_preview_cell"):
			preview_cell = _build_system.call("get_preview_cell") as Vector2i
		if has_preview_turret and _build_system.has_method("get_preview_direction"):
			preview_direction = _build_system.call("get_preview_direction") as Vector2i
	if (
		has_preview_turret == _has_preview_turret
		and preview_cell == _preview_turret_cell
		and preview_direction == _preview_turret_direction
	):
		return
	_has_preview_turret = has_preview_turret
	_preview_turret_cell = preview_cell
	_preview_turret_direction = preview_direction
	queue_redraw()

func _preview_turret_data() -> TurretData:
	if _build_system == null or not _build_system.has_method("get_preview_item_id"):
		return null
	var item_id: String = str(_build_system.call("get_preview_item_id"))
	return ItemCatalog.get_turret_data(item_id)

func _weapon_id_from_resource(weapon: Resource) -> String:
	if weapon == null:
		return ""
	return str(weapon.get("id"))

func _target_for_turret(turret_cell: Vector2i, state: Dictionary, origin: Vector2, activation_range: float) -> Node2D:
	if bool(state.get("straight_line_detection", false)):
		var direction: Vector2i = state.get("direction", Vector2i(1, 0)) as Vector2i
		return _nearest_enemy_in_line(turret_cell, origin, activation_range, direction)
	return _nearest_enemy_in_range(turret_cell, origin, activation_range)

func _fire_direction_for_target(state: Dictionary, origin: Vector2, target: Node2D) -> Vector2:
	if bool(state.get("directional", false)):
		var direction: Vector2i = state.get("direction", Vector2i(1, 0)) as Vector2i
		return Vector2(float(direction.x), float(direction.y))
	return target.global_position - origin

func _nearest_enemy_in_line(turret_cell: Vector2i, origin: Vector2, activation_range: float, direction: Vector2i) -> Node2D:
	if direction == Vector2i.ZERO:
		return null
	var layer: TileMapLayer = _building_objects.blocking_buildings
	if layer == null:
		return null
	var nearest: Node2D = null
	var nearest_step: int = 2147483647
	var tile_size: float = _tile_size_pixels(layer)
	var max_steps: int = ceili(activation_range / maxf(1.0, tile_size))
	for raw_enemy: Node in get_tree().get_nodes_in_group(&"monsters"):
		var enemy: Node2D = raw_enemy as Node2D
		if enemy == null or not is_instance_valid(enemy):
			continue
		var enemy_cell: Vector2i = layer.local_to_map(layer.to_local(enemy.global_position))
		var offset: Vector2i = enemy_cell - turret_cell
		var step: int = _line_step_for_offset(offset, direction)
		if step <= 0 or step > max_steps or step >= nearest_step:
			continue
		if origin.distance_squared_to(enemy.global_position) > activation_range * activation_range:
			continue
		if not _turret_can_see_world_position(turret_cell, enemy.global_position):
			continue
		nearest = enemy
		nearest_step = step
	return nearest

func _line_step_for_offset(offset: Vector2i, direction: Vector2i) -> int:
	if direction.x != 0:
		if offset.y != 0 or offset.x * direction.x <= 0:
			return -1
		return absi(offset.x)
	if direction.y != 0:
		if offset.x != 0 or offset.y * direction.y <= 0:
			return -1
		return absi(offset.y)
	return -1

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
	var activation_range: float = float(state.get("shooting_range", 0.0))
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

	if bool(state.get("straight_line_detection", false)):
		var direction: Vector2i = state.get("direction", Vector2i(1, 0)) as Vector2i
		_collect_line_cells(layer, cell, direction, activation_range, visible_cells)
		_finish_turret_los(cell, generation, visible_cells)
		return

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
