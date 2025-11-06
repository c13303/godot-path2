extends Node
class_name SteeringSystem

## Module de steering commun à tous les agents
## Fournit une interface unique, indépendante du FlowField ou de A*

@export var neighbor_radius: float = 16.0
@export var weight_separation: float = 1
@export var weight_alignment: float = 0.6
@export var weight_cohesion: float = 0.4
@onready var grid: SpatialGrid = SpatialGrid.new()

func _ready() -> void:
	add_child(grid)



func compute(agent: Node2D, neighbors: Array, flow_dir: Vector2) -> Vector2:
	const MAX_NEIGHBORS: int = 64

	var sep_force: Vector2 = Vector2.ZERO
	var count: int = 0

	var local_neighbors: Array = get_neighbors(agent, neighbors)
	for other in local_neighbors:
		if other == null:
			continue
		var diff: Vector2 = agent.global_position - other.global_position
		var dist: float = diff.length()
		if dist > 0.0:
			var falloff: float = 1.0 - min(dist / neighbor_radius, 1.0)
			sep_force += diff.normalized() * falloff
			count += 1
			if count >= MAX_NEIGHBORS:
				break

	if count > 0:
		sep_force /= float(count)
		sep_force = sep_force.normalized() * weight_separation

	var result: Vector2 = (flow_dir + sep_force).normalized()

	var prev_dir: Vector2 = Vector2.ZERO
	if agent.velocity.length() > 0.0:
		prev_dir = agent.velocity.normalized()
	else:
		prev_dir = flow_dir.normalized()

	result = prev_dir.lerp(result, 0.25).normalized()

	return result



func get_neighbors(agent: Node2D, all_agents: Array) -> Array:
	grid.update(agent)
	return grid.neighbors_at(agent.global_position, 1)
