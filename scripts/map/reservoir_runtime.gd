extends Node2D
class_name ReservoirRuntime

const HEALTH_BAR_SIZE: Vector2 = Vector2(34.0, 5.0)
const HEALTH_BAR_POSITION: Vector2 = Vector2(-17.0, -34.0)
const FLASH_DURATION: float = 0.08

@export var max_health: int = 100

var health: int = 100
var _flash_left: float = 0.0
var _destroyed: bool = false
var _sprite: Sprite2D


func _ready() -> void:
	health = maxi(1, max_health)
	_sprite = get_node_or_null("Sprite2D") as Sprite2D
	queue_redraw()


func _process(delta: float) -> void:
	if _flash_left <= 0.0:
		return
	_flash_left = maxf(0.0, _flash_left - delta)
	if _sprite == null or not is_instance_valid(_sprite):
		return
	if _flash_left > 0.0:
		_sprite.modulate = Color(3.0, 3.0, 3.0, 1.0)
	else:
		_sprite.modulate = Color.WHITE


func take_damage(amount: int) -> bool:
	if _destroyed or amount <= 0:
		return false
	health = maxi(0, health - amount)
	_flash_left = FLASH_DURATION
	if _sprite != null and is_instance_valid(_sprite):
		_sprite.modulate = Color(3.0, 3.0, 3.0, 1.0)
	queue_redraw()
	if health <= 0:
		_destroyed = true
		GameState.set_reservoir_destroyed(true)
		return true
	return false


func is_destroyed() -> bool:
	return _destroyed


func _draw() -> void:
	if health >= max_health or _destroyed:
		return
	draw_rect(Rect2(HEALTH_BAR_POSITION, HEALTH_BAR_SIZE), Color.BLACK)
	var ratio: float = float(health) / float(maxi(1, max_health))
	var fill_size: Vector2 = Vector2((HEALTH_BAR_SIZE.x - 2.0) * ratio, HEALTH_BAR_SIZE.y - 2.0)
	draw_rect(Rect2(HEALTH_BAR_POSITION + Vector2.ONE, fill_size), Color(0.9, 0.05, 0.05, 1.0))
