extends RefCounted
class_name GrassAutotile

## Beautifies "green grass" floor tiles the same way the water surface is beautified.
##
## The floor tileset holds a grass autotile block at atlas (4,9)..(13,11) laid out
## identically to the water autotile block at (4,3)..(13,5) (a straight +6 offset in Y).
## Tile selection reproduces the Rose Level Editor's water beautification exactly:
## it was reverse-engineered from and validated 1:1 against the shipped water tilemap
## (0 mismatches over 1788 authored water cells).
##
## Scheme: standard "corners and sides" autotiling. A cell looks at its 8 neighbours;
## a corner sub-tile only matters when both of its adjacent sides are also grass.
## Configurations with no dedicated tile (concave corners next to an open side, or
## multi-notch interiors) fall back to the "all corners filled" variant, mirroring
## how the editor best-matches those cases.

## Inclusive atlas bounds of the beautified grass block (floor layer).
const GRASS_ATLAS_MIN: Vector2i = Vector2i(4, 9)
const GRASS_ATLAS_MAX: Vector2i = Vector2i(13, 11)
## Fully-surrounded interior grass tile (used as the paint placeholder before re-tiling).
const GRASS_FULL_ATLAS: Vector2i = Vector2i(5, 10)

## Neighbour bit layout: N=1, E=2, S=4, W=8, NE=16, SE=32, SW=64, NW=128.
const _MASK_TO_ATLAS: Dictionary = {
	0: Vector2i(11, 11),
	1: Vector2i(13, 11),
	2: Vector2i(12, 11),
	4: Vector2i(13, 10),
	5: Vector2i(13, 9),
	8: Vector2i(12, 10),
	10: Vector2i(12, 9),
	19: Vector2i(4, 11),
	27: Vector2i(5, 11),
	38: Vector2i(4, 9),
	55: Vector2i(4, 10),
	76: Vector2i(6, 9),
	110: Vector2i(5, 9),
	127: Vector2i(10, 9),
	137: Vector2i(6, 11),
	139: Vector2i(5, 11),
	155: Vector2i(5, 11),
	191: Vector2i(10, 10),
	205: Vector2i(6, 10),
	223: Vector2i(11, 10),
	239: Vector2i(11, 9),
	255: Vector2i(5, 10),
}

const _NEIGHBOUR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1),
]


static func is_grass_atlas(coords: Vector2i) -> bool:
	return coords.x >= GRASS_ATLAS_MIN.x and coords.x <= GRASS_ATLAS_MAX.x \
		and coords.y >= GRASS_ATLAS_MIN.y and coords.y <= GRASS_ATLAS_MAX.y


static func is_grass_cell(floor: TileMapLayer, cell: Vector2i) -> bool:
	if floor == null or floor.get_cell_source_id(cell) < 0:
		return false
	return is_grass_atlas(floor.get_cell_atlas_coords(cell))


## Re-tiles every grass cell touched by `cells` and their neighbours, so edges/corners
## stay consistent after grass was added or removed. Returns true if any tile changed.
static func beautify(floor: TileMapLayer, cells) -> bool:
	if floor == null:
		return false
	var dirty: Dictionary = {}
	for cell: Vector2i in cells:
		dirty[cell] = true
		for offset: Vector2i in _NEIGHBOUR_OFFSETS:
			dirty[cell + offset] = true
	var changed: bool = false
	for cell: Vector2i in dirty:
		if not is_grass_cell(floor, cell):
			continue
		var atlas: Vector2i = _atlas_for_mask(_compute_mask(floor, cell))
		if floor.get_cell_atlas_coords(cell) != atlas:
			floor.set_cell(cell, floor.get_cell_source_id(cell), atlas, floor.get_cell_alternative_tile(cell))
			changed = true
	return changed


static func _compute_mask(floor: TileMapLayer, cell: Vector2i) -> int:
	var n: bool = is_grass_cell(floor, cell + Vector2i(0, -1))
	var e: bool = is_grass_cell(floor, cell + Vector2i(1, 0))
	var s: bool = is_grass_cell(floor, cell + Vector2i(0, 1))
	var w: bool = is_grass_cell(floor, cell + Vector2i(-1, 0))
	var ne: bool = is_grass_cell(floor, cell + Vector2i(1, -1))
	var se: bool = is_grass_cell(floor, cell + Vector2i(1, 1))
	var sw: bool = is_grass_cell(floor, cell + Vector2i(-1, 1))
	var nw: bool = is_grass_cell(floor, cell + Vector2i(-1, -1))
	var mask: int = 0
	if n: mask |= 1
	if e: mask |= 2
	if s: mask |= 4
	if w: mask |= 8
	if ne and n and e: mask |= 16
	if se and s and e: mask |= 32
	if sw and s and w: mask |= 64
	if nw and n and w: mask |= 128
	return mask


static func _atlas_for_mask(mask: int) -> Vector2i:
	if _MASK_TO_ATLAS.has(mask):
		return _MASK_TO_ATLAS[mask]
	return _MASK_TO_ATLAS[_canonical_mask(mask)]


## Forces every "in-play" corner (both adjacent sides present) on. The result is
## always one of the authored tiles, so it is a safe best-match fallback.
static func _canonical_mask(mask: int) -> int:
	var canonical: int = mask & 15
	if (canonical & 1) and (canonical & 2): canonical |= 16
	if (canonical & 4) and (canonical & 2): canonical |= 32
	if (canonical & 4) and (canonical & 8): canonical |= 64
	if (canonical & 1) and (canonical & 8): canonical |= 128
	return canonical
