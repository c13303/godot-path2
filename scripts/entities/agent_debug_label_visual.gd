extends RefCounted
class_name AgentDebugLabelVisual

## Owns one debug state label for a FlowAgent. The label node is created the first
## time text is actually shown, so a normal session with labels off pays nothing.
##
## CPathLib reports state, it never draws: the text handed to set_text() is composed
## by AgentDebugLabelController from the crowd diagnostics.

const LABEL_NAME: StringName = &"DebugStateLabel"
const LOCAL_POSITION: Vector2 = Vector2(-40.0, -72.0)
const FIXED_Z_INDEX: int = 4097
const FONT_SIZE: int = 14
const TEXT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const SHADOW_COLOR: Color = Color(0.0, 0.0, 0.0, 0.8)

var _owner: Node2D = null
var _label: Label = null
var _text: String = ""


func setup(owner: Node2D) -> void:
	_owner = owner


func set_text(text: String) -> void:
	if text == _text:
		return
	_text = text
	if text.is_empty():
		if is_instance_valid(_label):
			_label.visible = false
		return
	var label: Label = _ensure_label()
	if label != null:
		label.text = text
		# The label is not in a container, so nothing else resizes it to fit the
		# new text and a stale rect would clip the second line.
		label.reset_size()
		label.visible = true


func clear() -> void:
	set_text("")


func _ensure_label() -> Label:
	if is_instance_valid(_label):
		return _label
	if not is_instance_valid(_owner):
		return null
	var label: Label = Label.new()
	label.name = LABEL_NAME
	label.position = LOCAL_POSITION
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", FONT_SIZE)
	label.add_theme_color_override(&"font_color", TEXT_COLOR)
	label.add_theme_color_override(&"font_shadow_color", SHADOW_COLOR)
	label.add_theme_constant_override(&"shadow_offset_x", 1)
	label.add_theme_constant_override(&"shadow_offset_y", 1)
	# Deliberately independent of FlowAgent's world-Y z-index, like the bubble visual.
	label.z_as_relative = false
	label.z_index = FIXED_Z_INDEX
	label.visible = false
	_owner.add_child(label)
	_label = label
	return _label
