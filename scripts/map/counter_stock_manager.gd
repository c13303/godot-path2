extends Node
class_name CounterStockManager

const ROSE_TEXTURE: Texture2D = preload("res://assets/sprites/legval/rose.png")
const ROSE_TEXTURE_FRAME_COUNT: int = 3
const ROSE_TEXTURE_FRAME: int = 0
const HARVEST_ROSE_FLIGHT_SECONDS: float = 0.65
const COUNTER_PILE_ROSE_SCALE: float = 0.56
const COUNTER_BOUQUET_BASE_OFFSET: Vector2 = Vector2(0.0, -8.0)
const COUNTER_BOUQUET_SLOT_OFFSETS: Array[Vector2] = [
	Vector2(0.0, 0.0),
	Vector2(-13.0, -14.0),
	Vector2(14.0, -15.0),
	Vector2(-11.0, 12.0),
	Vector2(12.0, 13.0),
	Vector2(-17.0, 1.0),
	Vector2(18.0, 2.0),
	Vector2(-27.0, -5.0),
	Vector2(28.0, -4.0),
	Vector2(0.0, 25.0),
]
const MAX_STOCK_PER_COUNTER: int = 10
const CLIENT_COUNTER_RADIUS_TILES: int = 2
# Early fetching only succeeds within 1.25 tile widths of the selected target. A
# target farther than two cells from the client's current cell cannot pass that final
# world-distance check, so only this fixed local neighborhood needs to be searched.
const CLIENT_EARLY_FETCH_TARGET_RADIUS_TILES: int = 2
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const ROSE_SHOP_COUNTER_ID: String = "rose_shop_counter"
const ROSE_ITEM_ID: String = "rose"
# Total duration of the nightfall "counters emptying" animation. The per-rose tick is
# derived from this so the whole sequence always finishes in exactly this many seconds.
const NIGHTFALL_DISSOLVE_SECONDS: float = 3.0

var _stock_by_cell: Dictionary = {}  # Vector2i -> int
var _pile_nodes_by_cell: Dictionary = {}  # Vector2i -> Array[Node2D]
var _pile_parent: Node
var _cell_center: Callable
var _is_walkable: Callable
var _has_plant: Callable
var _manager: BuildingManager


func setup(manager: BuildingManager) -> void:
	_manager = manager


func configure(pile_parent: Node, cell_center: Callable, is_walkable: Callable, has_plant: Callable) -> void:
	_pile_parent = pile_parent
	_cell_center = cell_center
	_is_walkable = is_walkable
	_has_plant = has_plant


func clear() -> void:
	clear_all_piles()
	_stock_by_cell.clear()


func clear_counter(counter_cell: Vector2i) -> void:
	_stock_by_cell.erase(counter_cell)
	clear_pile(counter_cell)


func total_stock() -> int:
	var total: int = 0
	for raw_count: Variant in _stock_by_cell.values():
		total += int(raw_count)
	return total


func stock(counter_cell: Vector2i) -> int:
	return int(_stock_by_cell.get(counter_cell, 0))


func remaining_capacity(counter_cell: Vector2i) -> int:
	return maxi(0, MAX_STOCK_PER_COUNTER - stock(counter_cell))


func has_room(counter_cell: Vector2i) -> bool:
	return remaining_capacity(counter_cell) > 0


func rose_shop_counter_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if _manager == null:
		return cells
	var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
	if building_objects != null and building_objects.has_method("get_building_cells_by_item_id"):
		var raw_cells: Array = building_objects.call("get_building_cells_by_item_id", ROSE_SHOP_COUNTER_ID) as Array
		for raw_cell: Variant in raw_cells:
			cells.append(raw_cell as Vector2i)
		return cells
	var item_def: Dictionary = ItemCatalog.get_item_def(ROSE_SHOP_COUNTER_ID)
	var atlas: Vector2i = item_def.get("atlas", Vector2i(-1, -1)) as Vector2i
	for layer: TileMapLayer in [_manager.traversable_buildings, _manager.blocking_buildings]:
		if layer == null:
			continue
		for raw_cell: Variant in layer.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
			if layer.get_cell_atlas_coords(cell) == atlas and not cells.has(cell):
				cells.append(cell)
	return cells


func rose_shop_counter_cells_with_room() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for counter_cell: Vector2i in rose_shop_counter_cells():
		if has_room(counter_cell):
			cells.append(counter_cell)
	return cells


