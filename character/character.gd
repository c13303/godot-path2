#characters.gd

extends CharacterBody2D
class_name FlowAgent

## Agent optimisé pour le plugin FlowField C++
## Compatible avec l'ancien système via PathManager
@export var steering_system: SteeringSystem

@export var path_manager: PathManager
@export var max_speed: float = 100.0
@export var max_force: float = 1200.0  # Non utilisé en mode direct, gardé pour compatibilité
@export var steering_smooth: float = 0.45  # Non utilisé en mode direct
@export var flow_sample_stride: int = 2  # Non utilisé avec le plugin C++
@export var use_bilinear: bool = true  # Active l'interpolation bilinéaire pour plus de fluidité

var arrived: bool = false
var arrived_reported: bool = false
var prev_dist_to_goal: float = INF

#var _last_dir: Vector2 = Vector2.ZERO
var _sample_phase: int = 0

func _ready() -> void:
	_sample_phase = int(get_instance_id() % max(1, flow_sample_stride))
	if not has_meta("last_flow_version"):
		set_meta("last_flow_version", -1)
	if not has_meta("cooldown_until_ms"):
		set_meta("cooldown_until_ms", 0)

func _check_goal_state(flow: FlowField, current_cell: Vector2i, goal_cell: Vector2i, goal_pos: Vector2, tile_size: Vector2i) -> bool:
	var dist_to_goal: float = global_position.distance_to(goal_pos)
	var arrive_epsilon: float = float(tile_size.x) * 0.15
	return current_cell == goal_cell or dist_to_goal <= arrive_epsilon


func _is_blocked_near_wall(flow: FlowField, current_cell: Vector2i, goal_pos: Vector2) -> bool:
	var reachable: bool = false
	for d: Vector2i in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
		var c: Vector2i = current_cell + d
		var dir_c: Vector2 = flow.sample_dir_cell(c)
		if dir_c != Vector2.ZERO:
			var c_world: Vector2 = flow.cell_to_world(c)
			if c_world.distance_to(goal_pos) < global_position.distance_to(goal_pos):
				reachable = true
				break
	return not reachable



func _physics_process(_delta: float) -> void:
	if steering_system == null:
		return

	var flow: FlowField = get_meta("flow_ref") as FlowField
	if flow == null or not flow.is_ready():
		return

	var cur_version: int = flow.flow_version()
	var last_version: int = (get_meta("last_flow_version") as int) if has_meta("last_flow_version") else -1
	if cur_version != last_version:
		set_meta("last_flow_version", cur_version)
		arrived = false
		set_meta("cooldown_until_ms", Time.get_ticks_msec() + 200)

	# Agents arrivés : maintien minimal pour la grille et la reprise
	if arrived and cur_version == last_version:
		if steering_system.grid != null:
			steering_system.grid.update(self)
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var now_ms: int = Time.get_ticks_msec()
	var in_cooldown: bool = now_ms < ((get_meta("cooldown_until_ms") as int) if has_meta("cooldown_until_ms") else 0)

	var goal_cell: Vector2i = flow.current_goal_cell()
	var current_cell: Vector2i = flow.world_to_cell(global_position)
	var goal_pos: Vector2 = flow.cell_to_world(goal_cell)
	var tile_size: Vector2i = flow.get_tile_size()

	# Vérifie si arrivé
	var dist_to_goal: float = global_position.distance_to(goal_pos)
	var arrive_epsilon: float = float(tile_size.x) * 0.15
	if current_cell == goal_cell or dist_to_goal <= arrive_epsilon:
		arrived = true
		velocity = Vector2.ZERO
		if steering_system.grid != null:
			steering_system.grid.update(self)
		move_and_slide()
		return

	var flow_vec: Vector2 = flow.sample_dir_world_bilinear(global_position)
	if flow_vec == Vector2.ZERO:
		_handle_flow_zero(flow, tile_size)
		return

	var flow_dir: Vector2 = steering_system.compute(self, get_tree().get_nodes_in_group("main_chars"), flow_vec)
	var step_distance: float = max_speed * _delta
	var next_pos: Vector2 = global_position + flow_dir.normalized() * step_distance
	var next_cell: Vector2i = flow.world_to_cell(next_pos)
	var dir_next: Vector2 = flow.sample_dir_cell(next_cell)

	if dir_next == Vector2.ZERO and next_cell != goal_cell:
		var perp: Vector2 = Vector2(-flow_dir.y, flow_dir.x)
		var test1: Vector2i = flow.world_to_cell(global_position + perp * step_distance)
		var test2: Vector2i = flow.world_to_cell(global_position - perp * step_distance)
		var dir1: Vector2 = flow.sample_dir_cell(test1)
		var dir2: Vector2 = flow.sample_dir_cell(test2)
		if dir1 != Vector2.ZERO:
			flow_dir = perp
		elif dir2 != Vector2.ZERO:
			flow_dir = -perp
		else:
			velocity = Vector2.ZERO
			move_and_slide()
			return

	if not in_cooldown and _check_propagation(flow, goal_pos, tile_size):
		arrived = true
		velocity = Vector2.ZERO
		if steering_system.grid != null:
			steering_system.grid.update(self)
		move_and_slide()
		return

	velocity = (flow_dir.normalized() if flow_dir != Vector2.ZERO else Vector2.ZERO) * max_speed
	move_and_slide()
	z_index = int(global_position.y)

	if steering_system.grid != null:
		steering_system.grid.update(self)


