extends RefCounted
class_name BuildPlacementService

# Owns placement validation and placement commits. BuildSystem keeps input,
# preview, selection state, drag state, removal, and save/load coordination.

const FLOOR_TILE_CATALOG: Script = preload("res://scripts/map/floor_tile_catalog.gd")
const DEFAULT_TERRAIN_SPEED_MULTIPLIER: float = 1.0
const ALERT_NEEDS_GRASS_KEY: String = "alert.needs_grass"
const ALERT_NON_BUILDABLE_FLOOR_KEY: String = "alert.non_buildable_floor"
const ALERT_NEEDS_WATER_KEY: String = "alert.needs_water"
const PLACEMENT_SURFACE_BUILDABLE_FLOOR: StringName = &"buildable_floor"
const PLACEMENT_SURFACE_WATER_SOURCE: StringName = &"water_source"
const FENCE_ITEM_ID: String = "fence"

var _manager: BuildSystem
var _actor_displacement: BuildActorDisplacementService = BuildActorDisplacementService.new()


func setup(manager: BuildSystem) -> void:
	_manager = manager
	_actor_displacement.setup(manager)


func affordable_quantity(item_id: String) -> int:
	var game_ui: CanvasLayer = _game_ui()
	if not game_ui or not game_ui.has_method("get_build_affordable_quantity"):
		return 0
	return int(game_ui.call("get_build_affordable_quantity", item_id))


func can_afford(item_id: String) -> bool:
	var game_ui: CanvasLayer = _game_ui()
	return game_ui and game_ui.has_method("can_afford_build") and bool(game_ui.call("can_afford_build", item_id, 1))


func clear_build_selection_if_unaffordable(item_id: String) -> void:
	if item_id == "" or not can_afford(item_id):
		_clear_build_selection()


## Phase availability for a concrete placeable, as owned by game_ui. The plant/house policy
## itself lives there; the commit paths below only ask, so a stale definition, a same-frame
## night transition or a scripted caller can never place what the UI forbids.
func is_disabled_for_placement(item_id: String) -> bool:
	var game_ui: CanvasLayer = _game_ui()
	if game_ui == null or not game_ui.has_method("is_item_disabled_for_placement"):
		return false
	return bool(game_ui.call("is_item_disabled_for_placement", item_id))


func try_apply_placeable(placeable_def: Dictionary, cell: Vector2i) -> void:
	var item_id: String = str(placeable_def.get("id", ""))
	# Defense in depth: reject before validation scans, purchase, tile mutation, plant/house
	# creation, navigation or garden invalidation, FX and placement signals.
	if is_disabled_for_placement(item_id):
		return
	# Houses are multi-cell logical objects owned by HouseManager: route them before the generic
	# one-tile commit path (which would validate/stamp/pay for a single cell).
	if ItemCatalog.is_house_placeable(item_id):
		_apply_house_placeable(placeable_def, cell)
		return
	if _atlas_source_id() < 0 and not is_logical_plant(placeable_def):
		return
	var atlas_coords: Vector2i = atlas_coords_from_placeable(placeable_def)
	if atlas_coords == Vector2i(-1, -1) and not is_logical_plant(placeable_def):
		return

	var target_layer: TileMapLayer = target_tile_layer(str(placeable_def.get("target_layer", "wallz")))
	if not target_layer:
		return

	if not is_valid_placeable_cell(cell, target_layer, placeable_def):
		if placement_surface(placeable_def) == PLACEMENT_SURFACE_WATER_SOURCE and not is_water_source_cell(cell):
			_show_tutorial_alert(ALERT_NEEDS_WATER_KEY)
			return
		if placement_surface(placeable_def) == PLACEMENT_SURFACE_BUILDABLE_FLOOR and not is_buildable_floor_cell(cell):
			_show_tutorial_alert(ALERT_NON_BUILDABLE_FLOOR_KEY)
			return
		if requires_grass_green_floor(placeable_def) and not is_grass_green_floor_cell(cell):
			_show_tutorial_alert(ALERT_NEEDS_GRASS_KEY)
			return
		_notify("invalid construction")
		return

	if not can_afford(item_id):
		_notify("can't afford")
		return
	var game_ui: CanvasLayer = _game_ui()
	if not game_ui or not game_ui.has_method("try_purchase_build"):
		return
	if not bool(game_ui.call("try_purchase_build", item_id, 1)):
		_notify("can't afford")
		return

	clear_other_build_layer(target_layer, cell)
	if is_logical_plant(placeable_def) and target_layer == _plantz() and target_layer.get_cell_source_id(cell) >= 0:
		target_layer.erase_cell(cell)
		_flush_plant_layer_visuals()
	if not is_logical_plant(placeable_def):
		target_layer.set_cell(
			cell,
			_atlas_source_id(),
			atlas_coords,
			alternative_from_placeable(placeable_def)
		)
		target_layer.update_internals()
	if target_layer_affects_collision(target_layer):
		_refresh_cell_collision(cell)
	if target_layer_affects_navigation(target_layer, placeable_def):
		_notify_navigation_topology_changed(cell, "placeable_placed")
	if not is_logical_plant(placeable_def):
		_refresh_cell_terrain_speed(cell)
	after_placeable_placed(cell, placeable_def)
	if _placeable_displaces_actors(placeable_def):
		var displaced_cells: Array[Vector2i] = [cell]
		_actor_displacement.displace_from_cells(displaced_cells)
	if is_logical_plant(placeable_def):
		_refresh_cell_terrain_speed(cell)
	if item_id == FENCE_ITEM_ID:
		_refresh_fence_autotiles_around(cell)
	_play_build_fx_at_cell(cell, target_layer)
	clear_build_selection_if_unaffordable(item_id)