func rose_shop_counter_count() -> int:
	return rose_shop_counter_cells().size()


func has_counter_room_for_harvest() -> bool:
	return not rose_shop_counter_cells_with_room().is_empty()


func counter_room_for_harvest() -> int:
	var total: int = 0
	for counter_cell: Vector2i in rose_shop_counter_cells():
		total += remaining_capacity(counter_cell)
	return total


func add_stock(counter_cell: Vector2i, amount: int) -> Dictionary:
	return set_stock(counter_cell, stock(counter_cell) + amount)


func set_stock(counter_cell: Vector2i, amount: int) -> Dictionary:
	var previous: int = stock(counter_cell)
	var value: int = clampi(amount, 0, MAX_STOCK_PER_COUNTER)
	if value <= 0:
		_stock_by_cell.erase(counter_cell)
	else:
		_stock_by_cell[counter_cell] = value
	rebuild_pile(counter_cell)
	return {
		"previous": previous,
		"value": value,
	}


func add_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	var change: Dictionary = add_stock(counter_cell, amount)
	after_counter_stock_changed(int(change.get("previous", 0)), int(change.get("value", 0)))


func set_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	var change: Dictionary = set_stock(counter_cell, amount)
	var previous: int = int(change.get("previous", 0))
	var value: int = int(change.get("value", 0))
	after_counter_stock_changed(previous, value)


func after_counter_stock_changed(previous: int, value: int) -> void:
	if _manager == null:
		return
	_manager.notify_counter_stock_changed(previous, value)


func serialize_counter_stock() -> Array[Dictionary]:
	return serialize(rose_shop_counter_cells())


func restore_counter_stock(saved_stock: Array) -> void:
	restore(saved_stock, rose_shop_counter_cells())
	if _manager != null:
		_manager.mark_counter_stock_restored_for_navigation()


func serialize(counter_cells: Array[Vector2i]) -> Array[Dictionary]:
	var data: Array[Dictionary] = []
	for raw_cell: Variant in _stock_by_cell.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var count: int = stock(cell)
		if count <= 0 or not counter_cells.has(cell):
			continue
		data.append({
			"x": cell.x,
			"y": cell.y,
			"count": count,
		})
	return data


func restore(saved_stock: Array, counter_cells: Array[Vector2i]) -> void:
	clear()
	for raw_entry: Variant in saved_stock:
		if not (raw_entry is Dictionary):
			continue
		var entry: Dictionary = raw_entry as Dictionary
		var cell: Vector2i = Vector2i(int(entry.get("x", 0)), int(entry.get("y", 0)))
		var count: int = clampi(int(entry.get("count", 0)), 0, MAX_STOCK_PER_COUNTER)
		if count <= 0 or not counter_cells.has(cell):
			continue
		_stock_by_cell[cell] = count
		rebuild_pile(cell)


func stocked_counter_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for raw_cell: Variant in _stock_by_cell.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if stock(cell) > 0:
			cells.append(cell)
	return cells


func collect_access_cells(access_by_cell: Dictionary) -> Array[Vector2i]:
	var access_cells: Array[Vector2i] = []
	for counter_cell: Vector2i in stocked_counter_cells():
		for dy: int in range(-1, 2):
			for dx: int in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var cell: Vector2i = counter_cell + Vector2i(dx, dy)
				if access_by_cell.has(cell):
					continue
				if not _call_bool(_is_walkable, cell):
					continue
				if _call_bool(_has_plant, cell):
					continue
				access_by_cell[cell] = counter_cell
				access_cells.append(cell)
	return access_cells


func select_stocked_counter_target(from_cell: Vector2i) -> Dictionary:
	var best: Dictionary = {}
	var best_dist: int = 2147483647
	# This query runs once per approaching client per frame. Search target cells near
	# the client, then use O(1) stock lookups for counters that could serve each cell.
	# The previous implementation did the inverse: every client scanned every stocked
	# counter and performed up to 13 TileMap walkability checks for each one.
	for dy: int in range(-CLIENT_EARLY_FETCH_TARGET_RADIUS_TILES, CLIENT_EARLY_FETCH_TARGET_RADIUS_TILES + 1):
		for dx: int in range(-CLIENT_EARLY_FETCH_TARGET_RADIUS_TILES, CLIENT_EARLY_FETCH_TARGET_RADIUS_TILES + 1):
			var manhattan: int = abs(dx) + abs(dy)
			if manhattan > CLIENT_EARLY_FETCH_TARGET_RADIUS_TILES or manhattan >= best_dist:
				continue
			var target_cell: Vector2i = from_cell + Vector2i(dx, dy)
			if not _call_bool(_is_walkable, target_cell):
				continue
			var counter_cell: Vector2i = _stocked_counter_serving_target(target_cell)
			if counter_cell == INVALID_CELL:
				continue
			best_dist = manhattan
			best = {
				"counter_cell": counter_cell,
				"target_cell": target_cell,
			}
	return best


