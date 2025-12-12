extends Node

@export var tilemap: TileMapLayer
@export var target_sprite: Sprite2D
@export var pixels_per_tile: int = 16
@export var brush_radius_px: int = 8
@export var brush_color: Color = Color(0.7, 0.0, 0.0, 0.85)
@export var blood_frames: SpriteFrames

var img: Image
var tex: ImageTexture

var rect_world: Rect2
var texture_size: Vector2i
var inv_world_size: Vector2

func _ready():
	var used = tilemap.get_used_rect()
	var tile_size = tilemap.tile_set.tile_size

	rect_world = Rect2(
		tilemap.to_global(used.position * tile_size),
		used.size * tile_size
	)

	texture_size = Vector2i(
		used.size.x * pixels_per_tile,
		used.size.y * pixels_per_tile
	)

	inv_world_size = Vector2(
		1.0 / rect_world.size.x,
		1.0 / rect_world.size.y
	)

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
	



func flush():
	tex.update(img)

func clear():
	img.fill(Color(0, 0, 0, 0))
	tex.update(img)
	




func stamp_px(p: Vector2i):
	var myseed = int(p.x * 928371 + p.y * 364479)
	var rng = RandomNumberGenerator.new()
	rng.seed = myseed

	var frame_count = blood_frames.get_frame_count("blood")
	var frame_idx = rng.randi_range(0, frame_count - 1)
	var src_tex: Texture2D = blood_frames.get_frame_texture("blood", frame_idx)
	if src_tex == null:
		return

	var src = src_tex.get_image()
	src.convert(Image.FORMAT_RGBA8)

	var angle = rng.randf() * TAU
	var sin_a = sin(-angle)
	var cos_a = cos(-angle)

	var w = src.get_width()
	var h = src.get_height()
	var half = Vector2(w * 0.5, h * 0.5)

	for dy in range(-half.y, half.y):
		for dx in range(-half.x, half.x):
			var sx = int(dx * cos_a - dy * sin_a + half.x)
			var sy = int(dx * sin_a + dy * cos_a + half.y)

			if sx < 0 or sy < 0 or sx >= w or sy >= h:
				continue

			if src.get_pixel(sx, sy).a < 0.1:
				continue

			var tx = p.x + dx
			var ty = p.y + dy

			if tx < 0 or ty < 0 or tx >= texture_size.x or ty >= texture_size.y:
				continue

			img.set_pixel(tx, ty, brush_color)