# House placement commit: validate the whole six-cell footprint, consume exactly one owned house,
# then ask HouseManager to build one runtime house. On an unexpected commit failure after the
# inventory was consumed, the item is restored immediately. No currency is charged (inventory-backed).
func _apply_house_placeable(placeable_def: Dictionary, entrance: Vector2i) -> void:
	var item_id: String = str(placeable_def.get("id", ""))
	var rejection: String = house_placement_rejection(entrance, placeable_def)
	if rejection != "":
		if _house_presence_has_non_buildable_floor(entrance):
			_show_tutorial_alert(ALERT_NON_BUILDABLE_FLOOR_KEY)
			return
		_notify("invalid construction")
		return
	if not can_afford(item_id):
		_notify("can't afford")
		return
	var game_ui: CanvasLayer = _game_ui()
	if game_ui == null or not game_ui.has_method("try_purchase_build"):
		return
	if not bool(game_ui.call("try_purchase_build", item_id, 1)):
		_notify("can't afford")
		return
	var house_manager: HouseManager = _manager.get_house_manager()
	if house_manager == null or not house_manager.build_player_house(item_id, entrance):
		# Commit failed after the inventory was consumed (e.g. the footprint changed this frame):
		# restore the one consumed house so no stock is lost.
		if game_ui.has_method("refund_build"):
			game_ui.call("refund_build", item_id, _cell_world_position(entrance), 1)
		_notify("invalid construction")
		return
	_actor_displacement.displace_from_cells(house_manager.get_presence_cells(entrance))
	if _manager != null and _manager.has_method("notify_player_house_placed"):
		_manager.call("notify_player_house_placed", item_id)
	_play_build_fx_at_cell(entrance, _wallz())
	# A house is placed one at a time (never dragged), so the tool always deselects after a
	# successful placement and control returns to play mode, even when another one is affordable.
	_clear_build_selection()


# "" = the whole house footprint is valid to place with `entrance` as its anchor. Otherwise a
# rejection reason. Combines HouseManager's structural rules (bounds, walkable entrance, overlap
# with an existing house) with the same per-cell buildable/occupancy checks a wall must satisfy,
# applied atomically to all six presence cells. Shared by the commit path and the live preview.
func house_placement_rejection(entrance: Vector2i, placeable_def: Dictionary) -> String:
	var house_manager: HouseManager = _manager.get_house_manager()
	if house_manager == null:
		return "house system unavailable"
	var item_id: String = ItemCatalog.normalize_house_item_id(str(placeable_def.get("id", "")))
	if not _manager.is_house_build_item_available(item_id):
		return "house item '%s' is not available" % item_id
	if ItemCatalog.is_unique_house_type(item_id) and house_manager.has_existing_house_type(item_id):
		return "house item '%s' is unique and already exists" % item_id
	var structural: String = house_manager.house_structural_rejection(entrance)
	if structural != "":
		return structural
	var wallz: TileMapLayer = _wallz()
	if wallz == null:
		return "wall layer unavailable"
	for cell: Vector2i in house_manager.get_presence_cells(entrance):
		if not is_buildable_floor_cell(cell):
			return "presence cell %s is not on buildable floor" % str(cell)
		if not is_valid_placeable_cell(cell, wallz, placeable_def):
			return "presence cell %s is blocked or not buildable" % str(cell)
	return ""


