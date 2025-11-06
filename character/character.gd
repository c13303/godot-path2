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
func _physics_process(_delta: float) -> void:
	if steering_system == null:
		return

	var flow: FlowField = get_meta("flow_ref")
	if flow == null or not flow.is_ready():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if arrived:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var goal_cell: Vector2i = flow.current_goal_cell()
	var goal_pos: Vector2 = flow.cell_to_world(goal_cell)
	var tile_size: Vector2i = flow.get_tile_size()
	var dist_to_goal: float = global_position.distance_to(goal_pos)
	var arrive_epsilon: float = float(tile_size.x) * 0.25

	# Test position actuelle dans le repère du flow
	var world_pos: Vector2 = global_position
	var local_pos: Vector2 = flow.floor_layer.to_local(world_pos)
	var current_cell: Vector2i = flow.world_to_cell(global_position)

	print("DEBUG: world:", world_pos, " local:", local_pos, " current_cell:", current_cell, " goal_cell:", goal_cell, " dist:", dist_to_goal)

	if dist_to_goal <= arrive_epsilon:
		print("TEST: condition distance atteinte → dist:", dist_to_goal, " epsilon:", arrive_epsilon)
	if current_cell == goal_cell:
		print("TEST: condition current_cell == goal_cell atteinte")

	if current_cell == goal_cell or dist_to_goal <= arrive_epsilon:
		print(">>> ARRIVED EVENT TRIGGERED <<<")
		arrived = true
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var flow_vec: Vector2 = flow.sample_dir_world_bilinear(global_position)
	var flow_dir: Vector2 = steering_system.compute(self, get_tree().get_nodes_in_group("main_chars"), flow_vec)

	var step_distance: float = max_speed * _delta
	var step_dir: Vector2 = (flow_dir.normalized() if flow_dir != Vector2.ZERO else Vector2.ZERO)
	var next_pos: Vector2 = global_position + step_dir * step_distance
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

	velocity = (flow_dir.normalized() if flow_dir != Vector2.ZERO else Vector2.ZERO) * max_speed
	move_and_slide()
	z_index = int(global_position.y)



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
