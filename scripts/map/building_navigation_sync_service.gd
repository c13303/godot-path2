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
# Blocking behavior, layer order, and missing-definition fallbacks remain the same as the
# original BuildingManager implementation. Speed contributions now use the shared
# source-aware composition rule so slowdowns and speedups can coexist predictably.

const DEFAULT_TERRAIN_SPEED_MULTIPLIER: float = 1.0
const DEFAULT_TERRAIN_SPEED_CHANNEL: int = 0
const STATIC_TERRAIN_SOURCE_PREFIX: String = "static:"
const CELL_TERRAIN_SOURCE_PREFIX: String = "cell:"
const WATER_TERRAIN_SOURCE: StringName = &"water"
const WATER_TERRAIN_SPEED_MIN_MULTIPLIER: float = 0.05
const WATER_TERRAIN_SPEED_MAX_MULTIPLIER: float = 4.0

var _manager: BuildingManager
var _terrain_speed: RefCounted = null


func setup(manager: BuildingManager, terrain_speed: RefCounted) -> void:
	_manager = manager
	_terrain_speed = terrain_speed
	_terrain_speed.setup(_get_steering_system())


func sync_all_terrain_speed_cells() -> void:
	if _terrain_speed == null:
		return
	_terrain_speed.set_steering(_get_steering_system())
	_terrain_speed.clear_local_contributions()
	_terrain_speed.clear_all_native_channels()
	var touched: Dictionary = {}
	for layer: TileMapLayer in [_manager.plantz, _manager.blocking_buildings, _manager.fences]:
		if layer == null:
			continue
		for raw_cell: Variant in layer.get_used_cells():
			touched[raw_cell as Vector2i] = true
	var plant_manager: Node = _manager.plant_manager
	if plant_manager != null and plant_manager.has_method("get_plant_cells"):
		var plant_cells: Array = plant_manager.call("get_plant_cells") as Array
		for raw_cell: Variant in plant_cells:
			touched[raw_cell as Vector2i] = true
	var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
	if building_objects != null:
		for runtime_cell: Vector2i in building_objects.get_building_cells():
			touched[runtime_cell] = true
	for raw_cell: Variant in touched.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var multipliers: Vector3 = effective_cell_speed_profile(cell)
		_terrain_speed.set_cell_contribution_triplet(
			cell,
			StringName(CELL_TERRAIN_SOURCE_PREFIX + str(cell)),
			multipliers.x,
			multipliers.y,
			multipliers.z,
			false
		)
	# Water carries its slowdown on the WaterSources layer rather than a catalog def, so it is not
	# part of the per-cell composition above and has to be re-registered after the clear.
	_sync_water_terrain_speed_cells()
	_terrain_speed.upload_all_channels()


## Registers the water layer's slowdown on every water cell. Water is authored on WaterSources
## (player_slowdown), not in the item catalog, so it needs its own pass; it applies equally to the
## player and to the crowd. Called from sync_all_terrain_speed_cells, which clears local
## contributions first and would otherwise drop the water entry.
func _sync_water_terrain_speed_cells() -> void:
	var watersources: WaterSources = _manager.watersources
	if watersources == null or _terrain_speed == null:
		return
	var multiplier: float = clampf(
		watersources.player_slowdown,
		WATER_TERRAIN_SPEED_MIN_MULTIPLIER,
		WATER_TERRAIN_SPEED_MAX_MULTIPLIER
	)
	for raw_cell: Variant in watersources.get_used_cells():
		_terrain_speed.set_cell_contribution_triplet(
			raw_cell as Vector2i,
			WATER_TERRAIN_SOURCE,
			multiplier,
			multiplier,
			multiplier,
			false
		)


## Registers (or clears) a permanent world feature's speed multipliers for one cell, then
## refreshes only that cell's effective terrain speed. `multiplier` applies to every agent,
## `player_multiplier` only to the player, so a feature can slow the crowd while leaving the
## player at full speed (bamboo passes 1.0 there, mirroring the rose rule). The entry is
## removed only when the cell slows nobody. This never rebuilds a flow field:
## refresh_cell_speed writes the shared native terrain-speed map that every steered agent
## reads live.
func set_static_terrain_speed_multiplier(cell: Vector2i, multiplier: float, player_multiplier: float) -> void:
	_terrain_speed.set_steering(_get_steering_system())
	_terrain_speed.set_cell_contribution_pair(
		cell,
		StringName(STATIC_TERRAIN_SOURCE_PREFIX + str(cell)),
		multiplier,
		player_multiplier
	)


func set_static_terrain_speed_multipliers(
	cells: Array[Vector2i],
	source_id: StringName,
	multiplier: float,
	player_multiplier: float
) -> void:
	if cells.is_empty() or source_id == &"":
		return
	_terrain_speed.set_steering(_get_steering_system())
	_terrain_speed.set_cells_contribution_pair(
		cells,
		source_id,
		multiplier,
		player_multiplier
	)