func _house_presence_has_non_buildable_floor(entrance: Vector2i) -> bool:
	var house_manager: HouseManager = _manager.get_house_manager()
	if house_manager == null:
		return false
	for cell: Vector2i in house_manager.get_presence_cells(entrance):
		if not is_buildable_floor_cell(cell):
			return true
	return false


func _cell_world_position(cell: Vector2i) -> Vector2:
	var layer: TileMapLayer = _wallz()
	if layer == null:
		return Vector2.ZERO
	return layer.to_global(layer.map_to_local(cell))


func commit_drag_build(placeable_def: Dictionary, item_id: String, start_cell: Vector2i, end_cell: Vector2i) -> bool:
	# Same commit-level gate as try_apply_placeable: a rectangle released into a forbidden
	# phase places nothing, spends nothing, and emits no placement signal. Both ids are checked
	# because item_id drives the purchase while the def drives the tile mutation, and a
	# scripted caller can pass the two out of sync.
	if is_disabled_for_placement(item_id) or is_disabled_for_placement(str(placeable_def.get("id", ""))):
		return false
	var target_layer: TileMapLayer = target_tile_layer(str(placeable_def.get("target_layer", "wallz")))
	var atlas_coords: Vector2i = atlas_coords_from_placeable(placeable_def)
	var available: int = affordable_quantity(item_id)
	var cells: Array[Vector2i] = []
	if target_layer and (atlas_coords != Vector2i(-1, -1) or is_logical_plant(placeable_def)):
		cells = drag_build_rectangle_cells(start_cell, end_cell, target_layer, placeable_def, available)
	if cells.is_empty():
		if placement_attempt_has_non_buildable_floor(start_cell, end_cell):
			_show_tutorial_alert(ALERT_NON_BUILDABLE_FLOOR_KEY)
		elif placement_attempt_needs_grass_alert(start_cell, end_cell, placeable_def):
			_show_tutorial_alert(ALERT_NEEDS_GRASS_KEY)
		return false

	var game_ui: CanvasLayer = _game_ui()
	if not game_ui or not game_ui.has_method("try_purchase_build"):
		_clear_build_selection()
		return false
	if not bool(game_ui.call("try_purchase_build", item_id, cells.size())):
		_clear_build_selection()
		return false

	for cell: Vector2i in cells:
		if not is_logical_plant(placeable_def):
			target_layer.set_cell(cell, _atlas_source_id(), atlas_coords, alternative_from_placeable(placeable_def))
		if target_layer_affects_collision(target_layer):
			_refresh_cell_collision(cell)
		if target_layer_affects_navigation(target_layer, placeable_def):
			_notify_navigation_topology_changed(cell, "drag_placeable_placed")
		if not is_logical_plant(placeable_def):
			_refresh_cell_terrain_speed(cell)
		after_placeable_placed(cell, placeable_def, false)
		if is_logical_plant(placeable_def):
			_refresh_cell_terrain_speed(cell)
		_play_build_fx_at_cell(cell, target_layer)
	target_layer.update_internals()
	if _placeable_displaces_actors(placeable_def):
		_actor_displacement.displace_from_cells(cells)
	if item_id == FENCE_ITEM_ID:
		_refresh_fence_autotiles_for_cells(cells)
	if target_layer == _plantz():
		_flush_plant_layer_visuals()
	var sound: StringName = drag_build_sound(item_id)
	if sound != &"":
		Sfx.play_sound(sound)
	clear_build_selection_if_unaffordable(item_id)
	return true


func drag_build_sound(item_id: String) -> StringName:
	return &"plant" if item_id == "rose" else &""


