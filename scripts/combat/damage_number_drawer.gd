extends Node2D
class_name DamageNumberDrawer

## Generic floating damage-number renderer. Add it as a child of any world-space
## node and call show_damage() to pop a rising, fading number at a world position.
## Shared by the monster fight system and the reservoir client tantrum.

const LIFETIME: float = 0.65
const RISE_SPEED: float = 26.0
const FONT_SIZE: int = 14
const DRAW_Z_INDEX: int = 4096

var _positions: PackedVector2Array = PackedVector2Array()
var _damages: PackedInt32Array = PackedInt32Array()
var _times_left: PackedFloat32Array = PackedFloat32Array()

func _ready() -> void:
	z_as_relative = false
	z_index = DRAW_Z_INDEX

func show_damage(world_position: Vector2, damage: int) -> void:
	_positions.push_back(world_position + Vector2(0.0, -28.0))
	_damages.push_back(damage)
	_times_left.push_back(LIFETIME)
	queue_redraw()

func _process(delta: float) -> void:
	var had_numbers: bool = not _positions.is_empty()
	for index: int in range(_positions.size() - 1, -1, -1):
		var number_position: Vector2 = _positions[index]
		number_position.y -= RISE_SPEED * delta
		_positions[index] = number_position
		_times_left[index] = _times_left[index] - delta
		if _times_left[index] <= 0.0:
			_remove_number_at(index)
	if had_numbers:
		queue_redraw()

# Order is visually irrelevant, so swap-remove keeps expiry O(1) and avoids
# shifting every later number during large bursts.
func _remove_number_at(index: int) -> void:
	var last_index: int = _positions.size() - 1
	if index != last_index:
		_positions[index] = _positions[last_index]
		_damages[index] = _damages[last_index]
		_times_left[index] = _times_left[last_index]
	_positions.resize(last_index)
	_damages.resize(last_index)
	_times_left.resize(last_index)

func _draw() -> void:
	var font: Font = ThemeDB.fallback_font
	for index: int in range(_positions.size()):
		var text_value: String = str(_damages[index])
		var number_position: Vector2 = _positions[index]
		var text_size: Vector2 = font.get_string_size(text_value, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
		var draw_position: Vector2 = number_position - Vector2(text_size.x * 0.5, 0.0)
		var alpha: float = min(1.0, _times_left[index] / 0.18)
		var outline_color: Color = Color(0.0, 0.0, 0.0, alpha)
		for offset: Vector2 in [Vector2(-1.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, -1.0), Vector2(0.0, 1.0)]:
			draw_string(font, draw_position + offset, text_value, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, outline_color)
		draw_string(font, draw_position, text_value, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(1.0, 1.0, 1.0, alpha))
