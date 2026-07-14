extends Control

## Floating "press to shop" hint shown above the seed merchant while the player stands next to
## it during the merchant's day phase. It renders the E-Y.png key glyph for the active input
## device (frame 0 = keyboard E, frame 1 = gamepad Y) with a small drop shadow so it stays
## readable over the gameplay below, and hides once the shop is open, at night, or when the
## player walks away. It only draws the hint; opening the shop is handled by the player
## controller (interact button) and the MerchantDialogController.

const PROMPT_TEXTURE: Texture2D = preload("res://assets/sprites/buttons/E-Y.png")
const FRAME_SIZE: Vector2 = Vector2(32.0, 32.0)
const FRAME_KMOUSE: int = 0
const FRAME_PAD: int = 1
const INPUT_MODE_PAD: String = "pad"
# Rendered glyph size (source frames are 32x32; upscaled for visibility above the world).
const ICON_SIZE: Vector2 = Vector2(40.0, 40.0)
# Offset from the merchant's origin (its feet) to the hint, placing it just above the sprite.
const ABOVE_HEAD_OFFSET: Vector2 = Vector2(0.0, -60.0)
const SHADOW_OFFSET: Vector2 = Vector2(2.0, 3.0)

var _building_manager: Node
var _player_controller: Node
var _merchant_controller: Node
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


func _make_glyph() -> TextureRect:
	var rect: TextureRect = TextureRect.new()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.custom_minimum_size = ICON_SIZE
	rect.size = ICON_SIZE
	return rect


func _process(_delta: float) -> void:
	if not _should_show():
		if visible:
			visible = false
		return
	_apply_frame(_desired_frame())
	_position_over_merchant()
	if not visible:
		visible = true


## True while the prompt should be visible: day, merchant phase, player standing at the merchant,
## and the shop not already open.
func _should_show() -> bool:
	if GameState.is_night or not GameState.is_seed_merchant_phase:
		return false
	var manager: Node = _resolve_building_manager()
	if manager == null or not manager.has_method("is_player_near_seed_merchant"):
		return false
	if not bool(manager.call("is_player_near_seed_merchant")):
		return false
	# Only show the hint once the merchant has parked at its spot. While it is still
	# walking in, the player can press interact but no prompt is drawn.
	if manager.has_method("has_seed_merchant_reached_spot") and not bool(manager.call("has_seed_merchant_reached_spot")):
		return false
	var merchant_controller: Node = _resolve_merchant_controller()
	if merchant_controller != null and merchant_controller.has_method("is_shop_open") and bool(merchant_controller.call("is_shop_open")):
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


func _position_over_merchant() -> void:
	var manager: Node = _resolve_building_manager()
	if manager == null or not manager.has_method("get_seed_merchant_world_position"):
		return
	var world_position: Vector2 = manager.call("get_seed_merchant_world_position") as Vector2
	var screen_position: Vector2 = get_viewport().get_canvas_transform() * (world_position + ABOVE_HEAD_OFFSET)
	global_position = (screen_position - ICON_SIZE * 0.5).round()


func _resolve_building_manager() -> Node:
	if _building_manager == null or not is_instance_valid(_building_manager):
		var scene: Node = get_tree().current_scene
		_building_manager = scene.get_node_or_null("Map/BuildingManager") if scene != null else null
	return _building_manager


func _resolve_player_controller() -> Node:
	if _player_controller == null or not is_instance_valid(_player_controller):
		var scene: Node = get_tree().current_scene
		_player_controller = scene.get_node_or_null("Player/PlayerController") if scene != null else null
	return _player_controller


func _resolve_merchant_controller() -> Node:
	if _merchant_controller == null or not is_instance_valid(_merchant_controller):
		var scene: Node = get_tree().current_scene
		_merchant_controller = scene.get_node_or_null("GameUI/MerchantDialogController") if scene != null else null
	return _merchant_controller


func _region_texture(frame: int) -> AtlasTexture:
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = PROMPT_TEXTURE
	atlas.region = Rect2(Vector2(float(frame) * FRAME_SIZE.x, 0.0), FRAME_SIZE)
	return atlas