func drag_build_rectangle_cells(
	start_cell: Vector2i,
	end_cell: Vector2i,
	target_layer: TileMapLayer,
	placeable_def: Dictionary,
	limit: int
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	# Asked once for the whole rectangle, before the per-cell loop: a phase-disabled buildable
	# never enters the candidate-cell x active-agent occupancy scan below.
	if limit <= 0 or is_disabled_for_placement(str(placeable_def.get("id", ""))):
		return cells
	var x_step: int = 1 if end_cell.x >= start_cell.x else -1
	var y_step: int = 1 if end_cell.y >= start_cell.y else -1
	var y: int = start_cell.y
	while true:
		var x: int = start_cell.x
		while true:
			var cell: Vector2i = Vector2i(x, y)
			if (
				is_valid_placeable_cell(cell, target_layer, placeable_def)
				and not drag_build_candidate_blocked_by_batch(cell, target_layer, placeable_def, cells)
			):
				cells.append(cell)
				if cells.size() >= limit:
					return cells
			if x == end_cell.x:
				break
			x += x_step
		if y == end_cell.y:
			break
		y += y_step
	return cells


func drag_build_candidate_blocked_by_batch(
	cell: Vector2i,
	target_layer: TileMapLayer,
	placeable_def: Dictionary,
	accepted_cells: Array[Vector2i]
) -> bool:
	if accepted_cells.is_empty():
		return false
	if str(placeable_def.get("category", "")) != "turret":
		return false
	var candidate_turret_data: TurretData = turret_data_from_placeable(placeable_def)
	if candidate_turret_data == null:
		return false
	if candidate_turret_data.build_in_range:
		return false
	var build_range: float = candidate_turret_data.build_range
	if build_range <= 0.0:
		return false
	var candidate_world_position: Vector2 = target_layer.to_global(target_layer.map_to_local(cell))
	var range_squared: float = build_range * build_range
	for accepted_cell: Vector2i in accepted_cells:
		var accepted_world_position: Vector2 = target_layer.to_global(target_layer.map_to_local(accepted_cell))
		if candidate_world_position.distance_squared_to(accepted_world_position) <= range_squared:
			return true
	return false


func target_tile_layer(layer_name: String) -> TileMapLayer:
	if layer_name == "plantz":
		return _plantz()
	if layer_name == "traversable_buildings":
		return _traversable_buildings()
	if layer_name == "blocking_buildings":
		return _blocking_buildings()
	if layer_name == "fences":
		return _fences()
	if layer_name == "buildings":
		return _traversable_buildings()
	return _wallz()


func target_layer_affects_collision(target_layer: TileMapLayer) -> bool:
	return target_layer == _wallz() or target_layer == _blocking_buildings()


# True only when placing this tile is a genuine hard-topology change that must rebuild
# walkability / gardens / Flow Fields. Turrets and other speed-only placeables return
# false (their slowdown is applied live via _refresh_cell_terrain_speed instead). Fences
# resolve by the current phase through the authoritative PlaceableNavImpact classifier.
func target_layer_affects_navigation(target_layer: TileMapLayer, placeable_def: Dictionary) -> bool:
	var layer_role: String = _nav_layer_role(target_layer)
	# Classify against the full catalog def (the build selection def can omit the
	# blocks_movement / isWall / speed_multiplier semantics the classifier reads).
	var item_id: String = str(placeable_def.get("id", ""))
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id) if item_id != "" else placeable_def
	var impact: PlaceableNavImpact.Impact = PlaceableNavImpact.classify_for_layer(layer_role, item_def)
	return PlaceableNavImpact.requires_hard_topology(impact, _fences_block_navigation())


func _nav_layer_role(target_layer: TileMapLayer) -> String:
	if target_layer == _wallz():
		return PlaceableNavImpact.LAYER_WALLZ
	if target_layer == _fences():
		return PlaceableNavImpact.LAYER_FENCES
	if target_layer == _blocking_buildings():
		return PlaceableNavImpact.LAYER_BLOCKING
	return "other"


func _fences_block_navigation() -> bool:
	if _manager != null and _manager.has_method("fences_currently_block_navigation"):
		return bool(_manager.call("fences_currently_block_navigation"))
	return true


func is_free_walkable_cell(cell: Vector2i) -> bool:
	var floorz: TileMapLayer = _floorz()
	var wallz: TileMapLayer = _wallz()
	if floorz and floorz.get_cell_source_id(cell) < 0:
		return false
	if wallz and wallz.get_cell_source_id(cell) >= 0:
		return false
	return true


