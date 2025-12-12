extends Node

@export var target_sprite: Sprite2D
@export var world_size: Vector2 = Vector2(4096, 4096)
@export var texture_size: Vector2i = Vector2i(1024, 1024)
@export var brush_radius_px: int = 8
@export var brush_color: Color = Color(0.7, 0.0, 0.0, 0.85)

var img: Image
var tex: ImageTexture
var rect_world: Rect2
var inv_world_size: Vector2

func _ready():
	rect_world = Rect2(-world_size * 0.5, world_size)
	inv_world_size = Vector2(1.0 / world_size.x, 1.0 / world_size.y)

	img = Image.create(texture_size.x, texture_size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	tex = ImageTexture.create_from_image(img)
	target_sprite.texture = tex
	target_sprite.position = rect_world.position + rect_world.size * 0.5
	target_sprite.scale = rect_world.size / Vector2(texture_size)

func stamp_world(world_pos: Vector2):
	var uv = (world_pos - rect_world.position) * inv_world_size
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return

	var px = Vector2i(
		int(uv.x * float(texture_size.x - 1)),
		int(uv.y * float(texture_size.y - 1))
	)

	stamp_px(px)

func stamp_px(p: Vector2i):
	var r = brush_radius_px
	var r2 = r * r

	var min_x = max(p.x - r, 0)
	var max_x = min(p.x + r, texture_size.x - 1)
	var min_y = max(p.y - r, 0)
	var max_y = min(p.y + r, texture_size.y - 1)

	var a = brush_color.a
	var cr = brush_color.r * a
	var cg = brush_color.g * a
	var cb = brush_color.b * a

	for y in range(min_y, max_y + 1):
		var dy = y - p.y
		for x in range(min_x, max_x + 1):
			var dx = x - p.x
			if dx * dx + dy * dy > r2:
				continue

			var dst = img.get_pixel(x, y)
			var out_a = a + dst.a * (1.0 - a)
			var inv_out_a = 1.0 / max(out_a, 0.000001)

			img.set_pixel(
				x,
				y,
				Color(
					(cr + dst.r * dst.a * (1.0 - a)) * inv_out_a,
					(cg + dst.g * dst.a * (1.0 - a)) * inv_out_a,
					(cb + dst.b * dst.a * (1.0 - a)) * inv_out_a,
					out_a
				)
			)

func flush():
	tex.update(img)

func clear():
	img.fill(Color(0, 0, 0, 0))
	tex.update(img)
