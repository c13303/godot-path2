extends Node
class_name FXController

const EXPLOSION_DEBUG_SCENE := preload("res://sprites/bomb/bomb.tscn")

@export var explosion_radius: float = 100.0
@export var explosion_intensity: float = 200.0
@export var explosion_friction: float = 0.91
@export var explosion_debug_duration: float = 1.0

var steering: Node
var floorz: TileMapLayer

func setup(steering_in: Node, floor_layer: TileMapLayer = null) -> void:
	steering = steering_in
	floorz = floor_layer

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
	var mscale: float = explosion_radius / _tile_size()
	circle.scale = Vector2(mscale, mscale)
	var timer: SceneTreeTimer = get_tree().create_timer(explosion_debug_duration)
	await timer.timeout
	if circle.is_inside_tree():
		circle.queue_free()

func _tile_size() -> float:
	if floorz and floorz.tile_set:
		return float(floorz.tile_set.get_tile_size().x)
	return 32.0