func is_debris_cell(cell: Vector2i) -> bool:
	var plantz: TileMapLayer = _plantz()
	if plantz == null or plantz.get_cell_source_id(cell) < 0:
		return false
	var atlas_coords: Vector2i = plantz.get_cell_atlas_coords(cell)
	return ItemCatalog.get_placeable_id_for_tile(str(plantz.name), atlas_coords) == "debris"


func is_placeable_occupied(cell: Vector2i, target_layer: TileMapLayer, placeable_def: Dictionary) -> bool:
	# Permanent authored world features (bamboo) reserve their cell against every placeable
	# type, house presence cells included. Checked first because _placeable_displaces_actors
	# below lets most non-plant placeables skip actor-group occupancy entirely, so a
	# group-based reservation would not hold. Bamboo stays walkable — this only blocks
	# building on it.
	if _manager.is_permanent_world_feature_cell(cell):
		return true
	var wallz: TileMapLayer = _wallz()
	var plantz: TileMapLayer = _plantz()
	var traversable_buildings: TileMapLayer = _traversable_buildings()
	var blocking_buildings: TileMapLayer = _blocking_buildings()
	var fences: TileMapLayer = _fences()
	if bool(placeable_def.get("occupies_cell", true)) and target_layer.get_cell_source_id(cell) >= 0 and not (target_layer == plantz and is_debris_cell(cell)):
		return true
	var plant_manager: Node = _plant_manager()
	if plant_manager and plant_manager.has_method("has_plant") and bool(plant_manager.call("has_plant", cell)):
		return true
	if wallz and wallz != target_layer and wallz.get_cell_source_id(cell) >= 0:
		return true
	if plantz and plantz != target_layer and plantz.get_cell_source_id(cell) >= 0 and not is_debris_cell(cell):
		return true
	if traversable_buildings and traversable_buildings != target_layer and traversable_buildings.get_cell_source_id(cell) >= 0:
		return true
	if blocking_buildings and blocking_buildings != target_layer and blocking_buildings.get_cell_source_id(cell) >= 0:
		return true
	if fences and fences != target_layer and fences.get_cell_source_id(cell) >= 0:
		return true
	# Reserve every house's six presence cells (five walls AND the walkable entrance) against all
	# other placeables, so nothing can be built on a house wall or in its doorway. Covers authored
	# houses (e.g. house_seedmerchant) and player-built houses. During a house's own placement the
	# new house is not registered yet, so its cells are not reported occupied by this check.
	var house_manager: HouseManager = _manager.get_house_manager()
	if house_manager != null and house_manager.get_house_at_presence_cell(cell) != null:
		return true
	if _placeable_displaces_actors(placeable_def):
		return false
	return is_occupied_by_group_node(cell, placeable_def)


func is_valid_placeable_cell(cell: Vector2i, target_layer: TileMapLayer, placeable_def: Dictionary) -> bool:
	var surface: StringName = placement_surface(placeable_def)
	if surface == PLACEMENT_SURFACE_WATER_SOURCE:
		if not is_water_source_cell(cell):
			return false
		if bool(placeable_def.get("requires_cardinal_water_neighbors", false)) and not has_cardinal_water_neighbors(cell):
			return false
	else:
		if is_water_source_cell(cell):
			return false
		if not is_buildable_floor_cell(cell):
			return false
		if requires_grass_green_floor(placeable_def) and not is_grass_green_floor_cell(cell):
			return false
		if bool(placeable_def.get("requires_walkable_floor", false)) and not is_free_walkable_cell(cell):
			return false
	if not turret_range_blocker_for_cell(cell, placeable_def).is_empty():
		return false
	return not is_placeable_occupied(cell, target_layer, placeable_def)


func placement_surface(placeable_def: Dictionary) -> StringName:
	return StringName(placeable_def.get("placement_surface", PLACEMENT_SURFACE_BUILDABLE_FLOOR))


func is_logical_plant(placeable_def: Dictionary) -> bool:
	return bool(placeable_def.get("logical_plant", false))


func _placeable_displaces_actors(placeable_def: Dictionary) -> bool:
	if str(placeable_def.get("type", "")) != "placeable":
		return false
	if str(placeable_def.get("category", "")) == "plant":
		return false
	return bool(placeable_def.get("occupies_cell", true))


