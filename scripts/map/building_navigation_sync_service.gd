extends RefCounted
class_name BuildingNavigationSyncService

# Owns the "building/fence/placeable effects -> flow & player navigation" synchronization
# extracted from BuildingManager. This service translates the current contents of the
# building tile layers into the flow node's extra-blocking-cell set, fence-blocking-cell
# set, per-cell player blocking, and per-cell speed multipliers. It never mutates the tile
# layers or performs placement/removal; BuildingManager keeps the source-of-truth state
# (the exported layers, the flow node) and thin compatibility wrappers, and this reads them
# back through the typed _manager reference (BuildingManager) rather than string lookups.
#
# Behavior note: this is an extraction only. Which items block flow, which block the
# player, fence slow behavior, the min/clamp speed logic, the layer order, and the
# missing-definition fallbacks are all preserved exactly as they were inline in
# BuildingManager.

const DEFAULT_TERRAIN_SPEED_MULTIPLIER: float = 1.0

var _manager: BuildingManager
# Terrain speed owned by permanent static world features (authored bamboo), keyed by cell.
# These are not derived from any tile layer, so they survive layer save/restore and cannot be
# cleared by build/removal logic. Kept generic: any permanent feature can register here, and
# 1.0 clears an entry. Vector2i -> float.
var _static_terrain_speed_by_cell: Dictionary = {}


func setup(manager: BuildingManager) -> void:
	_manager = manager


## Registers (or clears) a permanent world feature's speed multiplier for one cell, then
## refreshes only that cell's effective terrain speed. A multiplier at or above 1.0 removes
## the entry. This never rebuilds a flow field: refresh_cell_speed writes the shared native
## terrain-speed map that every steered agent reads live.
func set_static_terrain_speed_multiplier(cell: Vector2i, multiplier: float) -> void:
	var clamped_multiplier: float = clampf(multiplier, 0.01, 1.0)
	if clamped_multiplier >= DEFAULT_TERRAIN_SPEED_MULTIPLIER:
		_static_terrain_speed_by_cell.erase(cell)
	else:
		_static_terrain_speed_by_cell[cell] = clamped_multiplier
	refresh_cell_speed(cell)


func sync_flow_extra_blocking_cells() -> void:
	var flow: Node = _manager.flow
	if flow == null or not flow.has_method("set_extra_blocking_cells"):
		return
	var blocking_buildings: TileMapLayer = _manager.blocking_buildings
	var fences: TileMapLayer = _manager.fences
	var cells: PackedVector2Array = PackedVector2Array()
	if blocking_buildings != null:
		for raw_cell: Variant in blocking_buildings.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
			if not _manager._building_cell_blocks_movement(cell):
				continue
			cells.append(Vector2(float(cell.x), float(cell.y)))
	flow.call("set_extra_blocking_cells", cells)
	# Fences are kept out of extra_blocking_cells (which feeds player collision and every
	# group flow). They are pushed as a separate set that only client/merchant flows bake
	# as walls (block_fences); monster flows ignore fences and are slowed by the fence
	# cells' 0.3 speed multiplier instead. See _request_group_flow_rebuild / _has_wall.
	if flow.has_method("set_fence_blocking_cells"):
		var fence_cells: PackedVector2Array = PackedVector2Array()
		if fences != null:
			for raw_cell: Variant in fences.get_used_cells():
				var fence_cell: Vector2i = raw_cell as Vector2i
				fence_cells.append(Vector2(float(fence_cell.x), float(fence_cell.y)))
		flow.call("set_fence_blocking_cells", fence_cells)


func rebuild_waterpool_directional_field() -> void:
	var watersources: WaterSources = _manager.watersources
	if watersources == null or not watersources.has_method("rebuild_waterpool_directional_field"):
		return
	watersources.call("rebuild_waterpool_directional_field", _get_steering_system())


func clear_waterpool_directional_field() -> void:
	var watersources: WaterSources = _manager.watersources
	if watersources == null or not watersources.has_method("clear_waterpool_directional_field"):
		return
	watersources.call("clear_waterpool_directional_field", _get_steering_system())


func _get_steering_system() -> Node:
	var scene: Node = _manager.get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("CPP/SteeringSystemNative")


