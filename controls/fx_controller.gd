extends Node
class_name FXController

const EXPLOSION_DEBUG_SCENE := preload("res://sprites/bomb/bomb.tscn")

@export var explosion_radius: float = 100.0
@export var explosion_intensity: float = 200.0
@export var explosion_friction: float = 0.91
@export var explosion_debug_duration: float = 1.0

var steering: Node

func setup(steering_in: Node) -> void:
	steering = steering_in

func trigger_bomb(position: Vector2) -> void:
	if steering and steering.has_method("apply_explosion"):
		steering.call("apply_explosion", position, explosion_radius, explosion_intensity, explosion_friction)
	_spawn_explosion_effect(position)

func _spawn_explosion_effect(position: Vector2) -> void:
	var circle: Node2D = EXPLOSION_DEBUG_SCENE.instantiate()
	get_tree().current_scene.add_child(circle)
	circle.global_position = position
	circle.z_index = 999
	circle.visible = true
	var timer: SceneTreeTimer = get_tree().create_timer(explosion_debug_duration)
	await timer.timeout
	var mscale: float = explosion_radius / 16.0
	circle.scale = Vector2(mscale, mscale)
	if circle.is_inside_tree():
		circle.queue_free()