func _stocked_counter_serving_target(target_cell: Vector2i) -> Vector2i:
	for dy: int in range(-CLIENT_COUNTER_RADIUS_TILES, CLIENT_COUNTER_RADIUS_TILES + 1):
		for dx: int in range(-CLIENT_COUNTER_RADIUS_TILES, CLIENT_COUNTER_RADIUS_TILES + 1):
			if abs(dx) + abs(dy) > CLIENT_COUNTER_RADIUS_TILES:
				continue
			var counter_cell: Vector2i = target_cell + Vector2i(dx, dy)
			if stock(counter_cell) > 0:
				return counter_cell
	return INVALID_CELL


func nearest_counter_access_cell(counter_cell: Vector2i, from_cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_dist: int = 2147483647
	for y: int in range(counter_cell.y - CLIENT_COUNTER_RADIUS_TILES, counter_cell.y + CLIENT_COUNTER_RADIUS_TILES + 1):
		for x: int in range(counter_cell.x - CLIENT_COUNTER_RADIUS_TILES, counter_cell.x + CLIENT_COUNTER_RADIUS_TILES + 1):
			var cell: Vector2i = Vector2i(x, y)
			var to_counter: Vector2i = cell - counter_cell
			if abs(to_counter.x) + abs(to_counter.y) > CLIENT_COUNTER_RADIUS_TILES:
				continue
			if not _call_bool(_is_walkable, cell):
				continue
			var from_delta: Vector2i = cell - from_cell
			var manhattan: int = abs(from_delta.x) + abs(from_delta.y)
			if manhattan < best_dist:
				best_dist = manhattan
				best_cell = cell
	return best_cell


func consume_counter_rose(eater: Node2D, access_cell: Vector2i) -> void:
	if _manager == null:
		return
	var counter_cell: Vector2i = _manager.counter_cell_for_access_cell(access_cell)
	_manager.start_agent_eating_counter_rose(eater, access_cell)
	Sfx.play_sound(&"crunsh")
	set_counter_stock(counter_cell, stock(counter_cell) - 1)


func animate_harvested_rose(start_world: Vector2, counter_cell: Vector2i) -> void:
	var sprite: Sprite2D = Sprite2D.new()
	sprite.texture = ROSE_TEXTURE
	sprite.hframes = ROSE_TEXTURE_FRAME_COUNT
	sprite.frame = ROSE_TEXTURE_FRAME
	sprite.centered = true
	sprite.scale = Vector2(0.75, 0.75)
	sprite.global_position = start_world
	sprite.z_index = int(start_world.y) + 10
	_resolve_pile_parent().add_child(sprite)
	var end_world: Vector2 = _call_vector2(_cell_center, counter_cell) + _bouquet_offset(maxi(0, stock(counter_cell) - 1))
	var mid_world: Vector2 = (start_world + end_world) * 0.5 + Vector2(0.0, -64.0)
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(
		Callable(self, "_update_harvest_rose_flight").bind(sprite, start_world, mid_world, end_world),
		0.0,
		1.0,
		HARVEST_ROSE_FLIGHT_SECONDS
	)
	tween.parallel().tween_property(sprite, "rotation", TAU, HARVEST_ROSE_FLIGHT_SECONDS)
	tween.tween_callback(Callable(sprite, "queue_free"))


# Symmetric counterpart to animate_harvested_rose: a rose leaves its filled bouquet
# slot and flies to a client that just bought it. `pile_index` is the slot index the
# rose occupied BEFORE it was removed (i.e. stock - 1 at purchase time), so the sprite
# launches from exactly where the popped rose sat. The client is walking away, so the
# flight endpoint tracks its live position every tick; `on_arrival` fires once the rose
# catches up (the caller uses this to show the pinned rose sprite).
func animate_counter_rose_to_client(counter_cell: Vector2i, pile_index: int, target: Node2D, on_arrival: Callable) -> void:
	if target == null or not is_instance_valid(target):
		if not on_arrival.is_null():
			on_arrival.call()
		return
	var start_world: Vector2 = _call_vector2(_cell_center, counter_cell) + _bouquet_offset(maxi(0, pile_index))
	var sprite: Sprite2D = Sprite2D.new()
	sprite.texture = ROSE_TEXTURE
	sprite.hframes = ROSE_TEXTURE_FRAME_COUNT
	sprite.frame = ROSE_TEXTURE_FRAME
	sprite.centered = true
	sprite.scale = Vector2(COUNTER_PILE_ROSE_SCALE, COUNTER_PILE_ROSE_SCALE)
	sprite.global_position = start_world
	sprite.z_index = int(start_world.y) + 20
	_resolve_pile_parent().add_child(sprite)
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(
		Callable(self, "_update_counter_rose_to_client_flight").bind(sprite, start_world, target),
		0.0,
		1.0,
		HARVEST_ROSE_FLIGHT_SECONDS
	)
	tween.parallel().tween_property(sprite, "rotation", TAU, HARVEST_ROSE_FLIGHT_SECONDS)
	tween.tween_callback(Callable(self, "_on_counter_rose_reached_client").bind(sprite, on_arrival))


func can_install_new_counter() -> bool:
	if _manager == null:
		return false
	var scene: Node = _manager.get_tree().current_scene
	var game_ui: Node = scene.get_node_or_null("GameUI") if scene != null else null
	if game_ui == null:
		return false
	if game_ui.has_method("can_afford_build"):
		if bool(game_ui.call("can_afford_build", ROSE_SHOP_COUNTER_ID, 1)):
			return true
	if game_ui.has_method("get_inventory_item_quantity"):
		var owned_counters: int = int(game_ui.call("get_inventory_item_quantity", ROSE_SHOP_COUNTER_ID))
		if owned_counters > 0:
			return true
	if game_ui.has_method("can_afford_merchant_item"):
		return bool(game_ui.call("can_afford_merchant_item", ROSE_SHOP_COUNTER_ID, 1))
	return false


func rebuild_pile(counter_cell: Vector2i) -> void:
	clear_pile(counter_cell)
	var count: int = stock(counter_cell)
	if count <= 0:
		return
	var nodes: Array[Node2D] = []
	var counter_world: Vector2 = _call_vector2(_cell_center, counter_cell)
	for index: int in range(count):
		var sprite: Sprite2D = Sprite2D.new()
		sprite.texture = ROSE_TEXTURE
		sprite.hframes = ROSE_TEXTURE_FRAME_COUNT
		sprite.frame = ROSE_TEXTURE_FRAME
		sprite.centered = true
		sprite.scale = Vector2(COUNTER_PILE_ROSE_SCALE, COUNTER_PILE_ROSE_SCALE)
		sprite.global_position = counter_world + _bouquet_offset(index)
		sprite.z_index = _bouquet_z_index(counter_world, index)
		_resolve_pile_parent().add_child.call_deferred(sprite)
		nodes.append(sprite)
	_pile_nodes_by_cell[counter_cell] = nodes


func clear_pile(counter_cell: Vector2i) -> void:
	var nodes: Array = _pile_nodes_by_cell.get(counter_cell, []) as Array
	for raw_node: Variant in nodes:
		var node: Node = raw_node as Node
		if node != null and is_instance_valid(node):
			node.queue_free()
	_pile_nodes_by_cell.erase(counter_cell)


func clear_all_piles() -> void:
	var cells: Array = _pile_nodes_by_cell.keys()
	for raw_cell: Variant in cells:
		var cell: Vector2i = raw_cell as Vector2i
		clear_pile(cell)
	_pile_nodes_by_cell.clear()


# Every counter is emptied (triggered when the last client of the sale leaves). The
# logical stock drops to zero immediately so monster garden clustering/targeting never
# sees counter roses (the monster-eat mechanic is gone), while the already-built bouquet
# sprites are detached and popped in reverse fill order for a visual "counters emptying"
# effect. All counters pop in sync — one rose per tick, tick = total_seconds / fullest
# bouquet — so the whole sequence always finishes in exactly total_seconds regardless of
# how full each bouquet is (a 4-rose bouquet just runs out early).
func dissolve_all_piles(total_seconds: float = NIGHTFALL_DISSOLVE_SECONDS) -> void:
	var piles: Array = []  # Array[Array[Node2D]] - each bouquet in fill order (last == next removed)
	var max_count: int = 0
	for raw_cell: Variant in _pile_nodes_by_cell.keys():
		var nodes: Array = _pile_nodes_by_cell[raw_cell] as Array
		if nodes.is_empty():
			continue
		piles.append(nodes)
		max_count = maxi(max_count, nodes.size())
	# Hand the sprites over to the animation: detaching them from the manager (without
	# freeing) means set_stock/clear_pile won't touch them mid-dissolve, and zeroing the
	# stock makes the counters logically empty right now.
	_pile_nodes_by_cell.clear()
	_stock_by_cell.clear()
	if max_count <= 0:
		return
	var interval: float = maxf(0.01, total_seconds / float(max_count))
	var tween: Tween = create_tween()
	for _step: int in range(max_count):
		tween.tween_interval(interval)
		tween.tween_callback(Callable(self, "_pop_last_bouquet_slots").bind(piles))


func _pop_last_bouquet_slots(piles: Array) -> void:
	for raw_nodes: Variant in piles:
		var nodes: Array = raw_nodes as Array
		if nodes.is_empty():
			continue
		var node: Node = nodes.pop_back() as Node
		if node != null and is_instance_valid(node):
			_refund_unsold_rose_seed(node as Node2D)
			node.queue_free()


func _refund_unsold_rose_seed(rose_node: Node2D) -> void:
	if rose_node == null:
		return
	var scene: Node = get_tree().current_scene
	var game_ui: Node = scene.get_node_or_null("GameUI") if scene != null else null
	if game_ui != null and game_ui.has_method("refund_build"):
		game_ui.call("refund_build", ROSE_ITEM_ID, rose_node.global_position, 1)
		return
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node != null and progression_node.has_method("update_seeds"):
		progression_node.call("update_seeds", 1)


func _update_harvest_rose_flight(progress: float, sprite: Sprite2D, start_world: Vector2, mid_world: Vector2, end_world: Vector2) -> void:
	if not is_instance_valid(sprite):
		return
	var inverse_progress: float = 1.0 - progress
	var pos: Vector2 = (
		inverse_progress * inverse_progress * start_world
		+ 2.0 * inverse_progress * progress * mid_world
		+ progress * progress * end_world
	)
	sprite.global_position = pos
	sprite.z_index = int(pos.y) + 10


func _update_counter_rose_to_client_flight(progress: float, sprite: Sprite2D, start_world: Vector2, target: Node2D) -> void:
	if not is_instance_valid(sprite):
		return
	# Endpoint re-read every tick so the rose homes onto the walking-away client.
	var end_world: Vector2 = start_world
	if target != null and is_instance_valid(target):
		end_world = target.global_position
	var mid_world: Vector2 = (start_world + end_world) * 0.5 + Vector2(0.0, -48.0)
	var inverse_progress: float = 1.0 - progress
	var pos: Vector2 = (
		inverse_progress * inverse_progress * start_world
		+ 2.0 * inverse_progress * progress * mid_world
		+ progress * progress * end_world
	)
	sprite.global_position = pos
	sprite.z_index = int(pos.y) + 20


func _on_counter_rose_reached_client(sprite: Sprite2D, on_arrival: Callable) -> void:
	if is_instance_valid(sprite):
		sprite.queue_free()
	if not on_arrival.is_null():
		on_arrival.call()


func _resolve_pile_parent() -> Node:
	if _pile_parent != null and is_instance_valid(_pile_parent):
		return _pile_parent
	var scene: Node = get_tree().current_scene
	return scene if scene != null else self


func _bouquet_offset(index: int) -> Vector2:
	var slot_index: int = clampi(index, 0, COUNTER_BOUQUET_SLOT_OFFSETS.size() - 1)
	return COUNTER_BOUQUET_BASE_OFFSET + COUNTER_BOUQUET_SLOT_OFFSETS[slot_index]


func _bouquet_z_index(counter_world: Vector2, index: int) -> int:
	var offset: Vector2 = _bouquet_offset(index)
	return int(counter_world.y + offset.y) + index


func _call_bool(callable: Callable, cell: Vector2i) -> bool:
	if callable.is_null():
		return false
	return bool(callable.call(cell))


func _call_vector2(callable: Callable, cell: Vector2i) -> Vector2:
	if callable.is_null():
		return Vector2.ZERO
	var raw_result: Variant = callable.call(cell)
	if raw_result is Vector2:
		return raw_result
	return Vector2.ZERO