func building_item_blocks_player(item_id: String) -> bool:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if item_def.is_empty():
		return false
	if str(item_def.get("target_layer", "")) != "blocking_buildings":
		return false
	if item_def.has("blocks_player_movement"):
		return bool(item_def.get("blocks_player_movement", false))
	return bool(item_def.get("blocks_movement", false)) or bool(item_def.get("isWall", false))


func sync_player_blocking_cells() -> void:
	var flow: Node = _manager.flow
	var blocking_buildings: TileMapLayer = _manager.blocking_buildings
	if flow == null or not flow.has_method("set_cell_blocked") or blocking_buildings == null:
		return
	for raw_cell: Variant in blocking_buildings.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		var item_id: String = blocking_building_item_id_at_cell(cell)
		if item_id == "" or building_item_blocks_player(item_id):
			set_player_cell_blocked(cell, true)


func set_player_cell_blocked(cell: Vector2i, blocked: bool) -> void:
	var flow: Node = _manager.flow
	if flow == null or not flow.has_method("set_cell_blocked"):
		return
	flow.call("set_cell_blocked", cell, blocked)


func blocking_building_item_id_at_cell(cell: Vector2i) -> String:
	var blocking_buildings: TileMapLayer = _manager.blocking_buildings
	if blocking_buildings == null or blocking_buildings.get_cell_source_id(cell) < 0:
		return ""
	var atlas: Vector2i = blocking_buildings.get_cell_atlas_coords(cell)
	return ItemCatalog.get_placeable_id_for_tile(str(blocking_buildings.name), atlas)


func sync_building_cell_speed(cell: Vector2i, item_id: String) -> void:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if item_def.is_empty() or not item_def.has("speed_multiplier"):
		return
	# The buildsystem's terrain-speed refresh and this signal-driven sync both write
	# the same flow-field cell. A fence carries a speed_multiplier but lives on the
	# `fences` layer, so if we only inspected blocking_buildings we'd reset the cell to
	# 1.0 and clobber the fence slow the buildsystem just applied. Recompute the
	# effective multiplier across every speed-carrying layer instead.
	refresh_cell_speed(cell)


func refresh_cell_speed(cell: Vector2i) -> void:
	var flow: Node = _manager.flow
	if flow == null or not flow.has_method("set_cell_speed_multiplier"):
		return
	flow.call("set_cell_speed_multiplier", cell, effective_cell_speed_multiplier(cell))


func effective_cell_speed_multiplier(cell: Vector2i) -> float:
	var plantz: TileMapLayer = _manager.plantz
	var traversable_buildings: TileMapLayer = _manager.traversable_buildings
	var blocking_buildings: TileMapLayer = _manager.blocking_buildings
	var fences: TileMapLayer = _manager.fences
	var speed_multiplier: float = DEFAULT_TERRAIN_SPEED_MULTIPLIER
	# Permanent static features join the same minimum as logical plants and every speed-
	# carrying layer, so the slowest thing on the cell always wins.
	if _static_terrain_speed_by_cell.has(cell):
		speed_multiplier = minf(speed_multiplier, float(_static_terrain_speed_by_cell[cell]))
	var plant_manager: Node = _manager.plant_manager
	if plant_manager != null and plant_manager.has_method("get_plant_item_id"):
		var logical_plant_item_id: String = str(plant_manager.call("get_plant_item_id", cell))
		if logical_plant_item_id != "":
			var logical_plant_item_def: Dictionary = ItemCatalog.get_item_def(logical_plant_item_id)
			var logical_plant_multiplier: float = clampf(float(logical_plant_item_def.get("speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER)), 0.01, 1.0)
			speed_multiplier = minf(speed_multiplier, logical_plant_multiplier)
	for layer: TileMapLayer in [plantz, traversable_buildings, blocking_buildings, fences]:
		if layer == null or layer.get_cell_source_id(cell) < 0:
			continue
		var layer_item_id: String = ItemCatalog.get_placeable_id_for_tile(str(layer.name), layer.get_cell_atlas_coords(cell))
		if layer_item_id == "":
			continue
		var layer_item_def: Dictionary = ItemCatalog.get_item_def(layer_item_id)
		var layer_multiplier: float = clampf(float(layer_item_def.get("speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER)), 0.01, 1.0)
		speed_multiplier = minf(speed_multiplier, layer_multiplier)
	return speed_multiplier
