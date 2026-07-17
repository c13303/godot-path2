extends RefCounted
class_name IrrigationSource

## One irrigation center (a reservoir or a watermelon) and the wall-aware grass patch
## it owns.
##
## The patch is a flood fill from `center`, not a plain circle, so grass can never show
## up detached from the center blob: a cell only joins the patch if the fill reaches it
## from the center without spreading through a wall or through water. Range is spread
## distance, so grass that has to wrap around a wall fades out with the length of the
## detour instead of jumping across it.
##
## Steps are weighted (orthogonal 1, diagonal sqrt(2)). That keeps an unobstructed patch
## round, matching the circle this replaced; an unweighted fill would have turned every
## patch into a diamond. A diagonal step may not cut a wall corner, otherwise grass would
## leak through diagonal wall joints and grow the detached blobs this fill exists to
## prevent.
##
## Cells are bucketed into integer rings by spread distance. Growing reveals rings
## outwards one per tick and shrinking peels them back off in reverse, which is what
## makes the patch animate. The fill is computed once up front: it is bounded by the
## radius (a few hundred cells at most) and runs only when a source is placed, never
## per frame.

const ORTHOGONAL_STEP_COST: float = 1.0
const DIAGONAL_STEP_COST: float = 1.4142135623730951

# Guards the float compares against accumulated rounding, so a cell that lands exactly
# on the radius is not dropped and near-equal costs do not re-trigger relaxation.
const _COST_EPSILON: float = 0.0001

const _ORTHOGONAL_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
]
const _DIAGONAL_OFFSETS: Array[Vector2i] = [
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1),
]

var center: Vector2i
## Floor atlas the patch's cells are painted back to when it shrinks.
var restore_atlas: Vector2i
## Ring the patch reaches once fully grown.
var radius: int = 0
## Ring the patch is painted out to right now. -1 = nothing painted yet.
var current_radius: int = -1
## Ring the patch animates towards. -1 = the source is being removed entirely.
var target_radius: int = 0

# Spread distance of every reachable cell, bucketed to an integer ring.
var _ring_by_cell: Dictionary = {}
# _cells_by_ring[d] holds the cells of ring d, as Array[Vector2i].
var _cells_by_ring: Array = []


## `is_blocked` takes a Vector2i and returns true for cells the fill may not enter.
func _init(p_center: Vector2i, p_radius: int, p_restore_atlas: Vector2i, is_blocked: Callable) -> void:
	center = p_center
	radius = maxi(0, p_radius)
	restore_atlas = p_restore_atlas
	target_radius = radius
	_flood_fill(is_blocked)


## True when this patch reaches `cell` at the radius it is currently grown to.
func covers(cell: Vector2i) -> bool:
	if current_radius < 0 or not _ring_by_cell.has(cell):
		return false
	return int(_ring_by_cell[cell]) <= current_radius


func ring_cells(ring: int) -> Array[Vector2i]:
	if ring < 0 or ring >= _cells_by_ring.size():
		var empty: Array[Vector2i] = []
		return empty
	var cells: Array[Vector2i] = _cells_by_ring[ring]
	return cells


func is_animating() -> bool:
	return current_radius != target_radius


## Grows one ring outwards and returns the cells that ring just gained.
func grow_one_ring() -> Array[Vector2i]:
	current_radius += 1
	return ring_cells(current_radius)


## Drops the outermost ring and returns its cells. `current_radius` reaches -1 once the
## whole patch is gone.
func shrink_one_ring() -> Array[Vector2i]:
	var cells: Array[Vector2i] = ring_cells(current_radius)
	current_radius -= 1
	return cells


func _flood_fill(is_blocked: Callable) -> void:
	_cells_by_ring.resize(radius + 1)
	for ring: int in range(radius + 1):
		var ring_bucket: Array[Vector2i] = []
		_cells_by_ring[ring] = ring_bucket
	var limit: float = float(radius)
	# The center seeds the fill without a blocked test: a center always irrigates from where
	# it stands, even when its own cell is one the fill would not otherwise spread into.
	var cost_by_cell: Dictionary = {}
	cost_by_cell[center] = 0.0
	var pending: Array[Vector2i] = [center]
	while not pending.is_empty():
		var cell: Vector2i = pending.pop_back()
		var cost: float = float(cost_by_cell[cell])
		for offset: Vector2i in _ORTHOGONAL_OFFSETS:
			_relax(cell + offset, cost + ORTHOGONAL_STEP_COST, limit, cost_by_cell, pending, is_blocked)
		for offset: Vector2i in _DIAGONAL_OFFSETS:
			if _cuts_wall_corner(cell, offset, is_blocked):
				continue
			_relax(cell + offset, cost + DIAGONAL_STEP_COST, limit, cost_by_cell, pending, is_blocked)
	for raw_cell: Variant in cost_by_cell:
		var cell: Vector2i = raw_cell as Vector2i
		var ring: int = clampi(int(ceil(float(cost_by_cell[cell]) - _COST_EPSILON)), 0, radius)
		_ring_by_cell[cell] = ring
		var ring_bucket: Array[Vector2i] = _cells_by_ring[ring]
		ring_bucket.append(cell)


func _relax(
	cell: Vector2i,
	cost: float,
	limit: float,
	cost_by_cell: Dictionary,
	pending: Array[Vector2i],
	is_blocked: Callable
) -> void:
	if cost > limit + _COST_EPSILON:
		return
	if cost_by_cell.has(cell) and float(cost_by_cell[cell]) <= cost + _COST_EPSILON:
		return
	cost_by_cell[cell] = cost
	# A blocked cell joins the patch but is terminal: the fill never spreads onwards from
	# it. Joining keeps grass painted under walls the way the plain circle did, so tearing
	# a wall down later does not reveal a dry hole and the autotiled edge runs under the
	# wall instead of stopping at it. Not spreading onwards is what keeps the patch from
	# growing a detached blob on the far side.
	if is_blocked.call(cell):
		return
	pending.push_back(cell)


# A diagonal step is only legal when both orthogonals it squeezes between are open,
# so the fill cannot slip through the joint where two walls touch corner to corner.
func _cuts_wall_corner(cell: Vector2i, offset: Vector2i, is_blocked: Callable) -> bool:
	if bool(is_blocked.call(cell + Vector2i(offset.x, 0))):
		return true
	return bool(is_blocked.call(cell + Vector2i(0, offset.y)))