func sync_flow_extra_blocking_cells() -> void:
	var flow: Node = _manager.flow
	if flow == null or not flow.has_method("set_extra_blocking_cells"):
		return
	var blocking_buildings: TileMapLayer = _manager.blocking_buildings
	var wallz: TileMapLayer = _manager.wallz
	var fences: TileMapLayer = _manager.fences
	var cells: PackedVector2Array = PackedVector2Array()
	if blocking_buildings != null:
		for raw_cell: Variant in blocking_buildings.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
			if not _manager._building_cell_blocks_movement(cell):
				continue
			cells.append(Vector2(float(cell.x), float(cell.y)))
	# The static navigation grid is only uploaded once at level load
	# (NavigationRuntime.compute_distance_field_global, called from FlowFieldCode._ready).
	# Player-built walls land on this same "wallz" layer at runtime but nothing re-uploads
	# it afterwards, so a wall placed mid-game never reaches the native flow-field grid
	# through the static path. Every wallz cell must therefore be re-pushed here, on the
	# one channel every group flow (monsters, clients, the preview) already blocks against.
	if wallz != null:
		for raw_cell: Variant in wallz.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
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
	return scene.get_node_or_null("CPP/CrowdRuntime")


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
	var multipliers: Vector3 = effective_cell_speed_profile(cell)
	_terrain_speed.set_steering(_get_steering_system())
	_terrain_speed.set_cell_contribution_triplet(
		cell,
		StringName(CELL_TERRAIN_SOURCE_PREFIX + str(cell)),
		multipliers.x,
		multipliers.y,
		multipliers.z
	)


## Effective terrain speed on a cell: x = every agent, y = the player. The two differ on
## cells modified only by a def that opts out of affecting the player (a rose), which the
## player then walks at full speed. Composition is delegated to TerrainSpeedModifierService,
## so slowdown priority and speed-up selection have one authoritative implementation.
func effective_cell_speed_multipliers(cell: Vector2i) -> Vector2:
	var profile: Vector3 = effective_cell_speed_profile(cell)
	return Vector2(profile.x, profile.y)


## Effective terrain speed profile: x = ordinary agents, y = player,
## z = bigmonster. The third channel normally mirrors x and only differs for
## placeables with an explicit big-monster override such as ronce.
func effective_cell_speed_profile(cell: Vector2i) -> Vector3:
	var plantz: TileMapLayer = _manager.plantz
	var blocking_buildings: TileMapLayer = _manager.blocking_buildings
	var fences: TileMapLayer = _manager.fences
	var speed_multipliers: Array[float] = []
	var player_speed_multipliers: Array[float] = []
	var big_monster_speed_multipliers: Array[float] = []
	var plant_manager: Node = _manager.plant_manager
	if plant_manager != null and plant_manager.has_method("get_plant_item_id"):
		var logical_plant_item_id: String = str(plant_manager.call("get_plant_item_id", cell))
		if logical_plant_item_id != "":
			var logical_plant_item_def: Dictionary = ItemCatalog.get_item_def(logical_plant_item_id)
			speed_multipliers.append(PlaceableNavImpact.def_speed_multiplier(logical_plant_item_def))
			player_speed_multipliers.append(PlaceableNavImpact.def_player_speed_multiplier(logical_plant_item_def))
			big_monster_speed_multipliers.append(PlaceableNavImpact.def_big_monster_speed_multiplier(logical_plant_item_def))
	for layer: TileMapLayer in [plantz, blocking_buildings, fences]:
		if layer == null or layer.get_cell_source_id(cell) < 0:
			continue
		var layer_item_id: String = ItemCatalog.get_placeable_id_for_tile(str(layer.name), layer.get_cell_atlas_coords(cell))
		if layer_item_id == "":
			continue
		var layer_item_def: Dictionary = ItemCatalog.get_item_def(layer_item_id)
		speed_multipliers.append(PlaceableNavImpact.def_speed_multiplier(layer_item_def))
		player_speed_multipliers.append(PlaceableNavImpact.def_player_speed_multiplier(layer_item_def))
		big_monster_speed_multipliers.append(PlaceableNavImpact.def_big_monster_speed_multiplier(layer_item_def))
	var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
	if building_objects != null:
		var runtime_item_id: String = building_objects.get_placeable_item_id(cell)
		if runtime_item_id != "":
			var runtime_item_def: Dictionary = ItemCatalog.get_item_def(runtime_item_id)
			speed_multipliers.append(PlaceableNavImpact.def_speed_multiplier(runtime_item_def))
			player_speed_multipliers.append(PlaceableNavImpact.def_player_speed_multiplier(runtime_item_def))
			big_monster_speed_multipliers.append(PlaceableNavImpact.def_big_monster_speed_multiplier(runtime_item_def))
	if _terrain_speed == null:
		return Vector3(DEFAULT_TERRAIN_SPEED_MULTIPLIER, DEFAULT_TERRAIN_SPEED_MULTIPLIER, DEFAULT_TERRAIN_SPEED_MULTIPLIER)
	return Vector3(
		_terrain_speed.compose_multipliers(speed_multipliers),
		_terrain_speed.compose_multipliers(player_speed_multipliers),
		_terrain_speed.compose_multipliers(big_monster_speed_multipliers)
	)


## All-agent terrain speed on a cell. Kept for the nav-speed telemetry / BuildingManager
## façade, which report what the crowd walks at.
func effective_cell_speed_multiplier(cell: Vector2i) -> float:
	if _terrain_speed != null:
		return _terrain_speed.effective_multiplier(cell, DEFAULT_TERRAIN_SPEED_CHANNEL)
	return effective_cell_speed_multipliers(cell).x