func requires_grass_green_floor(placeable_def: Dictionary) -> bool:
	var item_id: String = str(placeable_def.get("id", ""))
	return item_id == "rose" or bool(placeable_def.get("requires_grass_green_floor", false))


func is_grass_green_floor_cell(cell: Vector2i) -> bool:
	var floorz: TileMapLayer = _floorz()
	if floorz == null or floorz.get_cell_source_id(cell) < 0:
		return false
	return FLOOR_TILE_CATALOG.is_wet_grass_atlas(floorz.get_cell_atlas_coords(cell))


func is_buildable_floor_cell(cell: Vector2i) -> bool:
	return FLOOR_TILE_CATALOG.is_buildable_floor_cell(_floorz(), cell)


func placement_attempt_needs_grass_alert(start_cell: Vector2i, end_cell: Vector2i, placeable_def: Dictionary) -> bool:
	if not requires_grass_green_floor(placeable_def):
		return false
	var x_step: int = 1 if end_cell.x >= start_cell.x else -1
	var y_step: int = 1 if end_cell.y >= start_cell.y else -1
	var y: int = start_cell.y
	while true:
		var x: int = start_cell.x
		while true:
			var cell: Vector2i = Vector2i(x, y)
			if not is_grass_green_floor_cell(cell):
				return true
			if x == end_cell.x:
				break
			x += x_step
		if y == end_cell.y:
			break
		y += y_step
	return false


func placement_attempt_has_non_buildable_floor(start_cell: Vector2i, end_cell: Vector2i) -> bool:
	var x_step: int = 1 if end_cell.x >= start_cell.x else -1
	var y_step: int = 1 if end_cell.y >= start_cell.y else -1
	var y: int = start_cell.y
	while true:
		var x: int = start_cell.x
		while true:
			var cell: Vector2i = Vector2i(x, y)
			if not is_buildable_floor_cell(cell):
				return true
			if x == end_cell.x:
				break
			x += x_step
		if y == end_cell.y:
			break
		y += y_step
	return false


func is_water_source_cell(cell: Vector2i) -> bool:
	var watersources: TileMapLayer = _watersources()
	return watersources != null and watersources.get_cell_source_id(cell) >= 0


func has_cardinal_water_neighbors(cell: Vector2i) -> bool:
	return (
		is_water_source_cell(cell + Vector2i.RIGHT)
		and is_water_source_cell(cell + Vector2i.LEFT)
		and is_water_source_cell(cell + Vector2i.UP)
		and is_water_source_cell(cell + Vector2i.DOWN)
	)


func turret_range_blocker_for_cell(cell: Vector2i, placeable_def: Dictionary) -> Dictionary:
	if str(placeable_def.get("category", "")) != "turret":
		return {}
	var candidate_turret_data: TurretData = turret_data_from_placeable(placeable_def)
	if candidate_turret_data == null:
		return {}
	if candidate_turret_data.build_in_range:
		return {}
	var blocking_buildings: TileMapLayer = _blocking_buildings()
	if blocking_buildings == null:
		return {}
	var candidate_world_position: Vector2 = blocking_buildings.to_global(blocking_buildings.map_to_local(cell))
	var best_blocker: Dictionary = {}
	var best_distance_squared: float = INF
	for raw_turret_cell: Variant in blocking_buildings.get_used_cells():
		var turret_cell: Vector2i = raw_turret_cell as Vector2i
		var turret_item_id: String = turret_item_id_at_cell(turret_cell)
		if turret_item_id == "":
			continue
		var turret_data: TurretData = ItemCatalog.get_turret_data(turret_item_id)
		if turret_data == null or turret_data.build_in_range:
			continue
		var build_range: float = turret_data.build_range
		if build_range <= 0.0:
			continue
		var range_squared: float = build_range * build_range
		var turret_world_position: Vector2 = blocking_buildings.to_global(blocking_buildings.map_to_local(turret_cell))
		var distance_squared: float = candidate_world_position.distance_squared_to(turret_world_position)
		if distance_squared <= range_squared and distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			best_blocker = {
				"cell": turret_cell,
				"range": build_range,
			}
	return best_blocker


