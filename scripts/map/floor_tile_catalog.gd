extends RefCounted
class_name FloorTileCatalog

## Reference atlas coordinates for gameplay-relevant floor tiles.
## Keep these names in sync with the floor TileMapLayer tileset usage, so gameplay
## code does not need to guess coordinates by inspecting the tilemap image.

const GRASS_GREEN_FLOOR_ATLAS: Vector2i = Vector2i(11, 6)
const DRY_GROUND_FLOOR_ATLAS: Vector2i = Vector2i(12, 6)


static func is_wet_grass_atlas(atlas_coords: Vector2i) -> bool:
	return GrassAutotile.is_grass_atlas(atlas_coords)


static func is_dry_grass_atlas(atlas_coords: Vector2i) -> bool:
	return atlas_coords == DRY_GROUND_FLOOR_ATLAS


static func is_buildable_floor_atlas(atlas_coords: Vector2i) -> bool:
	return is_wet_grass_atlas(atlas_coords) or is_dry_grass_atlas(atlas_coords)


static func is_buildable_floor_cell(layer: TileMapLayer, cell: Vector2i) -> bool:
	if layer == null or layer.get_cell_source_id(cell) < 0:
		return false
	return is_buildable_floor_atlas(layer.get_cell_atlas_coords(cell))
