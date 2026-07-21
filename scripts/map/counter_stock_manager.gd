extends Node
class_name CounterStockManager

const ROSE_TEXTURE: Texture2D = preload("res://assets/sprites/legval/rose.png")
const GROUND_ITEM_VISUAL_SCRIPT: Script = preload("res://scripts/map/ground_item_visual.gd")
const ROSE_TEXTURE_FRAME_COUNT: int = 3
const ROSE_TEXTURE_FRAME: int = 0
const HARVEST_ROSE_FLIGHT_SECONDS: float = 0.65
const HARVEST_ROSE_ARC_HEIGHT: float = 32.0
const CLIENT_ROSE_ARC_HEIGHT: float = 24.0
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
var _pile_nodes_by_cell: Dictionary = {}  # Vector2i -> Array[Sprite2D]
var _pile_parent: Node
var _cell_center: Callable
var _is_walkable: Callable
var _has_plant: Callable
var _manager: BuildingManager
var _bouquet_sprites_created: int = 0
var _bouquet_sprites_freed: int = 0
var _last_stock_logic_us: int = 0
var _last_pile_sync_us: int = 0
var _last_notify_us: int = 0


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
	unregister_counter(counter_cell)


func register_existing_counters() -> void:
	for counter_cell: Vector2i in rose_shop_counter_cells():
		register_counter(counter_cell)


func register_counter(counter_cell: Vector2i) -> void:
	if _pile_nodes_by_cell.has(counter_cell):
		_sync_pile_visibility(counter_cell, stock(counter_cell))
		return
	var counter_world: Vector2 = _call_vector2(_cell_center, counter_cell)
	var nodes: Array[Sprite2D] = []
	for index: int in range(MAX_STOCK_PER_COUNTER):
		var sprite: Sprite2D = Sprite2D.new()
		_bouquet_sprites_created += 1
		sprite.texture = ROSE_TEXTURE
		sprite.hframes = ROSE_TEXTURE_FRAME_COUNT
		sprite.frame = ROSE_TEXTURE_FRAME
		sprite.centered = true
		sprite.scale = Vector2(COUNTER_PILE_ROSE_SCALE, COUNTER_PILE_ROSE_SCALE)
		sprite.global_position = counter_world + _bouquet_offset(index)
		sprite.z_index = _bouquet_z_index(counter_world, index)
		sprite.visible = false
		_attach_pile_sprite(sprite)
		nodes.append(sprite)
	_pile_nodes_by_cell[counter_cell] = nodes
	_sync_pile_visibility(counter_cell, stock(counter_cell))


func unregister_counter(counter_cell: Vector2i) -> void:
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
	var telemetry_enabled: bool = _manager != null and _manager.rose_harvest_telemetry_enabled()
	var logic_started_us: int = Time.get_ticks_usec() if telemetry_enabled else 0
	var previous: int = stock(counter_cell)
	var value: int = clampi(amount, 0, MAX_STOCK_PER_COUNTER)
	if value <= 0:
		_stock_by_cell.erase(counter_cell)
	else:
		_stock_by_cell[counter_cell] = value
	if telemetry_enabled:
		_last_stock_logic_us = Time.get_ticks_usec() - logic_started_us
	var pile_started_us: int = Time.get_ticks_usec() if telemetry_enabled else 0
	_sync_pile_visibility(counter_cell, value)
	if telemetry_enabled:
		_last_pile_sync_us = Time.get_ticks_usec() - pile_started_us
	return {
		"previous": previous,
		"value": value,
	}


func add_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	_last_stock_logic_us = 0
	_last_pile_sync_us = 0
	_last_notify_us = 0
	var change: Dictionary = add_stock(counter_cell, amount)
	var notify_started_us: int = Time.get_ticks_usec() if _manager != null and _manager.rose_harvest_telemetry_enabled() else 0
	after_counter_stock_changed(int(change.get("previous", 0)), int(change.get("value", 0)))
	if notify_started_us > 0:
		_last_notify_us = Time.get_ticks_usec() - notify_started_us


func set_counter_stock(counter_cell: Vector2i, amount: int) -> void:
	_last_stock_logic_us = 0
	_last_pile_sync_us = 0
	_last_notify_us = 0
	var change: Dictionary = set_stock(counter_cell, amount)
	var previous: int = int(change.get("previous", 0))
	var value: int = int(change.get("value", 0))
	var notify_started_us: int = Time.get_ticks_usec() if _manager != null and _manager.rose_harvest_telemetry_enabled() else 0
	after_counter_stock_changed(previous, value)
	if notify_started_us > 0:
		_last_notify_us = Time.get_ticks_usec() - notify_started_us


