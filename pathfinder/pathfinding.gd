extends Node2D
class_name Pathfinding

@export var floor_layer: TileMapLayer
@export var wall_layer: TileMapLayer
@export var allow_diagonals: bool = false
@export var character_radius: float = 8.0

var astar: AStar2D = AStar2D.new()
const GRID_SIZE: int = 10000
var built: bool = false
var walkable_cells: Array[Vector2i] = []

func build() -> void:
	if built:
		return
	built = true
	astar.clear()
	walkable_cells.clear()
	if floor_layer == null:
		push_error("floor_layer est null")
		return
	var floors: Array[Vector2i] = floor_layer.get_used_cells()
	var walls: Array[Vector2i] = []
	if wall_layer != null:
		walls = wall_layer.get_used_cells()
	var expanded_walls: Array[Vector2i] = walls.duplicate()
	for w in walls:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var n: Vector2i = w + Vector2i(dx, dy)
				if not expanded_walls.has(n):
					expanded_walls.append(n)
	walls = expanded_walls
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0),
		Vector2i(0, 1), Vector2i(0, -1)
	]
	if allow_diagonals:
		dirs.append_array([
			Vector2i(1, 1), Vector2i(-1, 1),
			Vector2i(1, -1), Vector2i(-1, -1)
		])
	for cell in floors:
		if walls.has(cell):
			continue
		var world_pos: Vector2 = Utils.get_tile_pos_from_cell(floor_layer, cell)
		var id: int = _cell_to_id(cell)
		astar.add_point(id, world_pos)
		walkable_cells.append(cell)
	for cell in walkable_cells:
		var id1: int = _cell_to_id(cell)
		for d in dirs:
			var neighbor: Vector2i = cell + d
			if not walkable_cells.has(neighbor):
				continue
			if allow_diagonals and abs(d.x) == 1 and abs(d.y) == 1:
				var side1: Vector2i = cell + Vector2i(d.x, 0)
				var side2: Vector2i = cell + Vector2i(0, d.y)
				if not walkable_cells.has(side1) or not walkable_cells.has(side2):
					continue
			var id2: int = _cell_to_id(neighbor)
			if not astar.are_points_connected(id1, id2):
				astar.connect_points(id1, id2, true)

func find_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	if not built:
		push_warning("Pathfinding non initialisé")
		return PackedVector2Array()
	var from_local: Vector2 = floor_layer.to_local(from)
	var to_local: Vector2 = floor_layer.to_local(to)
	var start_cell: Vector2i = floor_layer.local_to_map(from_local)
	var goal_cell: Vector2i = floor_layer.local_to_map(to_local)
	if not walkable_cells.has(start_cell):
		start_cell = _find_nearest_walkable_cell(start_cell)
	if not walkable_cells.has(goal_cell):
		goal_cell = _find_nearest_walkable_cell(goal_cell)
	var id_start: int = _cell_to_id(start_cell)
	var id_goal: int = _cell_to_id(goal_cell)
	if not astar.has_point(id_start) or not astar.has_point(id_goal):
		return PackedVector2Array()
	return astar.get_point_path(id_start, id_goal)

func _find_nearest_walkable_cell(origin: Vector2i) -> Vector2i:
	var best: Vector2i = origin
	var best_dist: float = INF
	for cell in walkable_cells:
		var dist: float = (origin - cell).length()
		if dist < best_dist:
			best_dist = dist
			best = cell
	return best

func _cell_to_id(cell: Vector2i) -> int:
	return cell.y * GRID_SIZE + cell.x
	
func find_free_spawn_cell(goal_cell: Vector2i, occupied_cells: Array[Vector2i], max_radius: int = 6) -> Vector2i:
	# Si la case est libre et walkable, on la garde
	if walkable_cells.has(goal_cell) and not occupied_cells.has(goal_cell):
		return goal_cell

	var center: Vector2i = goal_cell

	# Recherche en anneaux croissants (8 directions)
	for r in range(1, max_radius + 1):
		var candidates: Array[Vector2i] = []

		# Bord supérieur et inférieur
		for dx in range(-r, r + 1):
			candidates.append(Vector2i(center.x + dx, center.y - r))
			candidates.append(Vector2i(center.x + dx, center.y + r))

		# Bord gauche et droit
		for dy in range(-r + 1, r):
			candidates.append(Vector2i(center.x - r, center.y + dy))
			candidates.append(Vector2i(center.x + r, center.y + dy))

		# Filtre : walkable, non réservée
		candidates = candidates.filter(func(c: Vector2i) -> bool:
			return walkable_cells.has(c) and not occupied_cells.has(c))

		if candidates.is_empty():
			continue

		# Tri par distance puis angle pour stabilité
		candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var da: float = (Vector2(a) - Vector2(center)).length()
			var db: float = (Vector2(b) - Vector2(center)).length()
			if da == db:
				var aa: float = atan2(float(a.y - center.y), float(a.x - center.x))
				var ab: float = atan2(float(b.y - center.y), float(b.x - center.x))
				return aa < ab
			return da < db)

		return candidates[0]

	return goal_cell

func world_to_cell(world_pos: Vector2) -> Vector2i:
	var local_pos: Vector2 = floor_layer.to_local(world_pos)
	return floor_layer.local_to_map(local_pos)
	