func turret_data_from_placeable(placeable_def: Dictionary) -> TurretData:
	var item_id: String = str(placeable_def.get("id", ""))
	if item_id == "":
		return null
	return ItemCatalog.get_turret_data(item_id)


func turret_item_id_at_cell(cell: Vector2i) -> String:
	var blocking_buildings: TileMapLayer = _blocking_buildings()
	if blocking_buildings == null or blocking_buildings.get_cell_source_id(cell) < 0:
		return ""
	var item_id: String = ItemCatalog.get_placeable_id_for_tile(str(blocking_buildings.name), blocking_buildings.get_cell_atlas_coords(cell))
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if str(item_def.get("category", "")) != "turret":
		return ""
	return item_id


func uses_building_object_manager(placeable_def: Dictionary) -> bool:
	var placeable_category: String = str(placeable_def.get("category", ""))
	var light_source: float = float(placeable_def.get("light_source", 0.0))
	if light_source > 0.0:
		return true
	return placeable_category == "furniture" or placeable_category == "turret" or placeable_category == "trap" or placeable_category == "shop_counter" or placeable_category == "irrigation" or placeable_category == "fence"


func is_occupied_by_group_node(cell: Vector2i, placeable_def: Dictionary) -> bool:
	var map_layer: TileMapLayer = _previewbuild() if _previewbuild() else _wallz()
	if not map_layer:
		return false
	var item_id: String = str(placeable_def.get("id", ""))
	for group_name: String in _occupied_groups():
		if item_id == "rose" and group_name == "player":
			continue
		var nodes: Array[Node] = _manager.get_tree().get_nodes_in_group(group_name)
		for node: Node in nodes:
			if node is Node2D:
				var occupant: Node2D = node as Node2D
				var occupant_cell: Vector2i = map_layer.local_to_map(map_layer.to_local(occupant.global_position))
				if occupant_cell == cell:
					return true
	return false


func atlas_coords_from_placeable(placeable_def: Dictionary) -> Vector2i:
	var raw: Variant = placeable_def.get("atlas", Vector2i(-1, -1))
	if raw is Vector2i:
		return raw
	if raw is Vector2:
		return Vector2i(int(raw.x), int(raw.y))
	if raw is Array and raw.size() == 2:
		return Vector2i(int(raw[0]), int(raw[1]))
	if is_logical_plant(placeable_def):
		return PlantManager.ROSE_DRY_ATLAS
	return Vector2i(-1, -1)


func alternative_from_placeable(placeable_def: Dictionary) -> int:
	if not BuildDirectionRules.is_directional_placeable(placeable_def):
		return 0
	var direction: Vector2i = placeable_def.get("direction", BuildDirectionRules.DIRECTION_RIGHT) as Vector2i
	return BuildDirectionRules.alternative_from_direction(direction)


func clear_other_build_layer(target_layer: TileMapLayer, cell: Vector2i) -> void:
	var wallz: TileMapLayer = _wallz()
	var plantz: TileMapLayer = _plantz()
	var traversable_buildings: TileMapLayer = _traversable_buildings()
	var blocking_buildings: TileMapLayer = _blocking_buildings()
	var fences: TileMapLayer = _fences()
	if target_layer != wallz and wallz:
		wallz.erase_cell(cell)
		wallz.update_internals()
	if target_layer != plantz and plantz:
		if not is_debris_cell(cell):
			plantz.erase_cell(cell)
			_flush_plant_layer_visuals()
			var plant_manager: Node = _plant_manager()
			if plant_manager and plant_manager.has_method("remove_plant"):
				plant_manager.call("remove_plant", cell, false)
	if target_layer != traversable_buildings and traversable_buildings:
		traversable_buildings.erase_cell(cell)
		traversable_buildings.update_internals()
		var building_object_manager: Node = _building_object_manager()
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, false)
		_refresh_cell_terrain_speed(cell)
	if target_layer != blocking_buildings and blocking_buildings:
		blocking_buildings.erase_cell(cell)
		blocking_buildings.update_internals()
		var building_object_manager: Node = _building_object_manager()
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, false)
	if target_layer != fences and fences:
		fences.erase_cell(cell)
		fences.update_internals()
		var building_object_manager: Node = _building_object_manager()
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, false)
		_refresh_cell_terrain_speed(cell)
		_refresh_fence_autotiles_around(cell)


