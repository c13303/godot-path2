extends AnimatedSprite2D

const W: int = 64
const H: int = 64

const DEFAULT_ANIMATION: String = "Idle_S"

const ANIMATION_RANGES: Dictionary = {
	"Idle_N": Vector2i(22 * 13 + 0, 22 * 13 + 0),  # single frame
	"Idle_W": Vector2i(23 * 13 + 0, 23 * 13 + 0),
	"Idle_S": Vector2i(24 * 13 + 0, 24 * 13 + 0),
	"Idle_E": Vector2i(25 * 13 + 0, 25 * 13 + 0),
	"Walk_N": Vector2i(8 * 13 + 0, 8 * 13 + 7),
	"Walk_W": Vector2i(9 * 13 + 0, 9 * 13 + 7),
	"Walk_S": Vector2i(10 * 13 + 0, 10 * 13 + 7),
	"Walk_E": Vector2i(11 * 13 + 0, 11 * 13 + 7),
}

const SKINS: Dictionary = {
	"rabbit": "res://sprites/lapin/full.png",
	"pig": "res://sprites/lapin/piggy.png",
}

@export var skin: StringName = "rabbit":
	set(value):
		_skin = value
		_apply_skin()
	get:
		return _skin
@export var sheet: Texture2D

static var _cached_frames: Dictionary = {}

var _skin: StringName = "rabbit"

func _ready() -> void:
	if sheet == null:
		sheet = _resolve_sheet(_skin)
	if sheet == null:
		visible = false
		return

	sprite_frames = _get_shared_frames(sheet)
	animation = DEFAULT_ANIMATION
	play()

func _resolve_sheet(skin_name: StringName) -> Texture2D:
	if SKINS.has(skin_name):
		var path: String = SKINS[skin_name]
		var tex: Texture2D = load(path)
		return tex
	if SKINS.size() > 0:
		var first_key: StringName = SKINS.keys()[0]
		var path_first: String = SKINS[first_key]
		return load(path_first)
	return null

func _apply_skin() -> void:
	if not is_inside_tree():
		return
	var resolved: Texture2D = _resolve_sheet(_skin)
	if resolved:
		sheet = resolved
		sprite_frames = _get_shared_frames(sheet)

func _get_cache_key(tex: Texture2D) -> String:
	if tex.resource_path.is_empty():
		return "inst:%d" % tex.get_instance_id()
	return tex.resource_path

func _get_shared_frames(tex: Texture2D) -> SpriteFrames:
	var key: String = _get_cache_key(tex)
	if _cached_frames.has(key):
		return _cached_frames[key]

	var frames: SpriteFrames = _build_frames(tex)
	_cached_frames[key] = frames
	return frames

func _build_frames(tex: Texture2D) -> SpriteFrames:
	var img: Image = tex.get_image()
	var cols: int = int(floor(float(tex.get_width()) / float(W)))

	var frames: SpriteFrames = SpriteFrames.new()
	for name_key in ANIMATION_RANGES.keys():
		var anim_name: String = name_key
		frames.add_animation(anim_name)

		var anim_range: Vector2i = ANIMATION_RANGES[anim_name]
		for i: int in range(anim_range.x, anim_range.y + 1):
			var x: int = (i % cols) * W
			var row: int = int(floor(float(i) / float(cols)))
			var y: int = row * H

			var rect := Rect2i(x, y, W, H)
			var sub_img: Image = img.get_region(rect)
			sub_img.convert(Image.FORMAT_RGBA8)

			var tex_frame: ImageTexture = ImageTexture.new()
			tex_frame.set_image(sub_img)

			frames.add_frame(anim_name, tex_frame)

	return frames