func _handle_flow_zero(flow: FlowField, tile_size: Vector2i) -> void:
	if arrived:
		velocity = Vector2.ZERO
		return

	var cur_cell: Vector2i = flow.world_to_cell(global_position)
	var fixed: bool = false

	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n_cell: Vector2i = cur_cell + d
		var dir_n: Vector2 = flow.sample_dir_cell(n_cell)
		if dir_n != Vector2.ZERO:
			global_position = flow.cell_to_world(n_cell)
			fixed = true
			break

	if not fixed:
		var random_offset: Vector2 = Vector2(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5)) * float(tile_size.x)
		global_position += random_offset

	velocity = Vector2.ZERO


func _check_propagation(flow: FlowField, goal_pos: Vector2, tile_size: Vector2i) -> bool:
	var neighbors: Array = steering_system.grid.neighbors_at(global_position, 2)
	var stop_distance: float = float(tile_size.x) * 0.9

	for n in neighbors:
		if n == self:
			continue
		if n is FlowAgent:
			var neighbor: FlowAgent = n
			if neighbor.arrived and global_position.distance_to(neighbor.global_position) <= stop_distance:
				return true
	return false

## Version avec smooth steering (optionnelle pour plus de contrôle)
func _physics_process_smooth(delta: float) -> void:
	if path_manager == null or not path_manager.flow_enabled:
		velocity = Vector2.ZERO
		move_and_slide()
		return
	
	if not path_manager.is_ready():
		velocity = Vector2.ZERO
		move_and_slide()
		return
	
	var flow_dir: Vector2 = path_manager.sample_dir(global_position)
	
	if flow_dir == Vector2.ZERO:
		# Décélération progressive
		velocity = velocity.lerp(Vector2.ZERO, steering_smooth)
		move_and_slide()
		return
	
	# Calcul du steering
	var desired_velocity: Vector2 = flow_dir.normalized() * max_speed
	var steering: Vector2 = desired_velocity - velocity
	
	# Limite la force de steering
	if steering.length() > max_force:
		steering = steering.normalized() * max_force
	
	# Application avec smooth
	velocity += steering * delta
	
	# Limite la vitesse maximale
	if velocity.length() > max_speed:
		velocity = velocity.normalized() * max_speed
	
	move_and_slide()
	z_index = int(global_position.y)
