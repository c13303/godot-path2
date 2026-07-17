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


# The build and unbuild selections change independently, so both are listened to. Neither
# payload is trusted: the handler re-asks game_ui for the composed answer instead.
func _connect_game_ui() -> void:
	var game_ui: Node = _game_ui()
	if game_ui == null:
		return
	var callback: Callable = Callable(self, "_on_build_state_changed")
	var signal_names: Array[StringName] = [&"unbuild_selection_changed", &"build_selection_changed"]
	for signal_name: StringName in signal_names:
		if not game_ui.has_signal(signal_name):
			continue
		if not game_ui.is_connected(signal_name, callback):
			game_ui.connect(signal_name, callback)


# The frame marks "a build or unbuild tool is in hand", which is exactly when a tool cursor has
# replaced the mouse cursor on the map. game_ui owns that rule; no usability check is needed here
# because a tool that stops being usable is unequipped rather than left in hand.
func _refresh_visibility() -> void:
	visible = _tool_in_hand()


func _tool_in_hand() -> bool:
	var game_ui: Node = _game_ui()
	return (
		game_ui != null
		and game_ui.has_method("is_build_or_unbuild_tool_in_hand")
		and bool(game_ui.call("is_build_or_unbuild_tool_in_hand"))
	)


func _on_build_state_changed(_is_active: bool) -> void:
	_refresh_visibility()


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
