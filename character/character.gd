#characters.gd

extends CharacterBody2D
class_name FlowAgent

## Agent optimisé pour le plugin FlowField C++
## Compatible avec l'ancien système via PathManager

@export var path_manager: PathManager
@export var max_speed: float = 100.0
@export var max_force: float = 1200.0  # Non utilisé en mode direct, gardé pour compatibilité
@export var steering_smooth: float = 0.45  # Non utilisé en mode direct
@export var flow_sample_stride: int = 2  # Non utilisé avec le plugin C++
@export var use_bilinear: bool = true  # Active l'interpolation bilinéaire pour plus de fluidité

#var _last_dir: Vector2 = Vector2.ZERO
var _sample_phase: int = 0

func _ready() -> void:
	_sample_phase = int(get_instance_id() % max(1, flow_sample_stride))

func _physics_process(_delta: float) -> void:
	var flow_ref: FlowField = get_meta("flow_ref")
	if flow_ref == null or not flow_ref.is_ready():
		velocity = Vector2.ZERO
		move_and_slide()
		z_index = int(global_position.y)
		return

	var tile_size: Vector2i = flow_ref.get_tile_size()
	var offset: Vector2 = Vector2(-tile_size.x * 0.5, -tile_size.y * 0.5)
	var sample_pos: Vector2 = global_position + offset

	var dir: Vector2 = Vector2.ZERO
	if use_bilinear:
		dir = flow_ref.sample_dir_world_bilinear(sample_pos)
	else:
		dir = flow_ref.sample_dir_world(sample_pos)

	if dir == Vector2.ZERO:
		velocity = Vector2.ZERO
	else:
		velocity = dir.normalized() * max_speed

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
