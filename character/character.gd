extends CharacterBody2D
class_name FlowAgent

@export var path_manager: PathManager               # Référence au gestionnaire global (contient le flow field)
@export var max_speed: float = 100.0                # Vitesse maximale (pixels/s)
@export var max_force: float = 1200.0               # Force de steering (accélération)
@export var steering_smooth: float = 0.45           # Filtrage de réactivité (0.3–0.5 recommandé)
@export var flow_sample_stride: int = 2             # Fréquence d'échantillonnage du flow

var acceleration: Vector2 = Vector2.ZERO
var _last_dir: Vector2 = Vector2.ZERO
var _sample_phase: int = 0

func _ready() -> void:
	_sample_phase = int(get_instance_id() % max(1, flow_sample_stride))

func _physics_process(delta: float) -> void:
	if path_manager != null and path_manager.flow_enabled and path_manager.is_ready():
		var flow_dir: Vector2 = path_manager.sample_dir(global_position)
		
		# Si pas de direction valide → stoppe net
		if flow_dir == Vector2.ZERO:
			velocity = Vector2.ZERO
			move_and_slide()
			return

		# Direction et vitesse directement imposées (pas d'accélération)
		velocity = flow_dir.normalized() * max_speed
	else:
		velocity = Vector2.ZERO

	move_and_slide()
	z_index = int(global_position.y)
