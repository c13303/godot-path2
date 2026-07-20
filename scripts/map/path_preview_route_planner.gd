extends RefCounted
class_name PathPreviewRoutePlanner

# Turns a prepared flow group into the exact chain of tile centers its route visits, so the
# path preview can travel through cell centers instead of drifting along tile edges.
#
# The native group field stores both a Dijkstra route cost and the exact selected outgoing
# direction for each cell. Following that stored direction is required for directed edges
# such as client one-way tiles: route costs alone cannot prove that a cheaper neighbouring
# cell is connected by a legal outgoing edge. Directions are sampled at tile centers and
# converted to whole-cell steps, so the preview remains a chain of tile centers.
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
	if (
		flow == null
		or not flow.has_method("group_route_cost_at_world")
		or not flow.has_method("compute_group_flow_dir")
	):
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


# Follows the exact outgoing direction stored in the group field. The route-cost check is
# retained as fail-closed validation that the sampled step belongs to this ready route.
# Returns from_cell when the route dead-ends or has arrived.
static func _next_route_cell(
	flow: Node,
	manager: BuildingManager,
	group_id: int,
	from_cell: Vector2i,
	from_cost: float
) -> Vector2i:
	if from_cost <= GOAL_ROUTE_COST:
		return from_cell
	var direction: Vector2 = flow.call(
		"compute_group_flow_dir",
		group_id,
		manager.cell_center(from_cell)
	) as Vector2
	if not is_finite(direction.x) or not is_finite(direction.y):
		return from_cell
	var step: Vector2i = Vector2i(roundi(direction.x), roundi(direction.y))
	if step == Vector2i.ZERO or absi(step.x) > 1 or absi(step.y) > 1:
		return from_cell
	var next_cell: Vector2i = from_cell + step
	var next_cost: float = _route_cost_at_cell(flow, manager, group_id, next_cell)
	if not is_finite(next_cost) or next_cost >= from_cost:
		return from_cell
	var is_diagonal: bool = step.x != 0 and step.y != 0
	var step_cost: float = DIAGONAL_STEP_COST if is_diagonal else ORTHOGONAL_STEP_COST
	if absf(from_cost - (next_cost + step_cost)) > COST_STEP_EPSILON:
		return from_cell
	return next_cell


static func _route_cost_at_cell(flow: Node, manager: BuildingManager, group_id: int, cell: Vector2i) -> float:
	return float(flow.call("group_route_cost_at_world", group_id, manager.cell_center(cell)))
