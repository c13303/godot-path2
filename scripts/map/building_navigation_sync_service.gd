extends RefCounted
class_name BuildingNavigationSyncService

# Owns the "building/fence/placeable effects -> flow & player navigation" synchronization
# extracted from BuildingManager. This service translates the current contents of the
# building tile layers into the flow node's extra-blocking-cell set, fence-blocking-cell
# set, per-cell player blocking, and per-cell speed multipliers. It never mutates the tile
# layers or performs placement/removal; BuildingManager keeps the source-of-truth state
# (the exported layers, the flow node) and thin compatibility wrappers, and this reaches
# back through _manager for all of it.
#
# Behavior note: this is an extraction only. Which items block flow, which block the
# player, fence slow behavior, the min/clamp speed logic, the layer order, and the
# missing-definition fallbacks are all preserved exactly as they were inline in
# BuildingManager.

const DEFAULT_TERRAIN_SPEED_MULTIPLIER: float = 1.0

var _manager: Node


func setup(manager: Node) -> void:
	_manager = manager


func sync_flow_extra_blocking_cells() -> void:
	var flow: Node = _manager.get("flow") as Node
	if flow == null or not flow.has_method("set_extra_blocking_cells"):
		return
	var blocking_buildings: TileMapLayer = _manager.get("blocking_buildings") as TileMapLayer
	var fences: TileMapLayer = _manager.get("fences") as TileMapLayer
	var cells: PackedVector2Array = PackedVector2Array()
	if blocking_buildings != null:
		for raw_cell: Variant in blocking_buildings.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
			if not bool(_manager.call("_building_cell_blocks_movement", cell)):
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


func building_item_blocks_flow(item_id: String) -> bool:
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if item_def.is_empty():
		return false
	if bool(item_def.get("blocks_agents", false)):
		return true
	if str(item_def.get("target_layer", "")) != "blocking_buildings":
		return false
	return bool(item_def.get("blocks_movement", false)) or bool(item_def.get("isWall", false))


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
	var flow: Node = _manager.get("flow") as Node
	var blocking_buildings: TileMapLayer = _manager.get("blocking_buildings") as TileMapLayer
	if flow == null or not flow.has_method("set_cell_blocked") or blocking_buildings == null:
		return
	for raw_cell: Variant in blocking_buildings.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		var item_id: String = blocking_building_item_id_at_cell(cell)
		if item_id == "" or building_item_blocks_player(item_id):
			set_player_cell_blocked(cell, true)


func set_player_cell_blocked(cell: Vector2i, blocked: bool) -> void:
	var flow: Node = _manager.get("flow") as Node
	if flow == null or not flow.has_method("set_cell_blocked"):
		return
	flow.call("set_cell_blocked", cell, blocked)


func blocking_building_item_id_at_cell(cell: Vector2i) -> String:
	var blocking_buildings: TileMapLayer = _manager.get("blocking_buildings") as TileMapLayer
	if blocking_buildings == null or blocking_buildings.get_cell_source_id(cell) < 0:
		return ""
	var atlas: Vector2i = blocking_buildings.get_cell_atlas_coords(cell)
	return ItemCatalog.get_placeable_id_for_tile(str(blocking_buildings.name), atlas)


func sync_building_cell_speed(cell: Vector2i, item_id: String) -> void:
	var flow: Node = _manager.get("flow") as Node
	if flow == null or not flow.has_method("set_cell_speed_multiplier"):
		return
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if item_def.is_empty() or not item_def.has("speed_multiplier"):
		return
	# The buildsystem's terrain-speed refresh and this signal-driven sync both write
	# the same flow-field cell. A fence carries a speed_multiplier but lives on the
	# `fences` layer, so if we only inspected blocking_buildings we'd reset the cell to
	# 1.0 and clobber the fence slow the buildsystem just applied. Recompute the
	# effective multiplier across every speed-carrying layer instead.
	flow.call("set_cell_speed_multiplier", cell, effective_cell_speed_multiplier(cell))


func effective_cell_speed_multiplier(cell: Vector2i) -> float:
	var plantz: TileMapLayer = _manager.get("plantz") as TileMapLayer
	var traversable_buildings: TileMapLayer = _manager.get("traversable_buildings") as TileMapLayer
	var blocking_buildings: TileMapLayer = _manager.get("blocking_buildings") as TileMapLayer
	var fences: TileMapLayer = _manager.get("fences") as TileMapLayer
	var speed_multiplier: float = DEFAULT_TERRAIN_SPEED_MULTIPLIER
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