func after_counter_stock_changed(previous: int, value: int) -> void:
	if _manager == null:
		return
	_manager.notify_counter_stock_changed(previous, value)


func serialize_counter_stock() -> Array[Dictionary]:
	return serialize(rose_shop_counter_cells())


func restore_counter_stock(saved_stock: Array) -> void:
	restore(saved_stock, rose_shop_counter_cells())


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
	_stock_by_cell.clear()
	var registered_cells: Array = _pile_nodes_by_cell.keys()
	for raw_cell: Variant in registered_cells:
		var registered_cell: Vector2i = raw_cell as Vector2i
		if not counter_cells.has(registered_cell):
			clear_pile(registered_cell)
	for counter_cell: Vector2i in counter_cells:
		register_counter(counter_cell)
		_sync_pile_visibility(counter_cell, 0)
	for raw_entry: Variant in saved_stock:
		if not (raw_entry is Dictionary):
			continue
		var entry: Dictionary = raw_entry as Dictionary
		var cell: Vector2i = Vector2i(int(entry.get("x", 0)), int(entry.get("y", 0)))
		var count: int = clampi(int(entry.get("count", 0)), 0, MAX_STOCK_PER_COUNTER)
		if count <= 0 or not counter_cells.has(cell):
			continue
		_stock_by_cell[cell] = count
		_sync_pile_visibility(cell, count)


func stocked_counter_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for raw_cell: Variant in _stock_by_cell.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if stock(cell) > 0:
			cells.append(cell)
	return cells


func collect_access_cells(access_by_cell: Dictionary) -> Array[Vector2i]:
	var access_cells: Array[Vector2i] = []
	for counter_cell: Vector2i in rose_shop_counter_cells():
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


func animate_harvested_rose(start_world: Vector2, counter_cell: Vector2i) -> void:
	var visual: GroundItemVisual = GROUND_ITEM_VISUAL_SCRIPT.new()
	if not visual.setup_catalog_item(ROSE_ITEM_ID):
		visual.free()
		return
	_resolve_pile_parent().add_child(visual)
	visual.set_flight_pose(start_world, 0.0, 10)
	var end_world: Vector2 = _call_vector2(_cell_center, counter_cell) + _bouquet_offset(maxi(0, stock(counter_cell) - 1))
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(
		Callable(self, "_update_harvest_rose_flight").bind(visual, start_world, end_world),
		0.0,
		1.0,
		HARVEST_ROSE_FLIGHT_SECONDS
	)
	tween.parallel().tween_property(visual.sprite, "rotation", TAU, HARVEST_ROSE_FLIGHT_SECONDS)
	tween.tween_callback(Callable(visual, "queue_free"))


# Symmetric counterpart to animate_harvested_rose: a rose leaves its filled bouquet
# slot and flies to a client that just bought it. `pile_index` is the slot index the
# rose occupied BEFORE it was removed (i.e. stock - 1 at purchase time), so the sprite
# launches from exactly where the popped rose sat. The client is walking away, so the
# flight endpoint tracks its live position every tick; `on_arrival` fires once the rose
# catches up (the caller uses this to show the pinned rose sprite).
func animate_counter_rose_to_client(counter_cell: Vector2i, pile_index: int, target: Node2D, on_arrival: Callable) -> void:
	var start_world: Vector2 = _call_vector2(_cell_center, counter_cell) + _bouquet_offset(maxi(0, pile_index))
	animate_world_rose_to_client(
		start_world,
		target,
		on_arrival
	)


## Shared rose-to-client flight for both counter stock and a rose bought directly from a garden.
func animate_world_rose_to_client(
	start_world: Vector2,
	target: Node2D,
	on_arrival: Callable
) -> void:
	if target == null or not is_instance_valid(target):
		if not on_arrival.is_null():
			on_arrival.call()
		return
	var visual: GroundItemVisual = GROUND_ITEM_VISUAL_SCRIPT.new()
	if not visual.setup_catalog_item(ROSE_ITEM_ID):
		visual.free()
		if not on_arrival.is_null():
			on_arrival.call()
		return
	_resolve_pile_parent().add_child(visual)
	visual.set_flight_pose(start_world, 0.0, 20)
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(
		Callable(self, "_update_counter_rose_to_client_flight").bind(visual, start_world, target),
		0.0,
		1.0,
		HARVEST_ROSE_FLIGHT_SECONDS
	)
	tween.parallel().tween_property(visual.sprite, "rotation", TAU, HARVEST_ROSE_FLIGHT_SECONDS)
	tween.tween_callback(Callable(self, "_on_counter_rose_reached_client").bind(visual, on_arrival))


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


