extends Panel
class_name PauseOverlay

@export var border_width: int = 4
@export var border_color: Color = Color(1, 0, 0, 1)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	z_index = 100
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.border_color = border_color
	style.border_width_top = border_width
	style.border_width_bottom = border_width
	style.border_width_left = border_width
	style.border_width_right = border_width
	style.bg_color = Color(0, 0, 0, 0)
	add_theme_stylebox_override("panel", style)

func set_paused(is_paused: bool) -> void:
	visible = is_paused

