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

func get_wall_avoidance(agent: Node2D) -> Vector2:
	if not agent.has_meta("flow_ref"):
		return Vector2.ZERO

	var flow: FlowField = agent.get_meta("flow_ref")
	if flow == null:
		return Vector2.ZERO

	var pos: Vector2i = flow.world_to_cell(agent.global_position)
	var repel: Vector2 = Vector2.ZERO
	var count: int = 0
	var radius: int = 2

	for dx in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			var c: Vector2i = pos + Vector2i(dx, dy)
			var dir: Vector2 = flow.sample_dir_cell(c)
			if dir == Vector2.ZERO:
				var diff: Vector2 = Vector2(dx, dy)
				var dist: float = diff.length()
				if dist > 0.0:
					var strength: float = 1.0 / dist
					repel += diff.normalized() * strength
					count += 1

	if count == 0:
		return Vector2.ZERO

	repel /= float(count)
	return repel.normalized()


func compute(agent: Node2D, neighbors: Array, flow_dir: Vector2) -> Vector2:
	const MAX_NEIGHBORS: int = 64
	
	var t0: int = Time.get_ticks_usec()
	var local_neighbors: Array = get_neighbors(agent, neighbors)
	var t1: int = Time.get_ticks_usec()
	
	var sep_force: Vector2 = Vector2.ZERO
	var count: int = 0
	
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
	
	var t2: int = Time.get_ticks_usec()
	
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
	
	var t3: int = Time.get_ticks_usec()
	var wall_avoid: Vector2 = get_wall_avoidance(agent)
	var t4: int = Time.get_ticks_usec()
	
	if wall_avoid != Vector2.ZERO:
		sep_force += wall_avoid * 2.5
	
	
	return result


func get_neighbors(agent: Node2D, all_agents: Array) -> Array:
	grid.update(agent)
	var raw: Array = grid.neighbors_at(agent.global_position, 1)
	
	const MAX_CONSIDERED: int = 16
	var candidates: Array = []
	var agent_pos: Vector2 = agent.global_position
	
	# Collecte avec distance
	for other in raw:
		if other == agent:
			continue
		var dist_sq: float = agent_pos.distance_squared_to(other.global_position)
		if dist_sq <= neighbor_radius * neighbor_radius:
			candidates.append({"node": other, "dist_sq": dist_sq})
	
	# Tri par proximité
	candidates.sort_custom(func(a, b): return a.dist_sq < b.dist_sq)
	
	# Limite stricte
	var result: Array = []
	var limit: int = min(candidates.size(), MAX_CONSIDERED)
	for i in range(limit):
		result.append(candidates[i].node)
	
	return result
