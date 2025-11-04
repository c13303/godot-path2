extends Node2D
class_name FlowField


@export var floor_layer: TileMapLayer
@export var wall_layer: TileMapLayer
@export var allow_diagonals: bool = false

var tile_size: Vector2i = Vector2i(32, 32)

var _walkable: Array[Vector2i] = []
var _walkable_set: Dictionary = {}

var _dirs_front: Dictionary = {}
var _dist_front: Dictionary = {}

var _dirs_back: Dictionary = {}
var _dist_back: Dictionary = {}

var _goal_cell: Vector2i = Vector2i.ZERO
var _version: int = 0

var _thread: Thread
var _computing: bool = false
var _pending_goal: Vector2i = Vector2i.ZERO
var _has_pending: bool = false

func _ready() -> void:
	_capture_tile_size()
	_build_walkable_snapshot()
	print("Floor used rect:", floor_layer.get_used_rect())
	print("Number of walkable cells:", _walkable.size())

func _exit_tree() -> void:
	_join_thread_if_any()

func _capture_tile_size() -> void:
	if floor_layer and floor_layer.tile_set:
		var ts: Vector2 = floor_layer.tile_set.tile_size
		tile_size = Vector2i(int(ts.x), int(ts.y))

func _build_walkable_snapshot() -> void:
	_walkable.clear()
	_walkable_set.clear()
	if floor_layer == null:
		return

	var floors: Array[Vector2i] = floor_layer.get_used_cells()
	var walls: Array[Vector2i] = []
	if wall_layer != null:
		walls = wall_layer.get_used_cells()

	var expanded_walls: Array[Vector2i] = walls.duplicate()
	for w: Vector2i in walls:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var n: Vector2i = w + Vector2i(dx, dy)
				if not expanded_walls.has(n):
					expanded_walls.append(n)
	walls = expanded_walls

	for c: Vector2i in floors:
		if not walls.has(c):
			_walkable.append(c)
			_walkable_set[c] = true

func _neighbors(cell: Vector2i, diag_ok: bool) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	const ORTHO: Array[Vector2i] = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]
	for d: Vector2i in ORTHO:
		var n: Vector2i = cell + d
		if _walkable_set.has(n):
			out.append(n)
	if diag_ok:
		const DIAG: Array[Vector2i] = [Vector2i(1,1), Vector2i(-1,1), Vector2i(1,-1), Vector2i(-1,-1)]
		for d: Vector2i in DIAG:
			var n2: Vector2i = cell + d
			if not _walkable_set.has(n2):
				continue
			var side1: Vector2i = cell + Vector2i(d.x, 0)
			var side2: Vector2i = cell + Vector2i(0, d.y)
			if _walkable_set.has(side1) and _walkable_set.has(side2):
				out.append(n2)
	return out


func _cell_center_world(cell: Vector2i) -> Vector2:
	var local_on_layer: Vector2 = floor_layer.map_to_local(cell)
	return floor_layer.to_global(local_on_layer)



func world_to_cell(world_pos: Vector2) -> Vector2i:
	if floor_layer == null:
		push_warning("FlowField: floor_layer non assigné")
		return Vector2i.ZERO
	var local_pos: Vector2 = floor_layer.to_local(world_pos)
	return floor_layer.local_to_map(local_pos)


func cell_to_world(cell: Vector2i) -> Vector2:
	return _cell_center_world(cell)

func is_ready() -> bool:
	return not _computing and _dirs_front.size() > 0

func current_goal_cell() -> Vector2i:
	return _goal_cell

func rebuild_async(goal_world: Vector2) -> void:
	if floor_layer == null:
		return
	#print("Rebuild flow field at goal:", goal_world)

	_capture_tile_size()
	_build_walkable_snapshot()
	var g: Vector2i = world_to_cell(goal_world)
	if not _walkable.has(g):
		g = _find_nearest_walkable(g, _walkable)
	if _computing:
		_pending_goal = g
		_has_pending = true
		return
	_start_thread(g)

