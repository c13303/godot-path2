extends RefCounted
class_name PathPreviewRoutePlanner

# Turns a prepared flow group into the exact chain of tile centers its route visits, so the
# path preview can travel through cell centers instead of drifting along tile edges.
#
# The native field stores a Dijkstra route cost per cell: 0.0 at the goal, +INF where
# unreachable, and one step of +1.0 (orthogonal) or +1.4142 (diagonal) per cell away from
# it. Walking that cost downhill from the spawner cell replays the same route the field's
# own directions encode, one whole cell at a time. Sampling the field's interpolated
# direction instead is what used to smear the preview along tile edges: it blends the four
# cells around the sample point, so it never resolves to "this cell, then that cell".
#
# Read-only: this never asks for a flow group, a rebuild, or any topology work. It is built
# once per prepared route by PathPreviewController, not per frame and not per arrow.

const IDLE_GROUP: int = 0
const GOAL_ROUTE_COST: float = 0.001
# One Dijkstra step, matched against the field's own step costs (see compute_costs in
# flow_field_native.cpp). The tolerance only absorbs float noise, not a real step.
const ORTHOGONAL_STEP_COST: float = 1.0
const DIAGONAL_STEP_COST: float = 1.41421356237
const COST_STEP_EPSILON: float = 0.01
# A route longer than this is a bug, not a map: bail rather than walk forever.
const MAX_ROUTE_CELLS: int = 4096

const STEP_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
	Vector2i(1, 1),
	Vector2i(-1, 1),
	Vector2i(1, -1),
	Vector2i(-1, -1),
]


# World-space tile centers from start_cell to goal_cell along the group's prepared route.
# Empty when the group's flow is not ready, the route is blocked, or the walk fails to land
# on goal_cell — callers treat an empty path as "nothing to draw yet".
static func build_cell_center_path(
	flow: Node,
	manager: BuildingManager,
	group_id: int,
	start_cell: Vector2i,
	goal_cell: Vector2i
) -> PackedVector2Array:
	var path: PackedVector2Array = PackedVector2Array()
	if manager == null or group_id <= IDLE_GROUP:
		return path
	if flow == null or not flow.has_method("group_route_cost_at_world"):
		return path
	var cell: Vector2i = start_cell
	var cost: float = _route_cost_at_cell(flow, manager, group_id, cell)
	if not is_finite(cost):
		return path
	path.append(manager.cell_center(cell))
	while cell != goal_cell:
		if path.size() >= MAX_ROUTE_CELLS:
			return PackedVector2Array()
		var next_cell: Vector2i = _next_route_cell(flow, manager, group_id, cell, cost)
		if next_cell == cell:
			# Dead end before the goal: the route the descriptor advertises is not
			# walkable right now, so there is no honest path to draw.
			return PackedVector2Array()
		cell = next_cell
		cost = _route_cost_at_cell(flow, manager, group_id, cell)
		path.append(manager.cell_center(cell))
	return path


# The neighbour the field's own Dijkstra expanded this cell from: strictly cheaper, and
# exactly one step cheaper. Returns from_cell when the route dead-ends or has arrived.
static func _next_route_cell(
	flow: Node,
	manager: BuildingManager,
	group_id: int,
	from_cell: Vector2i,
	from_cost: float
) -> Vector2i:
	if from_cost <= GOAL_ROUTE_COST:
		return from_cell
	var best_cell: Vector2i = from_cell
	var best_cost: float = from_cost
	for step: Vector2i in STEP_DIRECTIONS:
		var is_diagonal: bool = step.x != 0 and step.y != 0
		var neighbour: Vector2i = from_cell + step
		var neighbour_cost: float = _route_cost_at_cell(flow, manager, group_id, neighbour)
		if not is_finite(neighbour_cost) or neighbour_cost >= from_cost:
			continue
		# Cells outside the field read back as cost 0.0, which would otherwise look like
		# the goal. Requiring the neighbour to sit exactly one step below this cell keeps
		# the walk on cells the field actually computed.
		var step_cost: float = DIAGONAL_STEP_COST if is_diagonal else ORTHOGONAL_STEP_COST
		if absf(from_cost - (neighbour_cost + step_cost)) > COST_STEP_EPSILON:
			continue
		# The field only relaxes a diagonal when both orthogonal neighbours are open, so a
		# diagonal that clips a wall corner was never part of the real route.
		if is_diagonal:
			if not _cell_is_reachable(flow, manager, group_id, from_cell + Vector2i(step.x, 0)):
				continue
			if not _cell_is_reachable(flow, manager, group_id, from_cell + Vector2i(0, step.y)):
				continue
		if neighbour_cost < best_cost:
			best_cost = neighbour_cost
			best_cell = neighbour
	return best_cell


static func _cell_is_reachable(flow: Node, manager: BuildingManager, group_id: int, cell: Vector2i) -> bool:
	return is_finite(_route_cost_at_cell(flow, manager, group_id, cell))


static func _route_cost_at_cell(flow: Node, manager: BuildingManager, group_id: int, cell: Vector2i) -> float:
	return float(flow.call("group_route_cost_at_world", group_id, manager.cell_center(cell)))
