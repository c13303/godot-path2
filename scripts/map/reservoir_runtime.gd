extends Node2D
class_name ReservoirRuntime

const FLASH_DURATION: float = 0.08

@export var max_health: int = 100

var health: int = 100
var _destroyed: bool = false
var _flash_item: CanvasItem
var _base_modulate: Color = Color.WHITE
var _damage_flash_tween: Tween = null


func _ready() -> void:
	health = maxi(1, max_health)
	_flash_item = get_node_or_null("Sprite2D") as CanvasItem
	if _flash_item == null:
		_flash_item = self
	if _flash_item != null:
		_base_modulate = _flash_item.modulate


func take_damage(amount: int) -> bool:
	if _destroyed or amount <= 0:
		return false
	health = maxi(0, health - amount)
	play_damage_flash(FLASH_DURATION)
	if health <= 0:
		_destroyed = true
		GameState.set_reservoir_destroyed(true)
		queue_free()
		return true
	return false


func play_damage_flash(duration: float) -> void:
	if _flash_item == null or not is_instance_valid(_flash_item):
		return
	if _damage_flash_tween != null and _damage_flash_tween.is_valid():
		_damage_flash_tween.kill()
	_flash_item.modulate = Color(1.0, 0.12, 0.12, _base_modulate.a)
	_damage_flash_tween = create_tween()
	_damage_flash_tween.tween_property(_flash_item, "modulate", _base_modulate, maxf(0.0, duration)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func get_health_bar_anchor_world_position() -> Vector2:
	return global_position + Vector2(0.0, -34.0)


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
