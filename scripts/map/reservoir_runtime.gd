extends Node2D
class_name ReservoirRuntime

const HEALTH_BAR_SIZE: Vector2 = Vector2(34.0, 5.0)
const HEALTH_BAR_POSITION: Vector2 = Vector2(-17.0, -34.0)
const FLASH_DURATION: float = 0.08

@export var max_health: int = 100

var health: int = 100
var _flash_left: float = 0.0
var _destroyed: bool = false
var _flash_item: CanvasItem


func _ready() -> void:
	health = maxi(1, max_health)
	_flash_item = get_node_or_null("Sprite2D") as CanvasItem
	if _flash_item == null:
		_flash_item = self
	queue_redraw()


func _process(delta: float) -> void:
	if _flash_left <= 0.0:
		return
	_flash_left = maxf(0.0, _flash_left - delta)
	if _flash_item == null or not is_instance_valid(_flash_item):
		return
	if _flash_left > 0.0:
		_flash_item.modulate = Color(3.0, 3.0, 3.0, 1.0)
	else:
		_flash_item.modulate = Color.WHITE


func take_damage(amount: int) -> bool:
	if _destroyed or amount <= 0:
		return false
	health = maxi(0, health - amount)
	_flash_left = FLASH_DURATION
	if _flash_item != null and is_instance_valid(_flash_item):
		_flash_item.modulate = Color(3.0, 3.0, 3.0, 1.0)
	queue_redraw()
	if health <= 0:
		_destroyed = true
		GameState.set_reservoir_destroyed(true)
		_destroy_visuals()
		return true
	return false


## Removes the reservoir's two sprites (the base tank and its child water fill)
## when it is destroyed. Handles both reservoir layouts: shop-built reservoirs keep
## the base as a "Sprite2D" child, while level-authored ones use this runtime node
## itself as the base sprite.
func _destroy_visuals() -> void:
	var base_sprite: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if base_sprite != null:
		# Freeing the base sprite also frees its "WaterFill" child.
		base_sprite.queue_free()
	else:
		var water_fill: Node = get_node_or_null("WaterFill")
		if water_fill != null:
			water_fill.queue_free()
		# This script declares `extends Node2D`, but level-authored reservoirs attach
		# it to a Sprite2D node, so probe the runtime type through a widened ref.
		var self_node: Node = self
		if self_node is Sprite2D:
			(self_node as Sprite2D).texture = null
	queue_redraw()


func is_destroyed() -> bool:
	return _destroyed


func _draw() -> void:
	if health >= max_health or _destroyed:
		return
	draw_rect(Rect2(HEALTH_BAR_POSITION, HEALTH_BAR_SIZE), Color.BLACK)
	var ratio: float = float(health) / float(maxi(1, max_health))
	var fill_size: Vector2 = Vector2((HEALTH_BAR_SIZE.x - 2.0) * ratio, HEALTH_BAR_SIZE.y - 2.0)
	draw_rect(Rect2(HEALTH_BAR_POSITION + Vector2.ONE, fill_size), Color(0.9, 0.05, 0.05, 1.0))
