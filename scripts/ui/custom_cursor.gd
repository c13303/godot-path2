extends Node

const CURSOR_TEXTURE: Texture2D = preload("res://assets/sprites/legval/cursor.png")
const CURSOR_SIZE: Vector2i = Vector2i(64, 64)
const CURSOR_HOTSPOT: Vector2 = Vector2(32.0, 32.0)


func _ready() -> void:
	var cursor_image: Image = CURSOR_TEXTURE.get_image()
	cursor_image.resize(CURSOR_SIZE.x, CURSOR_SIZE.y, Image.INTERPOLATE_NEAREST)
	var scaled_cursor: ImageTexture = ImageTexture.create_from_image(cursor_image)
	Input.set_custom_mouse_cursor(scaled_cursor, Input.CURSOR_ARROW, CURSOR_HOTSPOT)
