extends AnimatedSprite2D

@export var sheet: Texture2D

const W: int = 64
const H: int = 64

const RANGES: Dictionary = {
	"Walk_N": Vector2i(8*13 + 0,  8*13 + 7),   # 117 → 124
	"Walk_W": Vector2i(9*13 + 0, 9*13 + 7), # 130 → 137
	"Walk_S": Vector2i(10*13 + 0, 10*13 + 7), # 143 → 150
	"Walk_E": Vector2i(11*13 + 0, 11*13 + 7)  # 156 → 163
}



func _ready() -> void:
	if sheet == null:
		visible = false
		return

	var img: Image = sheet.get_image()
	var cols: int = sheet.get_width() / W

	var frames: SpriteFrames = SpriteFrames.new()

	for name_key in RANGES.keys():
		var name: String = name_key
		frames.add_animation(name)

		var range: Vector2i = RANGES[name]
		var start: int = range.x
		var finish: int = range.y

		for i: int in range(start, finish + 1):
			var x: int = (i % cols) * W
			var y: int = int(i / cols) * H

			var rect := Rect2i(x, y, W, H)
			var sub_img: Image = img.get_region(rect)
			sub_img.convert(Image.FORMAT_RGBA8)

			var tex: ImageTexture = ImageTexture.new()
			tex.set_image(sub_img)

			frames.add_frame(name, tex)

	sprite_frames = frames
	animation = "Walk_S"
	play()