func clear_pile(counter_cell: Vector2i) -> void:
	var nodes: Array = _pile_nodes_by_cell.get(counter_cell, []) as Array
	for raw_node: Variant in nodes:
		var node: Node = raw_node as Node
		if node != null and is_instance_valid(node):
			_bouquet_sprites_freed += 1
			node.queue_free()
	_pile_nodes_by_cell.erase(counter_cell)


func clear_all_piles() -> void:
	var cells: Array = _pile_nodes_by_cell.keys()
	for raw_cell: Variant in cells:
		var cell: Vector2i = raw_cell as Vector2i
		clear_pile(cell)
	_pile_nodes_by_cell.clear()


func _attach_pile_sprite(sprite: Sprite2D) -> void:
	var parent: Node = _resolve_pile_parent()
	if parent == null or not is_instance_valid(parent):
		sprite.queue_free()
		return
	call_deferred("_add_pile_sprite_to_parent", parent, sprite)


func _add_pile_sprite_to_parent(parent: Node, sprite: Sprite2D) -> void:
	if parent == null or sprite == null:
		return
	if not is_instance_valid(parent) or not is_instance_valid(sprite):
		return
	if sprite.is_queued_for_deletion() or sprite.get_parent() != null:
		return
	parent.add_child(sprite)


# Every counter is emptied (triggered when the last client of the sale leaves). The
# logical stock drops to zero immediately while persistent bouquet slots hide in
# reverse fill order for a visual "counters emptying" effect.
func dissolve_all_piles(total_seconds: float = NIGHTFALL_DISSOLVE_SECONDS) -> void:
	var piles: Array = []  # Array[Array[Sprite2D]] - visible slots in fill order (last == next hidden)
	var max_count: int = 0
	for raw_cell: Variant in _pile_nodes_by_cell.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var nodes: Array = _pile_nodes_by_cell[cell] as Array
		var visible_nodes: Array[Sprite2D] = []
		var count: int = mini(stock(cell), nodes.size())
		for index: int in range(count):
			var sprite: Sprite2D = nodes[index] as Sprite2D
			if sprite != null and is_instance_valid(sprite) and sprite.visible:
				visible_nodes.append(sprite)
		if visible_nodes.is_empty():
			continue
		piles.append(visible_nodes)
		max_count = maxi(max_count, visible_nodes.size())
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
		var sprite: Sprite2D = nodes.pop_back() as Sprite2D
		if sprite != null and is_instance_valid(sprite):
			sprite.visible = false


func _update_harvest_rose_flight(progress: float, visual: GroundItemVisual, start_world: Vector2, end_world: Vector2) -> void:
	if not is_instance_valid(visual):
		return
	visual.set_arc_flight_pose(start_world, end_world, progress, HARVEST_ROSE_ARC_HEIGHT, 0.0, 0.0, 10)


func _update_counter_rose_to_client_flight(progress: float, visual: GroundItemVisual, start_world: Vector2, target: Node2D) -> void:
	if not is_instance_valid(visual):
		return
	# Endpoint re-read every tick so the rose homes onto the walking-away client.
	var end_world: Vector2 = start_world
	if target != null and is_instance_valid(target):
		end_world = target.global_position
	visual.set_arc_flight_pose(start_world, end_world, progress, CLIENT_ROSE_ARC_HEIGHT, 0.0, 0.0, 20)


func _on_counter_rose_reached_client(visual: GroundItemVisual, on_arrival: Callable) -> void:
	if is_instance_valid(visual):
		visual.queue_free()
	if not on_arrival.is_null():
		on_arrival.call()


func bouquet_sprites_created_count() -> int:
	return _bouquet_sprites_created


func bouquet_sprites_freed_count() -> int:
	return _bouquet_sprites_freed


func last_stock_logic_us() -> int:
	return _last_stock_logic_us


func last_pile_sync_us() -> int:
	return _last_pile_sync_us


func last_notify_us() -> int:
	return _last_notify_us


func _sync_pile_visibility(counter_cell: Vector2i, count: int) -> void:
	if not _pile_nodes_by_cell.has(counter_cell):
		return
	var nodes: Array = _pile_nodes_by_cell[counter_cell] as Array
	var visible_count: int = clampi(count, 0, mini(MAX_STOCK_PER_COUNTER, nodes.size()))
	for index: int in range(nodes.size()):
		var sprite: Sprite2D = nodes[index] as Sprite2D
		if sprite == null or not is_instance_valid(sprite):
			continue
		sprite.visible = index < visible_count


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
