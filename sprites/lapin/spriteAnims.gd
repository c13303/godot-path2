extends AnimatedSprite2D

@export var sheet: Texture2D = preload("res://sprites/lapin/full.png")

const W: int = 64
const H: int = 64

const DEFAULT_ANIMATION: String = "Idle_S"

const ANIMATION_RANGES: Dictionary = {
	"Idle_N": Vector2i(22*13 + 0, 22*13 + 1),  # line 23
	"Idle_W": Vector2i(23*13 + 0, 23*13 + 1),
	"Idle_S": Vector2i(24*13 + 0, 24*13 + 1),
	"Idle_E": Vector2i(25*13 + 0, 25*13 + 1),
	"Walk_N": Vector2i(9*13 + 0, 9*13 + 7),
	"Walk_W": Vector2i(10*13 + 0, 10*13 + 7),
	"Walk_S": Vector2i(11*13 + 0, 11*13 + 7),
	"Walk_E": Vector2i(12*13 + 0, 12*13 + 7),
}

static var _cached_frames: SpriteFrames
static var _cached_sheet: Texture2D

func _ready() -> void:
	if sheet == null:
		visible = false
		return

	sprite_frames = _get_shared_frames()
	animation = DEFAULT_ANIMATION
	play()

func _get_shared_frames() -> SpriteFrames:
	if _cached_frames and _cached_sheet == sheet:
		return _cached_frames

	var img: Image = sheet.get_image()
	var cols: int = sheet.get_width() / W

	var frames: SpriteFrames = SpriteFrames.new()
	for name_key in ANIMATION_RANGES.keys():
		var name: String = name_key
		frames.add_animation(name)

		var anim_range: Vector2i = ANIMATION_RANGES[name]
		for i: int in range(anim_range.x, anim_range.y + 1):
			var x: int = (i % cols) * W
			var y: int = int(i / cols) * H

			var rect := Rect2i(x, y, W, H)
			var sub_img: Image = img.get_region(rect)
			sub_img.convert(Image.FORMAT_RGBA8)

			var tex: ImageTexture = ImageTexture.new()
			tex.set_image(sub_img)

			frames.add_frame(name, tex)

	_cached_frames = frames
	_cached_sheet = sheet
	return _cached_frames
