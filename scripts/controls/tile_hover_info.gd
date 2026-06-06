extends Node
class_name TileHoverInfo

var floorz: TileMapLayer
var steering: Node
var fps_label: Label
var flow_node: Node
var game_ui: Node
var mouse_outline: Line2D
var enabled: bool = true

func setup(floor_layer: TileMapLayer, steering_in: Node, label_in: Label, flow_in: Node, game_ui_in: Node = null) -> void:
	floorz = floor_layer
	steering = steering_in
	fps_label = label_in
	flow_node = flow_in
	game_ui = game_ui_in

	mouse_outline = Line2D.new()
	mouse_outline.default_color = Color(1, 1, 1, 1)
	mouse_outline.width = 1.0
	mouse_outline.closed = true
	mouse_outline.visible = false
	if flow_node and flow_node is Node2D:
		var flow_2d: Node2D = flow_node
		flow_2d.add_child(mouse_outline)
	else:
		add_child(mouse_outline)

func process() -> void:
	if not enabled:
		if mouse_outline:
			mouse_outline.visible = false
		if fps_label and fps_label.has_method("set_hover_cell_text"):
			fps_label.call("set_hover_cell_text", "")
		return
	if not floorz:
		return

	var mouse_world: Vector2
	if floorz is Node2D:
		var floor_node: Node2D = floorz
		mouse_world = floor_node.get_global_mouse_position()
	else:
		var cam: Camera2D = get_viewport().get_camera_2d()
		if cam:
			mouse_world = cam.get_global_mouse_position()
		else:
			mouse_world = Vector2.ZERO
	var cell: Vector2i = floorz.local_to_map(floorz.to_local(mouse_world))
	var center: Vector2 = floorz.to_global(floorz.map_to_local(cell))

	if fps_label and fps_label.has_method("set_hover_cell_text"):
		var lines: Array[String] = ["Tile: (%d, %d)" % [cell.x, cell.y]]
		if steering and steering.has_method("get_agents_in_map_cell"):
			var agents: Array = steering.call("get_agents_in_map_cell", cell)
			for a in agents:
				var id: int = int(a.get("id", -1))
				var dir: int = int(a.get("dir_code", -1))
				var moving: bool = bool(a.get("is_moving", false))
				var vel_len: float = float(a.get("velocity_len", 0.0))
				lines.append("Agent %d : dir %d, moving=%s, vel=%.2f" % [id, dir, moving, vel_len])
		fps_label.call("set_hover_cell_text", "\n".join(lines))

	if mouse_outline:
		if _selected_item_places_tile():
			var tile_size: Vector2i = floorz.tile_set.get_tile_size()
			var half: Vector2 = Vector2(float(tile_size.x) * 0.5, float(tile_size.y) * 0.5)
			mouse_outline.points = [
				Vector2(-half.x, -half.y),
				Vector2(half.x, -half.y),
				Vector2(half.x, half.y),
				Vector2(-half.x, half.y)
			]
			mouse_outline.global_position = center
			mouse_outline.visible = true
		else:
			mouse_outline.visible = false

func _selected_item_places_tile() -> bool:
	if not game_ui or not game_ui.has_method("get_selected_quick_item_id"):
		return false
	var item_id := String(game_ui.call("get_selected_quick_item_id"))
	if item_id == "":
		return false
	return ItemCatalog.item_places_tile(item_id)

func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled and mouse_outline:
		mouse_outline.visible = false
