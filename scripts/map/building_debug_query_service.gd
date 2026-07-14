extends RefCounted
class_name BuildingDebugQueryService

# Owns read-only debug/query data used by overlays, labels, and verbose garden logs.
# It intentionally does not mutate gameplay state.

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

var _manager: BuildingManager
var _show_enters_exits: bool = false
# When on, BuildingManager prints "x gardens recomputed with y entry points" every
# time gardens (and their entry points) are recomputed. Pushed from
# CppDebugOptions.verbose; _verbose_pushed flips true once that push has happened.
# Until then _is_verbose() pulls the value straight off the CPP node so the startup
# recompute is logged even if it runs before CppDebugOptions._ready().
var _verbose: bool = false
var _verbose_pushed: bool = false
var _cpp_debug_options: Node = null


func setup(manager: BuildingManager) -> void:
	_manager = manager


func get_plant_zone_tiles() -> Array:
	return _manager.get_garden_topology_service().plant_zone_tiles().keys()


func get_plant_zone_margin_tiles() -> Array:
	return _manager.get_garden_topology_service().plant_zone_margin_tiles().keys()


func get_plant_zone_route_tiles() -> Array:
	var route_tiles: Dictionary = {}
	for raw_garden: Variant in _manager.get_garden_topology_service().gardens().values():
		var garden: Dictionary = raw_garden as Dictionary
		var entry_cells: Array = garden.get("entry_cells", []) as Array
		for raw_entry_cell: Variant in entry_cells:
			var entry_cell: Vector2i = raw_entry_cell as Vector2i
			route_tiles[entry_cell] = true
	return route_tiles.keys()


func get_garden_entry_cells() -> Array:
	return get_plant_zone_route_tiles()


func set_show_enters_exits(value: bool) -> void:
	_show_enters_exits = value
	if _manager != null:
		_manager.queue_plant_zone_overlay_redraw()


func get_show_enters_exits() -> bool:
	return _show_enters_exits


func set_verbose(value: bool) -> void:
	_verbose = value
	_verbose_pushed = true


func is_verbose() -> bool:
	if _verbose_pushed:
		return _verbose
	if _cpp_debug_options == null and _manager != null and _manager.is_inside_tree():
		var scene: Node = _manager.get_tree().get_current_scene()
		if scene:
			_cpp_debug_options = scene.get_node_or_null("CPP")
	if _cpp_debug_options and "verbose" in _cpp_debug_options and "debug_enabled" in _cpp_debug_options:
		return bool(_cpp_debug_options.get("verbose")) and bool(_cpp_debug_options.get("debug_enabled"))
	return _verbose


func get_garden_enter_tiles() -> Array:
	var tiles: Array[Vector2i] = []
	var route_service: SpawnerRouteService = _manager.get_spawner_route_service()
	for descriptor: Dictionary in route_service.prepared_upcoming_monster_routes():
		var entry_cell: Vector2i = descriptor.get("entry_cell", INVALID_CELL) as Vector2i
		if entry_cell != INVALID_CELL:
			tiles.append(entry_cell)
	return tiles


func get_unreachable_garden_cells() -> Array:
	var cells: Dictionary = {}
	for raw_garden: Variant in _manager.get_garden_topology_service().gardens().values():
		var garden: Dictionary = raw_garden as Dictionary
		if bool(garden.get("reachable", false)):
			continue
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
		for raw_cell: Variant in zone_tiles.keys():
			var zone_cell: Vector2i = raw_cell as Vector2i
			cells[zone_cell] = true
		for raw_cell: Variant in plant_cells.keys():
			var plant_cell: Vector2i = raw_cell as Vector2i
			cells[plant_cell] = true
	return cells.keys()


func get_dirty_garden_cells() -> Array:
	var cells: Dictionary = {}
	for raw_garden: Variant in _manager.get_garden_topology_service().gardens().values():
		var garden: Dictionary = raw_garden as Dictionary
		if not bool(garden.get("dirty", false)):
			continue
		var plant_cells: Dictionary = garden.get("plant_cells", {}) as Dictionary
		var zone_tiles: Dictionary = garden.get("zone_tiles", {}) as Dictionary
		for raw_cell: Variant in zone_tiles.keys():
			var zone_cell: Vector2i = raw_cell as Vector2i
			cells[zone_cell] = true
		for raw_cell: Variant in plant_cells.keys():
			var plant_cell: Vector2i = raw_cell as Vector2i
			cells[plant_cell] = true
	return cells.keys()


func get_debug_monster_path(nav_id: int) -> PackedVector2Array:
	if _manager._entry_path_agents.has(nav_id):
		var entry_data: Dictionary = _manager._entry_path_agents[nav_id] as Dictionary
		var entry_cell: Vector2i = entry_data.get("entry_cell", INVALID_CELL) as Vector2i
		return _debug_path_to_cell(entry_cell)
	if _manager._astar_in_agents.has(nav_id):
		var astar_in_data: Dictionary = _manager._astar_in_agents[nav_id] as Dictionary
		return astar_in_data.get("path_world", PackedVector2Array()) as PackedVector2Array
	if _manager._escaping_agents.has(nav_id):
		var escape_data: Dictionary = _manager._escaping_agents[nav_id] as Dictionary
		var escape_target: Vector2i = escape_data.get("target_cell", INVALID_CELL) as Vector2i
		return _debug_path_to_cell(escape_target)
	for node: Node in _manager.get_tree().get_nodes_in_group("monsters"):
		if not (node is Node2D):
			continue
		var agent: Node2D = node as Node2D
		if int(agent.get("nav_id")) != nav_id:
			continue
		if agent.has_meta("garden_entry_cell"):
			var entry_cell: Vector2i = agent.get_meta("garden_entry_cell") as Vector2i
			return _debug_path_to_cell(entry_cell)
		break
	return PackedVector2Array()


func get_floorz() -> TileMapLayer:
	return _manager.floorz


func _debug_path_to_cell(cell: Vector2i) -> PackedVector2Array:
	var path: PackedVector2Array = PackedVector2Array()
	if cell == INVALID_CELL:
		return path
	path.append(_manager.cell_center(cell))
	return path
