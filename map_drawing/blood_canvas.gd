extends Node

@export var tilemap: TileMapLayer
@export var blood_frames: SpriteFrames
@export var blood_z_index: int = -75

var rect_world: Rect2


func _ready():
	var used = tilemap.get_used_rect()
	var tile_size = tilemap.tile_set.tile_size

	rect_world = Rect2(
		tilemap.to_global(used.position * tile_size),
		used.size * tile_size
	)


func stamp_world(world_pos: Vector2):
	if not rect_world.has_point(world_pos):
		return

	var seed = int(world_pos.x * 928371 + world_pos.y * 364479)
	var rng = RandomNumberGenerator.new()
	rng.seed = seed

	var frame_count = blood_frames.get_frame_count("blood")
	if frame_count == 0:
		return

	var frame_idx = rng.randi_range(0, frame_count - 1)
	var tex: Texture2D = blood_frames.get_frame_texture("blood", frame_idx)
	if tex == null:
		return

	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.position = world_pos
	sprite.rotation = rng.randf() * TAU
	sprite.z_index = blood_z_index
	sprite.centered = true
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.modulate = Color(1, 1, 1, 0.8)

	add_child(sprite)


func clear():
	for c in get_children():
		if c is Sprite2D:
			c.queue_free()
