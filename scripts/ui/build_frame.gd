extends Control

@export_range(1.0, 64.0, 1.0, "or_greater") var border_width: float = 10.0:
	set(value):
		border_width = maxf(1.0, value)
		queue_redraw()

@export_range(4.0, 128.0, 1.0, "or_greater") var band_length: float = 22.0:
	set(value):
		band_length = maxf(1.0, value)
		queue_redraw()

@export_range(4.0, 128.0, 1.0, "or_greater") var band_spacing: float = 34.0:
	set(value):
		band_spacing = maxf(1.0, value)
		queue_redraw()

@export var yellow_color: Color = Color(1.0, 0.83, 0.0, 1.0):
	set(value):
		yellow_color = value
		queue_redraw()

@export var black_color: Color = Color(0.03, 0.03, 0.03, 1.0):
	set(value):
		black_color = value
		queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_connect_build_system()
	_connect_game_ui()
	_refresh_visibility()


func _draw() -> void:
	var frame_size: Vector2 = size
	var width: float = minf(border_width, minf(frame_size.x, frame_size.y) * 0.5)
	if width <= 0.0:
		return

	draw_rect(Rect2(Vector2.ZERO, Vector2(frame_size.x, width)), yellow_color)
	draw_rect(Rect2(Vector2(0.0, frame_size.y - width), Vector2(frame_size.x, width)), yellow_color)
	draw_rect(Rect2(Vector2.ZERO, Vector2(width, frame_size.y)), yellow_color)
	draw_rect(Rect2(Vector2(frame_size.x - width, 0.0), Vector2(width, frame_size.y)), yellow_color)

	_draw_horizontal_bands(0.0, width, frame_size.x)
	_draw_horizontal_bands(frame_size.y - width, width, frame_size.x)
	_draw_vertical_bands(0.0, width, frame_size.y)
	_draw_vertical_bands(frame_size.x - width, width, frame_size.y)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _connect_build_system() -> void:
	var build_system: Node = _build_system()
	if build_system == null or not build_system.has_signal(&"build_preview_changed"):
		return
	var callback: Callable = Callable(self, "_on_build_state_changed")
	if not build_system.is_connected(&"build_preview_changed", callback):
		build_system.connect(&"build_preview_changed", callback)


func _connect_game_ui() -> void:
	var game_ui: Node = _game_ui()
	if game_ui == null or not game_ui.has_signal(&"unbuild_selection_changed"):
		return
	var callback: Callable = Callable(self, "_on_build_state_changed")
	if not game_ui.is_connected(&"unbuild_selection_changed", callback):
		game_ui.connect(&"unbuild_selection_changed", callback)


# The frame shows while a placement drag is previewing OR the unbuild tool is equipped, so it
# reads both sources rather than trusting a single signal's bool payload.
func _refresh_visibility() -> void:
	visible = _build_preview_active() or _unbuild_selected()


func _build_preview_active() -> bool:
	var build_system: Node = _build_system()
	return build_system != null and build_system.has_method("pad_is_build_preview_active") and bool(build_system.call("pad_is_build_preview_active"))


func _unbuild_selected() -> bool:
	var game_ui: Node = _game_ui()
	return game_ui != null and game_ui.has_method("is_unbuild_tool_selected") and bool(game_ui.call("is_unbuild_tool_selected"))


func _on_build_state_changed(_is_active: bool) -> void:
	_refresh_visibility()


func _build_system() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("Map/BuildSystem")


func _game_ui() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI")


func _draw_horizontal_bands(y: float, width: float, frame_width: float) -> void:
	var x: float = -band_spacing
	while x < frame_width + band_spacing:
		var points: PackedVector2Array = PackedVector2Array([
			Vector2(x, y),
			Vector2(x + band_length, y),
			Vector2(x + band_length + width, y + width),
			Vector2(x + width, y + width),
		])
		draw_colored_polygon(points, black_color)
		x += band_spacing


func _draw_vertical_bands(x: float, width: float, frame_height: float) -> void:
	var y: float = -band_spacing
	while y < frame_height + band_spacing:
		var points: PackedVector2Array = PackedVector2Array([
			Vector2(x, y + width),
			Vector2(x + width, y),
			Vector2(x + width, y + band_length),
			Vector2(x, y + band_length + width),
		])
		draw_colored_polygon(points, black_color)
		y += band_spacing