func _start_thread(goal_cell: Vector2i) -> void:
	_join_thread_if_any()
	_computing = true
	_goal_cell = goal_cell
	_dirs_back.clear()
	_dist_back.clear()
	_thread = Thread.new()
	var payload: Dictionary = {
		"goal": goal_cell,
		"walkable": _walkable.duplicate(),
		"diag": allow_diagonals,
		"tile_size": tile_size
	}
	_thread.start(Callable(self, "_thread_compute").bind(payload))

#
func _thread_compute(payload: Dictionary) -> void:
	var goal: Vector2i = payload["goal"]
	var walkable: Array[Vector2i] = payload["walkable"]
	var diag: bool = payload["diag"]

	var dist: Dictionary = {}
	var dirs: Dictionary = {}
	var inf: float = 1e12

	for c: Vector2i in walkable:
		dist[c] = inf
	if not _walkable_set.has(goal):
		if walkable.is_empty():
			call_deferred("_thread_done", dirs, dist)
			return
		goal = _find_nearest_walkable(goal, walkable)
	dist[goal] = 0.0

	var heap: Array = []
	_heap_push(heap, [0.0, goal])

	var t0: int = Time.get_ticks_msec()
	var idx: int = 0

	while not heap.is_empty():
		var pair: Array = _heap_pop(heap)
		var current: Vector2i = pair[1]
		var base_cost: float = pair[0]

		for n: Vector2i in _neighbors(current, diag):
			var step: float = 1.0 + (0.3 if _is_near_wall(n) else 0.0)
			if diag and n.x != current.x and n.y != current.y:
				step = 1.41421356237
			var nc: float = base_cost + step
			if nc + 1e-6 < float(dist[n]):
				dist[n] = nc
				_heap_push(heap, [nc, n])

		idx += 1
		if (idx & 255) == 0:
			OS.delay_msec(0)

	for c: Vector2i in walkable:
		var best_n: Vector2i = c
		var best_v: float = float(dist.get(c, inf))
		for n: Vector2i in _neighbors(c, diag):
			var dv: float = float(dist.get(n, inf))
			if dv < best_v:
				best_v = dv
				best_n = n
		if best_n == c or best_v >= inf * 0.5:
			dirs[c] = Vector2.ZERO
		else:
			var a: Vector2 = Vector2(c.x * tile_size.x + 0.5 * tile_size.x, c.y * tile_size.y + 0.5 * tile_size.y)
			var b: Vector2 = Vector2(best_n.x * tile_size.x + 0.5 * tile_size.x, best_n.y * tile_size.y + 0.5 * tile_size.y)
			dirs[c] = (b - a).normalized()

	print("Flow build time:", Time.get_ticks_msec() - t0, "ms for", walkable.size(), "cells")
	call_deferred("_thread_done", dirs, dist)

# --- utilitaires heap internes (typés explicitement) ---
func _heap_push(heap: Array, pair: Array) -> void:
	heap.push_back(pair)
	var i: int = heap.size() - 1
	while i > 0:
		var parent: int = (i - 1) >> 1
		if float(heap[i][0]) < float(heap[parent][0]):
			var tmp: Array = heap[i]
			heap[i] = heap[parent]
			heap[parent] = tmp
			i = parent
		else:
			break

func _heap_pop(heap: Array) -> Array:
	var root: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i: int = 0
		while true:
			var left: int = i * 2 + 1
			var right: int = left + 1
			var smallest: int = i
			if left < heap.size() and float(heap[left][0]) < float(heap[smallest][0]):
				smallest = left
			if right < heap.size() and float(heap[right][0]) < float(heap[smallest][0]):
				smallest = right
			if smallest == i:
				break
			var tmp: Array = heap[i]
			heap[i] = heap[smallest]
			heap[smallest] = tmp
			i = smallest
	return root


func _is_near_wall(c: Vector2i) -> bool:
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var n: Vector2i = c + Vector2i(dx, dy)
			if not _walkable_set.has(n):
				return true
	return false


