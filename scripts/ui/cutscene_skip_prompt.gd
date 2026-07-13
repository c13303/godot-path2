extends Control
class_name CutsceneSkipPrompt

const TEXT_KEY_KMOUSE: String = "cutscene.hold_left_mouse_skip"
const TEXT_KEY_PAD: String = "cutscene.hold_pad_button_skip"
const CIRCLE_RADIUS: float = 14.0
const CIRCLE_WIDTH: float = 4.0
const CIRCLE_SEGMENTS: int = 32

var _progress: float = 0.0
var _pad_mode: bool = false
var _label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(360.0, 56.0)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.anchor_left = 0.0
	_label.anchor_top = 0.0
	_label.anchor_right = 1.0
	_label.anchor_bottom = 1.0
	_label.offset_left = 42.0
	_label.offset_top = 0.0
	_label.offset_right = 0.0
	_label.offset_bottom = 0.0
	add_child(_label)
	if not Translations.locale_changed.is_connected(_on_locale_changed):
		Translations.locale_changed.connect(_on_locale_changed)
	_refresh_text()


func set_progress(value: float) -> void:
	var next_progress: float = clampf(value, 0.0, 1.0)
	if is_equal_approx(_progress, next_progress):
		return
	_progress = next_progress
	queue_redraw()


func _draw() -> void:
	var center: Vector2 = Vector2(24.0, size.y * 0.5)
	draw_arc(center, CIRCLE_RADIUS, 0.0, TAU, CIRCLE_SEGMENTS, Color(1.0, 1.0, 1.0, 0.35), CIRCLE_WIDTH)
	if _progress > 0.0:
		draw_arc(
			center,
			CIRCLE_RADIUS,
			-PI * 0.5,
			-PI * 0.5 + TAU * _progress,
			CIRCLE_SEGMENTS,
			Color(1.0, 1.0, 1.0, 0.95),
			CIRCLE_WIDTH
		)


func set_pad_mode(pad_mode: bool) -> void:
	if _pad_mode == pad_mode:
		return
	_pad_mode = pad_mode
	_refresh_text()


func _refresh_text() -> void:
	if _label != null:
		_label.text = Translations.t(TEXT_KEY_PAD if _pad_mode else TEXT_KEY_KMOUSE)


func _on_locale_changed(_locale: String) -> void:
	_refresh_text()
