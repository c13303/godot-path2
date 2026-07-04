extends Sprite2D
class_name ReservoirWaterFill

const WATER_RESERVE_KEY: StringName = &"water_reserve"
const WATER_RESERVE_MAX_KEY: StringName = &"water_reserve_max"

var _progression: Node
var _last_current: int = -1
var _last_maximum: int = -1
var _base_position: Vector2 = Vector2.ZERO

func _ready() -> void:
	_base_position = position
	centered = true
	region_enabled = true
	_resolve_progression()
	_update_fill(true)
	set_process(true)

func _process(_delta: float) -> void:
	if _progression == null or not is_instance_valid(_progression):
		_resolve_progression()
	_update_fill(false)

func _resolve_progression() -> void:
	var scene: Node = get_tree().current_scene
	_progression = scene.get_node_or_null("progression") if scene != null else null

func _update_fill(force: bool) -> void:
	if texture == null or _progression == null or not _progression.has_method("get_value"):
		visible = false
		return

	var maximum: int = maxi(1, int(_progression.call("get_value", WATER_RESERVE_MAX_KEY)))
	var current: int = clampi(int(_progression.call("get_value", WATER_RESERVE_KEY)), 0, maximum)
	if not force and current == _last_current and maximum == _last_maximum:
		return

	_last_current = current
	_last_maximum = maximum
	var fill_ratio: float = clampf(float(current) / float(maximum), 0.0, 1.0)
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
