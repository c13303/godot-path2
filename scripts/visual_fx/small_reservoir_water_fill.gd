extends Sprite2D
class_name SmallReservoirWaterFill

## Water overlay for a single small reservoir. Unlike ReservoirWaterFill (which reads the
## global progression reserve), this reads one instance's own reserve from the
## BuildingObjectManager, keyed by the reservoir's cell. `manager` and `cell` are injected
## by BuildingObjectManager when the runtime node is spawned.

var manager: Node
var cell: Vector2i = Vector2i.ZERO

var _base_position: Vector2 = Vector2.ZERO

func _ready() -> void:
	_base_position = position
	centered = true
	region_enabled = true
	_update_fill()
	set_process(true)

func _process(_delta: float) -> void:
	_update_fill()

func _update_fill() -> void:
	if texture == null or manager == null or not is_instance_valid(manager) or not manager.has_method("get_small_reservoir_reserve"):
		visible = false
		return

	var maximum: float = maxf(1.0, float(manager.call("get_small_reservoir_max", cell)))
	var current: float = clampf(float(manager.call("get_small_reservoir_reserve", cell)), 0.0, maximum)
	var fill_ratio: float = clampf(current / maximum, 0.0, 1.0)
	_apply_fill_ratio(fill_ratio)

func _apply_fill_ratio(fill_ratio: float) -> void:
	var texture_size: Vector2 = texture.get_size()
	var texture_width: float = texture_size.x
	var texture_height: float = texture_size.y
	var visible_height: float = roundf(texture_height * fill_ratio)
	if visible_height <= 0.0:
		visible = false
		return

	var hidden_top: float = texture_height - visible_height
	visible = true
	region_rect = Rect2(0.0, hidden_top, texture_width, visible_height)
	position = _base_position + Vector2(0.0, hidden_top * 0.5)