func _thread_done(dirs: Dictionary, dist: Dictionary) -> void:
	_dirs_back = dirs
	_dist_back = dist
	_swap_buffers()
	_computing = false
	_version += 1
	# print("Flow built. dirs:", _dirs_front.size(), "walkable:", _walkable.size(), "goal:", _goal_cell)
	if _has_pending:
		_has_pending = false
		_start_thread(_pending_goal)


func _swap_buffers() -> void:
	_dirs_front = _dirs_back
	_dist_front = _dist_back
	_dirs_back = {}
	_dist_back = {}

func _find_nearest_walkable(origin: Vector2i, walkable: Array[Vector2i]) -> Vector2i:
	var best: Vector2i = origin
	var best_dist: float = 1e12
	for c in walkable:
		var d: float = (Vector2(c) - Vector2(origin)).length()
		if d < best_dist:
			best_dist = d
			best = c
	return best

func sample_dir_cell(cell: Vector2i) -> Vector2:
	if _dirs_front.has(cell):
		return _dirs_front[cell]
	return Vector2.ZERO

func sample_dir_world(world_pos: Vector2) -> Vector2:
	if _dirs_front.is_empty():
		return Vector2.ZERO
	var c: Vector2i = world_to_cell(world_pos)
	return sample_dir_cell(c)

func sample_dir_world_bilinear(world_pos: Vector2) -> Vector2:
	if _dirs_front.is_empty():
		return Vector2.ZERO
	var local: Vector2 = floor_layer.to_local(world_pos)
	var fx: float = local.x / float(tile_size.x)
	var fy: float = local.y / float(tile_size.y)
	var x0: int = int(floor(fx))
	var y0: int = int(floor(fy))
	var x1: int = x0 + 1
	var y1: int = y0 + 1
	var c00: Vector2 = sample_dir_cell(Vector2i(x0, y0))
	var c10: Vector2 = sample_dir_cell(Vector2i(x1, y0))
	var c01: Vector2 = sample_dir_cell(Vector2i(x0, y1))
	var c11: Vector2 = sample_dir_cell(Vector2i(x1, y1))
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	var a: Vector2 = c00.lerp(c10, tx)
	var b: Vector2 = c01.lerp(c11, tx)
	var v: Vector2 = a.lerp(b, ty)
	if v.length() > 0.0001:
		return v.normalized()
	return Vector2.ZERO

func flow_version() -> int:
	return _version

func _join_thread_if_any() -> void:
	if _computing and _thread != null:
		_thread.wait_to_finish()
	if _thread != null:
		_thread = null
		
###DEBUG

@export var debug_draw: bool = true
@export var debug_scale: float = 0.4
@export var debug_stride: int = 2  # saute une case sur deux pour lisibilité
@export var debug_color_dir: Color = Color(0, 1, 0)
@export var debug_color_cell: Color = Color(1, 1, 1)

func _process(_delta: float) -> void:
	if debug_draw and (Engine.get_frames_drawn() % 8 == 0):
		queue_redraw()



func _draw() -> void:
	if not debug_draw or _dirs_front.is_empty():
		return

	var cell_size: Vector2 = Vector2(tile_size)
	var skip: int = max(1, debug_stride)
	var i: int = 0

	for cell in _dirs_front.keys():
		i += 1
		if (i % skip) != 0:
			continue
		if not _walkable.has(cell):
			continue

		var dir: Vector2 = _dirs_front[cell]
		if dir == Vector2.ZERO:
			continue

		# ancrage exact: map_to_local (layer) -> to_global (layer) -> to_local (flow)
		var layer_local: Vector2 = floor_layer.map_to_local(cell)
		var world_center: Vector2 = floor_layer.to_global(layer_local)
		var p0: Vector2 = to_local(world_center)
		var p1: Vector2 = p0 + dir * cell_size * debug_scale

		draw_line(p0, p1, debug_color_dir, 1.0)
		draw_circle(p0, 2.0, debug_color_cell)
