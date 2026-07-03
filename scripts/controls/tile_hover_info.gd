extends Node
class_name TileHoverInfo

var floorz: TileMapLayer
var steering: Node
var fps_label: Label
var flow_node: Node
var game_ui: Node
var building_manager: Node
var build_system: Node
var mouse_outline: Line2D
var monster_path_line: Line2D
var _line_parent: Node2D
var enabled: bool = true
var show_monster_paths: bool = false

func setup(
	floor_layer: TileMapLayer,
	steering_in: Node,
	label_in: Label,
	flow_in: Node,
	game_ui_in: Node = null,
	building_manager_in: Node = null
) -> void:
	floorz = floor_layer
	steering = steering_in
	fps_label = label_in
	flow_node = flow_in
	game_ui = game_ui_in
	building_manager = building_manager_in
	var scene: Node = get_tree().get_current_scene()
	build_system = scene.get_node_or_null("Map/BuildSystem") if scene != null else null

	mouse_outline = Line2D.new()
	mouse_outline.default_color = Color(1, 1, 1, 1)
	mouse_outline.width = 1.0
	mouse_outline.closed = true
	mouse_outline.visible = false
	if flow_node and flow_node is Node2D:
		var flow_2d: Node2D = flow_node
		_line_parent = flow_2d
		flow_2d.add_child(mouse_outline)
	else:
		add_child(mouse_outline)

	monster_path_line = Line2D.new()
	monster_path_line.default_color = Color(0.25, 0.85, 1.0, 0.95)
	monster_path_line.width = 2.0
	monster_path_line.closed = false
	monster_path_line.z_index = 200
	monster_path_line.z_as_relative = false
	monster_path_line.visible = false
	if _line_parent:
		_line_parent.add_child(monster_path_line)
	else:
		add_child(monster_path_line)

func process() -> void:
	if not enabled:
		if mouse_outline:
			mouse_outline.visible = false
		if monster_path_line:
			monster_path_line.visible = false
		if fps_label and fps_label.has_method("set_hover_cell_text"):
			fps_label.call("set_hover_cell_text", "")
		return
	if not floorz:
		return

	var mouse_world: Vector2 = _hover_world_position()
	var cell: Vector2i = _hover_cell(mouse_world)
	var center: Vector2 = floorz.to_global(floorz.map_to_local(cell))
	if _pad_cursor_active():
		mouse_world = center

	var hovered_monster: Node2D = _hovered_monster(cell, mouse_world)
	if fps_label and fps_label.has_method("set_hover_cell_text"):
		var lines: Array[String] = ["Tile: (%d, %d)" % [cell.x, cell.y]]
		if steering and steering.has_method("get_agents_in_map_cell"):
			var agents: Array = steering.call("get_agents_in_map_cell", cell) as Array
			for a in agents:
				var id: int = int(a.get("id", -1))
				var dir: int = int(a.get("dir_code", -1))
				var moving: bool = bool(a.get("is_moving", false))
				var vel_len: float = float(a.get("velocity_len", 0.0))
				lines.append("Agent %d : dir %d, moving=%s, vel=%.2f" % [id, dir, moving, vel_len])
		fps_label.call("set_hover_cell_text", "\n".join(lines))

	_update_monster_path_line(hovered_monster)

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
	if not game_ui or not game_ui.has_method("get_selected_build_item_id"):
		return false
	var item_id: String = String(game_ui.call("get_selected_build_item_id"))
	if item_id == "":
		return false
	if game_ui.has_method("is_item_disabled_for_placement") and bool(game_ui.call("is_item_disabled_for_placement", item_id)):
		return false
	return ItemCatalog.item_places_tile(item_id)

func _hover_world_position() -> Vector2:
	if floorz is Node2D:
		var floor_node: Node2D = floorz
		return floor_node.get_global_mouse_position()
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam:
		return cam.get_global_mouse_position()
	return Vector2.ZERO

func _hover_cell(mouse_world: Vector2) -> Vector2i:
	if _pad_cursor_active():
		if build_system.has_method("pad_get_cursor_cell"):
			return build_system.call("pad_get_cursor_cell") as Vector2i
	return floorz.local_to_map(floorz.to_local(mouse_world))

func _pad_cursor_active() -> bool:
	return build_system != null and build_system.has_method("pad_is_cursor_active") and bool(build_system.call("pad_is_cursor_active"))

func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled and mouse_outline:
		mouse_outline.visible = false
	if not enabled and monster_path_line:
		monster_path_line.visible = false

func set_show_monster_paths(value: bool) -> void:
	show_monster_paths = value
	if not show_monster_paths and monster_path_line:
		monster_path_line.visible = false

func _hovered_monster(cell: Vector2i, mouse_world: Vector2) -> Node2D:
	var best_monster: Node2D = null
	var best_dist_sq: float = 576.0
	for node in get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var monster: Node2D = node
		var monster_cell: Vector2i = floorz.local_to_map(floorz.to_local(monster.global_position))
		if monster_cell != cell:
			continue
		var dist_sq: float = monster.global_position.distance_squared_to(mouse_world)
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_monster = monster
	return best_monster

func _update_monster_path_line(monster: Node2D) -> void:
	if not monster_path_line:
		return
	if not show_monster_paths or monster == null or building_manager == null:
		monster_path_line.visible = false
		return
	if not building_manager.has_method("get_debug_monster_path"):
		monster_path_line.visible = false
		return
	var nav_id: int = int(monster.get("nav_id"))
	var raw_path: Variant = building_manager.call("get_debug_monster_path", nav_id)
	if not (raw_path is PackedVector2Array):
		monster_path_line.visible = false
		return
	var path: PackedVector2Array = raw_path as PackedVector2Array
	if path.is_empty():
		monster_path_line.visible = false
		return
	var points: PackedVector2Array = PackedVector2Array()
	points.append(_path_line_local(monster.global_position))
	for point in path:
		points.append(_path_line_local(point))
	monster_path_line.points = points
	monster_path_line.visible = points.size() >= 2

func _path_line_local(world_pos: Vector2) -> Vector2:
	if _line_parent:
		return _line_parent.to_local(world_pos)
	return world_pos
