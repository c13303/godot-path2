extends Control

const PROMPT_TEXTURE: Texture2D = preload("res://assets/sprites/buttons/E-Y.png")
const FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
const FRAME_KMOUSE: int = 0
const FRAME_PAD: int = 1
const INPUT_MODE_PAD: String = "pad"
const ICON_SIZE: Vector2 = Vector2(40.0, 40.0)
const ABOVE_HEAD_OFFSET: Vector2 = Vector2(0.0, -60.0)
const SHADOW_OFFSET: Vector2 = Vector2(2.0, 3.0)

@export var target_controller: NodePath

var _player_controller: Node
var _dialog_ui: Node
var _target: Node
var _icon: TextureRect
var _shadow: TextureRect
var _frame_kmouse: AtlasTexture
var _frame_pad: AtlasTexture
var _current_frame: int = -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = ICON_SIZE
	size = ICON_SIZE
	_frame_kmouse = _region_texture(FRAME_KMOUSE)
	_frame_pad = _region_texture(FRAME_PAD)
	_shadow = _make_glyph()
	_shadow.modulate = Color(0.0, 0.0, 0.0, 0.5)
	_shadow.position = SHADOW_OFFSET
	add_child(_shadow)
	_icon = _make_glyph()
	add_child(_icon)
	visible = false
	set_process(true)


func _process(_delta: float) -> void:
	if not _should_show():
		if visible:
			visible = false
		return
	_apply_frame(_desired_frame())
	_position_over_target()
	if not visible:
		visible = true


func _should_show() -> bool:
	var target: Node = _resolve_target()
	if target == null:
		return false
	if not target.has_method("can_interact") or not bool(target.call("can_interact")):
		return false
	if target.has_method("is_interaction_open") and bool(target.call("is_interaction_open")):
		return false
	var dialog_ui: Node = _resolve_dialog_ui()
	if dialog_ui != null and dialog_ui.has_method("is_open") and bool(dialog_ui.call("is_open")):
		return false
	return true


func _desired_frame() -> int:
	var controller: Node = _resolve_player_controller()
	if controller != null and controller.has_method("get_control_mode"):
		if str(controller.call("get_control_mode")) == INPUT_MODE_PAD:
			return FRAME_PAD
	return FRAME_KMOUSE


func _apply_frame(frame: int) -> void:
	if frame == _current_frame:
		return
	_current_frame = frame
	var texture: AtlasTexture = _frame_pad if frame == FRAME_PAD else _frame_kmouse
	_icon.texture = texture
	_shadow.texture = texture


func _position_over_target() -> void:
	var target: Node = _resolve_target()
	if target == null or not target.has_method("get_interaction_world_position"):
		return
	var world_position: Vector2 = target.call("get_interaction_world_position") as Vector2
	var screen_position: Vector2 = get_viewport().get_canvas_transform() * (world_position + ABOVE_HEAD_OFFSET)
	global_position = (screen_position - ICON_SIZE * 0.5).round()


func _make_glyph() -> TextureRect:
	var rect: TextureRect = TextureRect.new()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.custom_minimum_size = ICON_SIZE
	rect.size = ICON_SIZE
	return rect


func _resolve_target() -> Node:
	if _target == null or not is_instance_valid(_target):
		_target = get_node_or_null(target_controller)
	return _target


func _resolve_player_controller() -> Node:
	if _player_controller == null or not is_instance_valid(_player_controller):
		var scene: Node = get_tree().current_scene
		_player_controller = scene.get_node_or_null("Player/PlayerController") if scene != null else null
	return _player_controller


func _resolve_dialog_ui() -> Node:
	if _dialog_ui == null or not is_instance_valid(_dialog_ui):
		var scene: Node = get_tree().current_scene
		_dialog_ui = scene.get_node_or_null("GameUI/Dialog") if scene != null else null
	return _dialog_ui


func _region_texture(frame: int) -> AtlasTexture:
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = PROMPT_TEXTURE
	atlas.region = Rect2(Vector2(float(frame) * FRAME_SIZE.x, 0.0), FRAME_SIZE)
	return atlas
