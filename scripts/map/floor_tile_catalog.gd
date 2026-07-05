extends RefCounted
class_name FloorTileCatalog

## Reference atlas coordinates for gameplay-relevant floor tiles.
## Keep these names in sync with the floor TileMapLayer tileset usage, so gameplay
## code does not need to guess coordinates by inspecting the tilemap image.

const GRASS_GREEN_FLOOR_ATLAS: Vector2i = Vector2i(11, 6)
const DRY_GROUND_FLOOR_ATLAS: Vector2i = Vector2i(12, 6)
