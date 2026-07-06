extends RefCounted
class_name BuildDirectionRules

# Pure, stateless build direction / orientation rules shared by build-mode state and
# placement. Owns the canonical orientation constants (DIRECTION_* facings and the
# TileMap TILE_TRANSFORM_* flags), the forward/backward direction cycle, directional-
# placeable detection, and the direction -> TileMap alternative mapping.
#
# This class holds no mutable state: BuildModeStateController still owns the current
# _build_direction value, and BuildPlacementService still owns placement commits. Only
# the pure rules live here so the two callers stop duplicating them.

const DIRECTION_RIGHT: Vector2i = Vector2i(1, 0)
const DIRECTION_DOWN: Vector2i = Vector2i(0, 1)
const DIRECTION_LEFT: Vector2i = Vector2i(-1, 0)
const DIRECTION_UP: Vector2i = Vector2i(0, -1)

const TILE_TRANSFORM_FLIP_H: int = 4096
const TILE_TRANSFORM_FLIP_V: int = 8192
const TILE_TRANSFORM_TRANSPOSE: int = 16384


static func is_directional_placeable(placeable_def: Dictionary) -> bool:
	return bool(placeable_def.get("directional", false))


# Forward rotation order: RIGHT -> DOWN -> LEFT -> UP -> RIGHT.
static func next_direction(direction: Vector2i) -> Vector2i:
	if direction == DIRECTION_RIGHT:
		return DIRECTION_DOWN
	if direction == DIRECTION_DOWN:
		return DIRECTION_LEFT
	if direction == DIRECTION_LEFT:
		return DIRECTION_UP
	return DIRECTION_RIGHT


# Backward rotation order: RIGHT -> UP -> LEFT -> DOWN -> RIGHT.
static func previous_direction(direction: Vector2i) -> Vector2i:
	if direction == DIRECTION_RIGHT:
		return DIRECTION_UP
	if direction == DIRECTION_UP:
		return DIRECTION_LEFT
	if direction == DIRECTION_LEFT:
		return DIRECTION_DOWN
	return DIRECTION_RIGHT


# Maps a build direction to the TileMap alternative (transform flags) used when
# committing a directional placeable. RIGHT is the identity (0).
static func alternative_from_direction(direction: Vector2i) -> int:
	if direction == DIRECTION_LEFT:
		return TILE_TRANSFORM_FLIP_H | TILE_TRANSFORM_FLIP_V
	if direction == DIRECTION_DOWN:
		return TILE_TRANSFORM_TRANSPOSE | TILE_TRANSFORM_FLIP_H
	if direction == DIRECTION_UP:
		return TILE_TRANSFORM_TRANSPOSE | TILE_TRANSFORM_FLIP_V
	return 0