func after_placeable_placed(cell: Vector2i, placeable_def: Dictionary, play_placement_sound: bool = true) -> void:
	var plant_manager: Node = _plant_manager()
	var placeable_category: String = str(placeable_def.get("category", ""))
	if placeable_category == "plant" and plant_manager and plant_manager.has_method("add_plant"):
		plant_manager.call("add_plant", cell, str(placeable_def.get("plant_kind", "rose")))
	var placeable_id: String = str(placeable_def.get("id", ""))
	if placeable_category == "plant" and play_placement_sound:
		Sfx.play_sound(&"plant")
	var building_object_manager: Node = _building_object_manager()
	if uses_building_object_manager(placeable_def) and building_object_manager and building_object_manager.has_method("add_building"):
		building_object_manager.call("add_building", cell, placeable_def)
	var reservoir_system: Node = _reservoir_system()
	if placeable_id == "reservoir" and reservoir_system != null and reservoir_system.has_method("request_reservoir_irrigation_from_cell"):
		reservoir_system.call("request_reservoir_irrigation_from_cell", cell)
	if placeable_id == "pasteque" and reservoir_system != null and reservoir_system.has_method("request_pasteque_irrigation_from_cell"):
		reservoir_system.call("request_pasteque_irrigation_from_cell", cell)
	# Central player-built provenance hook: register the freshly placed placeable so it
	# becomes a destructible tantrum target (only player-built tiles are registered).
	if _manager != null and _manager.has_method("register_player_placeable"):
		_manager.call("register_player_placeable", cell, placeable_id, str(placeable_def.get("target_layer", "wallz")))


func _clear_build_selection() -> void:
	if _manager != null:
		_manager._clear_build_selection()


func _show_tutorial_alert(key: String) -> void:
	if _manager != null:
		_manager._show_tutorial_alert(key)


func _notify(message: String) -> void:
	if _manager != null:
		_manager._notify(message)


func _refresh_cell_collision(cell: Vector2i) -> void:
	if _manager != null:
		_manager._refresh_cell_collision(cell)


func _notify_navigation_topology_changed(cell: Vector2i, reason: String) -> void:
	if _manager != null:
		_manager._notify_navigation_topology_changed(cell, reason)


func _refresh_cell_terrain_speed(cell: Vector2i) -> void:
	if _manager != null:
		_manager._refresh_cell_terrain_speed(cell)


func _refresh_fence_autotiles_for_cells(cells: Array[Vector2i]) -> void:
	if _manager != null:
		_manager._refresh_fence_autotiles_for_cells(cells)


func _refresh_fence_autotiles_around(cell: Vector2i) -> void:
	if _manager != null:
		_manager._refresh_fence_autotiles_around(cell)


func _flush_plant_layer_visuals() -> void:
	if _manager != null:
		_manager._flush_plant_layer_visuals()


func _play_build_fx_at_cell(cell: Vector2i, target_layer: TileMapLayer) -> void:
	if _manager != null:
		_manager._play_build_fx_at_cell(cell, target_layer)


func _atlas_source_id() -> int:
	if _manager == null:
		return -1
	return _manager._atlas_source_id


func _floorz() -> TileMapLayer:
	return _manager.floorz


func _watersources() -> TileMapLayer:
	return _manager.watersources


func _wallz() -> TileMapLayer:
	return _manager.wallz


func _plantz() -> TileMapLayer:
	return _manager.plantz


func _traversable_buildings() -> TileMapLayer:
	return _manager.traversable_buildings


func _blocking_buildings() -> TileMapLayer:
	return _manager.blocking_buildings


func _fences() -> TileMapLayer:
	return _manager.fences


func _previewbuild() -> TileMapLayer:
	return _manager.previewbuild


func _plant_manager() -> Node:
	return _manager.plant_manager


func _building_object_manager() -> Node:
	return _manager.building_object_manager


func _reservoir_system() -> Node:
	return _manager.reservoir_system


func _game_ui() -> CanvasLayer:
	return _manager.game_ui


func _occupied_groups() -> Array[String]:
	var raw_groups: Array[String] = _manager.occupied_groups
	var groups: Array[String] = []
	for raw_group: String in raw_groups:
		groups.append(raw_group)
	return groups
