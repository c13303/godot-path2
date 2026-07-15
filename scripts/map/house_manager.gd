class_name HouseManager
extends RefCounted

signal house_completed(snapshot)
signal house_removing(snapshot)
signal houses_restored

## Owns everything about houses: their fixed geometry, the authoritative registry, sprite
## snapping / Y-sorting, footprint-wall stamping, authored-house discovery, and generic
## runtime house creation. It is a focused domain owner instantiated and wired by
## BuildingManager; it never performs flow-field generation, garden rebuilding, general
## building placement, inventory, build-menu state, save/load, removal, health, or merchant
## AI. It reaches BuildingManager only through intention-revealing public APIs.
##
## Fixed geometry (this pass): a house has a 3x2 blocking presence anchored on its entrance
## cell (0,0), which stays walkable:
##
##     WWW      (-1,-1) ( 0,-1) ( 1,-1)
##     WEW      (-1, 0)  E(0,0)  ( 1, 0)
##
## The five W cells block navigation; the visual sprite is 3x3 (an extra purely-visual row
## above the WWW row) and never creates blockers there. Orientation, rotation and alternate
## footprints are intentionally out of scope.

## Blocking footprint cells relative to the entrance (0,0). The entrance itself is never here.
const FOOTPRINT_OFFSETS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
]
## Fully transparent wallz atlas tile: blocks navigation/building/placement, renders nothing.
## Same invisible blocker the reservoir base uses (see LevelLoader.RESERVOIR_BASE_WALL_ATLAS).
const HOUSE_WALL_ATLAS: Vector2i = Vector2i(15, 0)
const AUTHORED_HOUSE_PREFIX: String = "house_"
const HOUSE_STATUS_WIP: StringName = &"wip"
const HOUSE_STATUS_COMPLETED: StringName = &"completed"
const RESIDENT_ROLE_NONE: StringName = &""
const RESIDENT_ROLE_FUNDAMENTAL_BUILDER: StringName = &"fundamental_builder"
## Set on a prepared authored house sprite so the runtime registry reads the resolved
## entrance cell instead of re-deriving it (which could drift after reparenting).
const ENTRANCE_CELL_META: StringName = &"house_entrance_cell"
const RUNTIME_HOUSE_CONTAINER_NAME: String = "Houses"

## Test-specific authored house -> companion spot-marker pairings. The geometry helpers stay
## generic (snap_node_to_house_entrance); only this table knows the merchant's spot node name.
const AUTHORED_SPOT_PAIRS: Dictionary = {
	"house_seedmerchant": "seedmerchent_spot",
}


## One logical record per house (not one per blocking cell).
class HouseRecord extends RefCounted:
	var id: StringName = &""
	## Catalog item id ("house"). Authored houses leave this empty (they are not inventory items).
	var item_id: String = ""
	var sprite: Sprite2D = null
	var entrance_cell: Vector2i = Vector2i.ZERO
	var blocking_cells: Array[Vector2i] = []
	var authored: bool = false
	## Player-built runtime houses are the only removable/refundable/destructible houses.
	var player_built: bool = false
	var removable: bool = false
	var destructible: bool = false
	var under_construction: bool = false
	var status: StringName = HOUSE_STATUS_COMPLETED
	var construction_order: int = 0
	var resident_role: StringName = RESIDENT_ROLE_NONE


class HouseSnapshot extends RefCounted:
	var id: StringName = &""
	var item_id: String = ""
	var resident_type: StringName = &""
	var resident_role: StringName = &""
	var entrance_cell: Vector2i = Vector2i.ZERO
	var entrance_world_position: Vector2 = Vector2.ZERO
	var completed: bool = false
	var player_built: bool = false
	var authored: bool = false


var _manager: BuildingManager = null
var _floor: TileMapLayer = null
var _wallz: TileMapLayer = null
var _houses: Array[HouseRecord] = []
var _entrance_to_house: Dictionary = {}
## Every one of a house's six presence cells (five blockers + the walkable entrance) maps to its
## owning HouseRecord. Drives placement-conflict detection, hover/unbuild resolution from any
## footprint cell, rectangle-removal dedup and durability validity. One house is one logical object.
var _presence_to_house: Dictionary = {}
## Monotonic counter for unique runtime (player-built) house ids.
var _runtime_house_seq: int = 0
var _next_construction_order: int = 1


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_floor = manager.floorz
	_wallz = manager.wallz


# ---------------------------------------------------------------------------
# Authored house preparation (static; runs on the off-tree level instance).
# ---------------------------------------------------------------------------

## Normalizes every authored house (a `house_`-prefixed Sprite2D under the spawner
## container) inside the off-tree level instance: derives its entrance from the authored
## sprite, snaps the sprite + Y-sorts it, stamps its five invisible footprint walls, records
## the entrance in metadata, and snaps any paired spot marker to the entrance centre.
##
## LevelLoader must call this BEFORE it captures spawner bindings, because a paired spot
## (e.g. seedmerchent_spot) is converted into the merchant's stored spot_cell and must be in
## its final position first. This mutates the level's floor/wallz layers and spawner nodes in
## place; it does not register anything (no BuildingManager exists yet) — the live nodes are
## registered later via register_authored_houses().
static func prepare_authored_houses(level_root: Node) -> void:
	if level_root == null:
		return
	var floor_layer: TileMapLayer = level_root.get_node_or_null("floor") as TileMapLayer
	var wall_layer: TileMapLayer = level_root.get_node_or_null("wallz") as TileMapLayer
	if floor_layer == null or wall_layer == null:
		push_warning("HouseManager: authored preparation skipped; level is missing a floor or wallz layer.")
		return
	var spawner_container: Node = _find_spawner_container(level_root)
	if spawner_container == null:
		return
	var source_id: int = _wallz_atlas_source_id(wall_layer)
	if source_id < 0:
		push_error("HouseManager: wallz tile_set has no atlas source; cannot stamp authored house walls.")
		return
	var stamped_any: bool = false
	for child: Node in spawner_container.get_children():
		var sprite: Sprite2D = child as Sprite2D
		if sprite == null or not String(sprite.name).begins_with(AUTHORED_HOUSE_PREFIX):
			continue
		if sprite.texture == null:
			push_warning("HouseManager: authored house '%s' has no texture; skipping." % sprite.name)
			continue
		var entrance: Vector2i = _derive_entrance_cell_from_sprite(sprite, floor_layer)
		_snap_house_sprite_to_entrance(sprite, entrance, floor_layer)
		sprite.set_meta(ENTRANCE_CELL_META, entrance)
		if _stamp_authored_house_walls(wall_layer, source_id, sprite.name, entrance):
			stamped_any = true
		_snap_paired_spot(spawner_container, sprite.name, entrance, floor_layer)
	if stamped_any:
		wall_layer.update_internals()


## Stamps the five footprint cells with the invisible blocker for one authored house.
## Never overwrites the entrance (must stay walkable) and never erases authored tiles: an
## already-walled footprint cell is left as-is. Returns true if any cell was newly stamped.
static func _stamp_authored_house_walls(wall_layer: TileMapLayer, source_id: int, house_name: String, entrance: Vector2i) -> bool:
	if wall_layer.get_cell_source_id(entrance) >= 0:
		push_error("HouseManager: authored house '%s' entrance %s already has a wall tile; entrance must stay walkable." % [house_name, str(entrance)])
	var stamped: bool = false
	for offset: Vector2i in FOOTPRINT_OFFSETS:
		var cell: Vector2i = entrance + offset
		if wall_layer.get_cell_source_id(cell) >= 0:
			if wall_layer.get_cell_atlas_coords(cell) != HOUSE_WALL_ATLAS:
				push_warning("HouseManager: authored house '%s' footprint cell %s already holds a non-standard wall tile; leaving it in place." % [house_name, str(cell)])
			continue
		wall_layer.set_cell(cell, source_id, HOUSE_WALL_ATLAS)
		stamped = true
	return stamped


static func _snap_paired_spot(spawner_container: Node, house_name: String, entrance: Vector2i, floor_layer: TileMapLayer) -> void:
	var spot_name: String = String(AUTHORED_SPOT_PAIRS.get(house_name, ""))
	if spot_name == "":
		return
	var spot: Node2D = spawner_container.get_node_or_null(NodePath(spot_name)) as Node2D
	if spot != null:
		snap_node_to_house_entrance(spot, entrance, floor_layer)


## Registers the already-prepared live authored house nodes into the authoritative registry.
## Called by BuildingManager after the spawner container has been reparented under MonTilemap.
## Reads the entrance from metadata (set during prepare_authored_houses) so it never re-derives
## geometry, and never stamps walls or triggers a topology rebuild — the authored blockers were
## stamped at load time and are consumed by normal startup topology scanning.
func register_authored_houses() -> void:
	var container: Node = _authored_house_container()
	if container == null:
		return
	for child: Node in container.get_children():
		var sprite: Sprite2D = child as Sprite2D
		if sprite == null or not String(sprite.name).begins_with(AUTHORED_HOUSE_PREFIX):
			continue
		if not sprite.has_meta(ENTRANCE_CELL_META):
			push_warning("HouseManager: authored house '%s' has no prepared entrance metadata; not registered." % sprite.name)
			continue
		var entrance: Vector2i = sprite.get_meta(ENTRANCE_CELL_META) as Vector2i
		# Authored houses reserve their full six-cell presence (so nothing can be built on their
		# walls or walkable entrance) but are never player-built: not removable, not refundable,
		# not destructible.
		var item_id: String = _authored_house_item_id(sprite.name)
		var record: HouseRecord = _register_house_record(StringName(sprite.name), item_id, sprite, entrance, true, false)
		record.player_built = false
		record.removable = false
		record.destructible = false
		record.status = HOUSE_STATUS_COMPLETED


func _authored_house_item_id(house_name: StringName) -> String:
	if String(house_name) == "house_seedmerchant":
		return "house_merchant"
	return ""


# ---------------------------------------------------------------------------
# Runtime house creation.
# ---------------------------------------------------------------------------

## Generic runtime house builder. `source` may be a Texture2D or a prepared Sprite2D.
## Validates the whole 3x2 presence atomically and rejects (no mutation) if anything is
## invalid, then commits in one batch: sprite -> snap -> z-index -> five walls (one
## update_internals) -> immediate player collision -> registry -> a single hard-topology
## invalidation -> WIP task notification. Returns true on success.
func create_house(
		id: StringName,
		source: Variant,
		entrance: Vector2i,
		parent: Node = null,
		item_id: String = "house_merchant",
		status: StringName = HOUSE_STATUS_WIP,
		construction_order: int = -1
) -> bool:
	item_id = ItemCatalog.normalize_house_item_id(item_id)
	var texture: Texture2D = _resolve_texture(source)
	var rejection: String = _validate_runtime_house(entrance, texture)
	if rejection != "":
		push_warning("HouseManager: runtime house '%s' at %s rejected: %s" % [String(id), str(entrance), rejection])
		return false

	var source_id: int = _wallz_atlas_source_id(_wallz)
	var sprite: Sprite2D = _make_runtime_sprite(source, texture, id)
	var container: Node = parent if parent != null else _runtime_house_container()
	container.add_child(sprite)
	_snap_house_sprite_to_entrance(sprite, entrance, _floor)

	var footprint: Array[Vector2i] = _footprint_cells(entrance)
	for cell: Vector2i in footprint:
		_wallz.set_cell(cell, source_id, HOUSE_WALL_ATLAS)
	_wallz.update_internals()
	# Native single-cell collision so the player is blocked instantly, before the budgeted
	# walkability rebuild re-bakes wallz into the flow field.
	for cell: Vector2i in footprint:
		_manager.set_player_navigation_cell_blocked(cell, true)

	var record: HouseRecord = _register_house_record(id, item_id, sprite, entrance, false, true)
	record.player_built = true
	record.removable = true
	record.destructible = ItemCatalog.get_max_health(item_id) > 0
	record.status = _normalized_status(status)
	record.construction_order = _assign_construction_order(construction_order)
	# One destructible target for the whole house (entrance-keyed on the logical "houses" layer),
	# never five per-cell targets. Registered through BuildingManager's durability facade.
	if record.destructible:
		_manager.register_player_built_house_durability(entrance, item_id)
	# Exactly one hard-topology invalidation for the whole house; the existing runtime system
	# then batches the quiet window, budgeted walkability rebuild, garden/route updates and
	# lazy flow-field recomputation.
	_manager.get_building_invalidation_controller().after_walkability_changed("runtime_house_built")
	if record.status == HOUSE_STATUS_WIP:
		_manager.get_house_builder_work_controller().on_wip_house_added(record.id)
	elif record.status == HOUSE_STATUS_COMPLETED:
		house_completed.emit(_snapshot_for_record(record))
	return true


## Player-build entry point used by BuildPlacementService after it has validated the footprint
## and consumed one inventory unit. Owns the runtime id + catalog texture so the placement
## service stays free of house geometry. Returns false (no mutation) if the atomic re-validation
## inside create_house fails, letting the caller restore the consumed item.
func build_player_house(item_id: String, entrance: Vector2i) -> bool:
	item_id = ItemCatalog.normalize_house_item_id(item_id)
	var texture: Texture2D = ItemCatalog.get_house_wip_texture(item_id)
	if texture == null:
		texture = ItemCatalog.get_house_completed_texture(item_id)
	if texture == null:
		push_warning("HouseManager: item '%s' has no house texture; cannot build." % item_id)
		return false
	return create_house(_next_runtime_house_id(), texture, entrance, null, item_id)


func _next_runtime_house_id() -> StringName:
	_runtime_house_seq += 1
	return StringName("house_runtime_%d" % _runtime_house_seq)


# ---------------------------------------------------------------------------
# Removal (normal unbuild + hostile destruction). Both tear the whole house down atomically.
# ---------------------------------------------------------------------------

## Normal player unbuild of one complete player-built house. Removes its single durability record,
## then tears the house down. Returns true on success; the caller (BuildRemovalService) performs
## the single inventory refund. Authored / non-player houses are rejected.
func remove_player_built_house(entrance: Vector2i) -> bool:
	var record: HouseRecord = _entrance_to_house.get(entrance, null) as HouseRecord
	if record == null or not record.player_built or not record.removable:
		return false
	# Normal unbuild does not go through the durability destroy path, so drop the record here.
	if record.destructible:
		_manager.remove_house_durability_record(entrance)
	_teardown_house(record)
	return true


## Hostile no-refund destruction of one complete player-built house. The durability service has
## already erased its own record before dispatching here, so this only tears down geometry/sprite.
func remove_player_built_house_no_refund(entrance: Vector2i) -> bool:
	var record: HouseRecord = _entrance_to_house.get(entrance, null) as HouseRecord
	if record == null or not record.player_built:
		return false
	_teardown_house(record)
	return true


## Atomic geometry/sprite teardown shared by normal unbuild and hostile destruction: erase the five
## owned blocker cells (one update_internals), refresh player collision, free the sprite, drop every
## registry/presence entry, and trigger exactly one hard-topology invalidation. Never refunds.
func _teardown_house(record: HouseRecord) -> void:
	house_removing.emit(_snapshot_for_record(record))
	if record.status == HOUSE_STATUS_WIP:
		_manager.get_house_builder_work_controller().on_wip_house_removed(record.id)
	var blockers: Array[Vector2i] = record.blocking_cells
	for cell: Vector2i in blockers:
		if _wallz.get_cell_source_id(cell) < 0:
			continue
		# Ownership safety: only erase a cell still holding this house's invisible blocker.
		if _wallz.get_cell_atlas_coords(cell) != HOUSE_WALL_ATLAS:
			push_warning("HouseManager: blocker cell %s no longer holds a house wall; leaving foreign content in place." % str(cell))
			continue
		_wallz.erase_cell(cell)
	_wallz.update_internals()
	for cell: Vector2i in blockers:
		_manager.set_player_navigation_cell_blocked(cell, false)
	if record.sprite != null and is_instance_valid(record.sprite):
		record.sprite.queue_free()
	record.sprite = null
	_unregister_house_record(record)
	_manager.get_building_invalidation_controller().after_walkability_changed("house_removed")


# ---------------------------------------------------------------------------
# Sprite positioning shared with the preview + health-bar anchoring for durability.
# ---------------------------------------------------------------------------

## Positions any house sprite (the real one OR a translucent preview sprite) exactly as it will
## sit after placement: bottom-centre on the entrance cell's bottom edge, entrance-top-edge z-index.
## Uses global coordinates, so a preview sprite parented under a different layer snaps identically.
func position_house_sprite(sprite: Sprite2D, entrance: Vector2i) -> void:
	if sprite == null or _floor == null:
		return
	_snap_house_sprite_to_entrance(sprite, entrance, _floor)


## World point above the visible house sprite, used by the durability health bar so it floats over
## the roof rather than over the walkable ground entrance. Falls back to the entrance centre.
func get_house_health_bar_world_position(entrance: Vector2i) -> Vector2:
	var record: HouseRecord = _entrance_to_house.get(entrance, null) as HouseRecord
	if record == null or record.sprite == null or not is_instance_valid(record.sprite) or record.sprite.texture == null:
		return _manager.cell_center(entrance)
	var bottom_center: Vector2 = _sprite_bottom_center_world(record.sprite)
	var tex_height: float = record.sprite.texture.get_size().y * absf(record.sprite.global_scale.y)
	return bottom_center - Vector2(0.0, tex_height)


# ---------------------------------------------------------------------------
# Save / restore of player-built runtime houses (authored houses are recreated by level loading).
# ---------------------------------------------------------------------------

## Minimal save records for player-built houses only: catalog item id, entrance cell, persistent
## WIP/completed status, and deterministic construction order. The five blockers are already
## serialized through wallz; the sprite and logical registry are rebuilt from these on load.
## Runtime Builder work progress is intentionally not saved.
func serialize_player_built_houses() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for record: HouseRecord in _houses:
		if not record.player_built:
			continue
		out.append({
			"item_id": record.item_id,
			"entrance_x": record.entrance_cell.x,
			"entrance_y": record.entrance_cell.y,
			"status": String(record.status),
			"construction_order": record.construction_order,
			"resident_role": String(record.resident_role),
		})
	return out


## Rebuilds player-built houses from saved records: recreates each sprite + six-cell registry
## ownership, reusing the blocker cells already restored from the wallz layer (repairing any missing
## one in a single batched update_internals). No per-house topology rebuild and no construction
## visual — startup navigation reconstructs routing from the restored map. Durability is restored
## separately, after this, so its "houses" records validate against the live registry.
func restore_player_built_houses(records: Array) -> void:
	var source_id: int = _wallz_atlas_source_id(_wallz)
	var repaired_any: bool = false
	var saw_resident_role_field: bool = false
	for raw_record: Variant in records:
		if not (raw_record is Dictionary):
			continue
		var entry: Dictionary = raw_record as Dictionary
		if entry.has("resident_role"):
			saw_resident_role_field = true
		var item_id: String = ItemCatalog.normalize_house_item_id(str(entry.get("item_id", "house_merchant")))
		var entrance: Vector2i = Vector2i(int(entry.get("entrance_x", 0)), int(entry.get("entrance_y", 0)))
		var status: StringName = _normalized_status(StringName(str(entry.get("status", String(HOUSE_STATUS_COMPLETED)))))
		var construction_order: int = int(entry.get("construction_order", -1))
		var resident_role: StringName = _normalized_resident_role(StringName(str(entry.get("resident_role", ""))))
		if _restore_one_player_house(item_id, entrance, source_id, status, construction_order, resident_role):
			repaired_any = true
	_normalize_fundamental_builder_house_role(not saw_resident_role_field)
	if repaired_any:
		_wallz.update_internals()
	houses_restored.emit()


func _restore_one_player_house(
		item_id: String,
		entrance: Vector2i,
		source_id: int,
		status: StringName,
		construction_order: int,
		resident_role: StringName
) -> bool:
	item_id = ItemCatalog.normalize_house_item_id(item_id)
	if _presence_to_house.has(entrance) or has_house_at_entrance(entrance):
		push_warning("HouseManager: saved house at %s conflicts with an existing house; skipping." % str(entrance))
		return false
	var texture: Texture2D = _texture_for_status(item_id, status)
	if texture == null:
		push_warning("HouseManager: saved house item '%s' has no texture; skipping." % item_id)
		return false
	var repaired: bool = false
	for cell: Vector2i in _footprint_cells(entrance):
		if _wallz.get_cell_source_id(cell) < 0 and source_id >= 0:
			_wallz.set_cell(cell, source_id, HOUSE_WALL_ATLAS)
			repaired = true
	var sprite: Sprite2D = Sprite2D.new()
	sprite.texture = texture
	sprite.centered = true
	sprite.name = String(_next_runtime_house_id())
	_runtime_house_container().add_child(sprite)
	_snap_house_sprite_to_entrance(sprite, entrance, _floor)
	var record: HouseRecord = _register_house_record(StringName(sprite.name), item_id, sprite, entrance, false, false)
	record.player_built = true
	record.removable = true
	record.destructible = ItemCatalog.get_max_health(item_id) > 0
	record.status = _normalized_status(status)
	record.construction_order = _assign_construction_order(construction_order)
	record.resident_role = _normalized_resident_role(resident_role)
	if record.status == HOUSE_STATUS_WIP:
		_manager.get_house_builder_work_controller().on_wip_house_added(record.id)
	return repaired


## Non-empty string = rejection reason (validated before any mutation). "" = valid.
func _validate_runtime_house(entrance: Vector2i, texture: Texture2D) -> String:
	if _floor == null or _wallz == null:
		return "map layers unavailable"
	if texture == null:
		return "house texture/sprite is invalid"
	if _wallz_atlas_source_id(_wallz) < 0:
		return "wall atlas source could not be resolved"
	if has_house_at_entrance(entrance):
		return "entrance already used by a house"
	if not _manager.is_walkable_cell(entrance):
		return "entrance is not a valid walkable floor cell"
	for cell: Vector2i in _footprint_cells(entrance):
		if not _manager.has_floor_cell(cell):
			return "footprint cell %s is outside the floor" % str(cell)
		if _manager.has_wall_cell(cell):
			return "footprint cell %s is already blocked" % str(cell)
	return ""


func _resolve_texture(source: Variant) -> Texture2D:
	var sprite: Sprite2D = source as Sprite2D
	if sprite != null:
		return sprite.texture
	return source as Texture2D


func _make_runtime_sprite(source: Variant, texture: Texture2D, id: StringName) -> Sprite2D:
	var sprite: Sprite2D = source as Sprite2D
	if sprite != null:
		if sprite.get_parent() != null:
			sprite.get_parent().remove_child(sprite)
	else:
		sprite = Sprite2D.new()
		sprite.centered = true
	sprite.texture = texture
	sprite.name = String(id)
	return sprite


func _texture_for_status(item_id: String, status: StringName) -> Texture2D:
	item_id = ItemCatalog.normalize_house_item_id(item_id)
	if _normalized_status(status) == HOUSE_STATUS_WIP:
		var wip_texture: Texture2D = ItemCatalog.get_house_wip_texture(item_id)
		if wip_texture != null:
			return wip_texture
	return ItemCatalog.get_house_completed_texture(item_id)


func _normalized_status(status: StringName) -> StringName:
	if status == HOUSE_STATUS_WIP:
		return HOUSE_STATUS_WIP
	return HOUSE_STATUS_COMPLETED


func _normalized_resident_role(role: StringName) -> StringName:
	if role == RESIDENT_ROLE_FUNDAMENTAL_BUILDER:
		return RESIDENT_ROLE_FUNDAMENTAL_BUILDER
	return RESIDENT_ROLE_NONE


func _assign_construction_order(saved_order: int) -> int:
	var order: int = saved_order
	if order <= 0:
		order = _next_construction_order
	_next_construction_order = maxi(_next_construction_order, order + 1)
	return order


func _runtime_house_container() -> Node2D:
	var host: Node = _floor.get_parent() if _floor != null else null
	if host == null:
		return null
	var container: Node2D = host.get_node_or_null(NodePath(RUNTIME_HOUSE_CONTAINER_NAME)) as Node2D
	if container == null:
		container = Node2D.new()
		container.name = RUNTIME_HOUSE_CONTAINER_NAME
		host.add_child(container)
	return container


# ---------------------------------------------------------------------------
# Registry + queries.
# ---------------------------------------------------------------------------

func _register_house_record(id: StringName, item_id: String, sprite: Sprite2D, entrance: Vector2i, authored: bool, under_construction: bool = false) -> HouseRecord:
	var record: HouseRecord = HouseRecord.new()
	record.id = id
	record.item_id = item_id
	record.sprite = sprite
	record.entrance_cell = entrance
	record.blocking_cells = _footprint_cells(entrance)
	record.authored = authored
	record.under_construction = under_construction
	_houses.append(record)
	_entrance_to_house[entrance] = record
	for cell: Vector2i in _presence_cells(entrance):
		_presence_to_house[cell] = record
	return record


## Removes a record from every index (registry, entrance lookup, and all six presence cells).
func _unregister_house_record(record: HouseRecord) -> void:
	if record == null:
		return
	_houses.erase(record)
	_entrance_to_house.erase(record.entrance_cell)
	for cell: Vector2i in _presence_cells(record.entrance_cell):
		if _presence_to_house.get(cell) == record:
			_presence_to_house.erase(cell)


func has_house_at_entrance(entrance: Vector2i) -> bool:
	return _entrance_to_house.has(entrance)


func find_house_by_name(id: StringName) -> HouseRecord:
	for record: HouseRecord in _houses:
		if record.id == id:
			return record
	return null


func get_house_entrance(id: StringName) -> Vector2i:
	var record: HouseRecord = find_house_by_name(id)
	return record.entrance_cell if record != null else Vector2i(2147483647, 2147483647)


func get_house_sprite(id: StringName) -> Sprite2D:
	var record: HouseRecord = find_house_by_name(id)
	if record == null or record.sprite == null or not is_instance_valid(record.sprite):
		return null
	return record.sprite


## Ground-plane middle of the six-cell house presence, for visuals that must point at the house
## itself (the sprite centre sits up in the roof overhang instead). Vector2.INF when unknown.
func get_house_center_world(id: StringName) -> Vector2:
	var record: HouseRecord = find_house_by_name(id)
	if record == null or _manager == null:
		return Vector2.INF
	var cells: Array[Vector2i] = _presence_cells(record.entrance_cell)
	var sum: Vector2 = Vector2.ZERO
	for cell: Vector2i in cells:
		sum += _manager.cell_center(cell)
	return sum / float(cells.size())


func house_status(house_id: StringName) -> StringName:
	var record: HouseRecord = find_house_by_name(house_id)
	return record.status if record != null else &""


func is_house_wip(house_id: StringName) -> bool:
	return house_status(house_id) == HOUSE_STATUS_WIP


func is_house_completed(house_id: StringName) -> bool:
	return house_status(house_id) == HOUSE_STATUS_COMPLETED


func get_wip_house_ids_in_build_order() -> Array[StringName]:
	var records: Array[HouseRecord] = []
	for record: HouseRecord in _houses:
		if record.player_built and record.status == HOUSE_STATUS_WIP:
			records.append(record)
	records.sort_custom(func(a: HouseRecord, b: HouseRecord) -> bool:
		if a.construction_order == b.construction_order:
			return String(a.id) < String(b.id)
		return a.construction_order < b.construction_order
	)
	var ids: Array[StringName] = []
	for record: HouseRecord in records:
		ids.append(record.id)
	return ids


func complete_house(house_id: StringName) -> bool:
	var record: HouseRecord = find_house_by_name(house_id)
	if record == null or record.status != HOUSE_STATUS_WIP:
		return false
	var texture: Texture2D = ItemCatalog.get_house_completed_texture(record.item_id)
	if texture == null:
		push_warning("HouseManager: completed texture missing for house '%s' item '%s'." % [String(house_id), record.item_id])
		return false
	record.status = HOUSE_STATUS_COMPLETED
	if record.item_id == "house_builder" and _fundamental_builder_house_record() == null:
		record.resident_role = RESIDENT_ROLE_FUNDAMENTAL_BUILDER
	if record.sprite != null and is_instance_valid(record.sprite):
		record.sprite.texture = texture
	house_completed.emit(_snapshot_for_record(record))
	return true


func complete_all_wip_houses_for_dev() -> int:
	var completed: int = 0
	for house_id: StringName in get_wip_house_ids_in_build_order():
		_manager.get_house_builder_work_controller().on_wip_house_removed(house_id)
		if complete_house(house_id):
			completed += 1
	return completed


func house_work_seconds(house_id: StringName) -> float:
	var record: HouseRecord = find_house_by_name(house_id)
	if record == null:
		return 0.0
	return ItemCatalog.get_house_builder_work_seconds(record.item_id)


func is_house_navigation_ready(house_id: StringName) -> bool:
	if find_house_by_name(house_id) == null:
		return false
	var invalidation: BuildingInvalidationController = _manager.get_building_invalidation_controller()
	return not invalidation.navigation_topology_dirty() and not invalidation.runtime_rebuild_active()


func get_house_blocking_cells(id: StringName) -> Array[Vector2i]:
	var record: HouseRecord = find_house_by_name(id)
	if record == null:
		return []
	var cells: Array[Vector2i] = []
	for cell: Vector2i in record.blocking_cells:
		cells.append(cell)
	return cells


func house_count() -> int:
	return _houses.size()


func count_completed_houses(item_id: StringName) -> int:
	var normalized_id: String = ItemCatalog.normalize_house_item_id(String(item_id))
	var count: int = 0
	for record: HouseRecord in _houses:
		if record.item_id == normalized_id and record.status == HOUSE_STATUS_COMPLETED:
			count += 1
	return count


func count_existing_houses(item_id: StringName) -> int:
	var normalized_id: String = ItemCatalog.normalize_house_item_id(String(item_id))
	var count: int = 0
	for record: HouseRecord in _houses:
		if record.item_id == normalized_id:
			count += 1
	return count


func get_completed_house_ids(item_id: StringName) -> Array[StringName]:
	var normalized_id: String = ItemCatalog.normalize_house_item_id(String(item_id))
	var ids: Array[StringName] = []
	for record: HouseRecord in _houses:
		if record.item_id == normalized_id and record.status == HOUSE_STATUS_COMPLETED:
			ids.append(record.id)
	return ids


func get_completed_normal_resident_house_ids(item_id: StringName) -> Array[StringName]:
	var normalized_id: String = ItemCatalog.normalize_house_item_id(String(item_id))
	var ids: Array[StringName] = []
	for record: HouseRecord in _houses:
		if record.item_id == normalized_id and record.status == HOUSE_STATUS_COMPLETED and record.resident_role == RESIDENT_ROLE_NONE:
			ids.append(record.id)
	return ids


func fundamental_builder_house_id() -> StringName:
	var record: HouseRecord = _fundamental_builder_house_record()
	return record.id if record != null else &""


func is_fundamental_builder_house(house_id: StringName) -> bool:
	var record: HouseRecord = find_house_by_name(house_id)
	return record != null and record.resident_role == RESIDENT_ROLE_FUNDAMENTAL_BUILDER


func get_house_snapshot(house_id: StringName) -> HouseSnapshot:
	var record: HouseRecord = find_house_by_name(house_id)
	return _snapshot_for_record(record)


func get_completed_house_snapshots() -> Array[HouseSnapshot]:
	var snapshots: Array[HouseSnapshot] = []
	for record: HouseRecord in _houses:
		if record.status == HOUSE_STATUS_COMPLETED:
			snapshots.append(_snapshot_for_record(record))
	return snapshots


func has_existing_house_type(item_id: String) -> bool:
	return count_existing_houses(StringName(item_id)) > 0


func _snapshot_for_record(record: HouseRecord) -> HouseSnapshot:
	var snapshot: HouseSnapshot = HouseSnapshot.new()
	if record == null:
		return snapshot
	snapshot.id = record.id
	snapshot.item_id = record.item_id
	snapshot.resident_type = ItemCatalog.get_house_resident_type(record.item_id)
	snapshot.resident_role = record.resident_role
	snapshot.entrance_cell = record.entrance_cell
	snapshot.entrance_world_position = _manager.cell_center(record.entrance_cell) if _manager != null else Vector2.ZERO
	snapshot.completed = record.status == HOUSE_STATUS_COMPLETED
	snapshot.player_built = record.player_built
	snapshot.authored = record.authored
	return snapshot


func _normalize_fundamental_builder_house_role(assign_oldest_when_missing: bool) -> void:
	var selected: HouseRecord = null
	for record: HouseRecord in _houses:
		if record.resident_role != RESIDENT_ROLE_FUNDAMENTAL_BUILDER:
			continue
		if not _is_completed_builder_house(record):
			record.resident_role = RESIDENT_ROLE_NONE
			continue
		if selected == null or _construction_order_less(record, selected):
			if selected != null:
				selected.resident_role = RESIDENT_ROLE_NONE
			selected = record
		else:
			record.resident_role = RESIDENT_ROLE_NONE
	if selected != null:
		return
	if not assign_oldest_when_missing:
		return
	var oldest: HouseRecord = null
	for record: HouseRecord in _houses:
		if not _is_completed_builder_house(record):
			continue
		if oldest == null or _construction_order_less(record, oldest):
			oldest = record
	if oldest != null:
		oldest.resident_role = RESIDENT_ROLE_FUNDAMENTAL_BUILDER


func _fundamental_builder_house_record() -> HouseRecord:
	for record: HouseRecord in _houses:
		if _is_completed_builder_house(record) and record.resident_role == RESIDENT_ROLE_FUNDAMENTAL_BUILDER:
			return record
	return null


func _is_completed_builder_house(record: HouseRecord) -> bool:
	return record != null and record.item_id == "house_builder" and record.status == HOUSE_STATUS_COMPLETED


func _construction_order_less(a: HouseRecord, b: HouseRecord) -> bool:
	if a.construction_order == b.construction_order:
		return String(a.id) < String(b.id)
	return a.construction_order < b.construction_order


# ---------------------------------------------------------------------------
# Geometry helpers (shared by authored + runtime paths).
# ---------------------------------------------------------------------------

func _footprint_cells(entrance: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for offset: Vector2i in FOOTPRINT_OFFSETS:
		cells.append(entrance + offset)
	return cells


## The complete six-cell reserved presence: the five blocking footprint cells plus the walkable
## entrance. This is the single geometry authority for placement, preview, occupancy and removal.
func _presence_cells(entrance: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = _footprint_cells(entrance)
	cells.append(entrance)
	return cells


# ---------------------------------------------------------------------------
# Public geometry / registry queries (shared by placement, preview, removal, durability, save).
# ---------------------------------------------------------------------------

## The six occupied presence cells (five walls + walkable entrance) for a hovered entrance cell.
func get_presence_cells(entrance: Vector2i) -> Array[Vector2i]:
	return _presence_cells(entrance)


## The five navigation-blocking wall cells for an entrance cell (excludes the entrance).
func get_blocking_cells(entrance: Vector2i) -> Array[Vector2i]:
	return _footprint_cells(entrance)


## The house owning `cell` (any of its six presence cells), or null. Used to resolve one logical
## house from any hovered footprint cell during placement conflict checks and unbuild.
func get_house_at_presence_cell(cell: Vector2i) -> HouseRecord:
	return _presence_to_house.get(cell, null) as HouseRecord


func has_player_built_house_at_entrance(entrance: Vector2i) -> bool:
	var record: HouseRecord = _entrance_to_house.get(entrance, null) as HouseRecord
	return record != null and record.player_built


## House-specific structural rejection for placing a new house with `entrance` as its anchor.
## Non-empty string = reason (no mutation happens). Complements the generic per-cell buildable
## checks that BuildPlacementService runs on each presence cell; this owns the geometry-level
## invariants (map bounds, walkable entrance, overlap with an existing house).
func house_structural_rejection(entrance: Vector2i) -> String:
	if _floor == null or _wallz == null:
		return "map layers unavailable"
	for cell: Vector2i in _presence_cells(entrance):
		if not _manager.has_floor_cell(cell):
			return "presence cell %s is outside the floor" % str(cell)
		if _presence_to_house.has(cell):
			return "presence cell %s already belongs to a house" % str(cell)
	if not _manager.is_walkable_cell(entrance):
		return "entrance %s is not a valid walkable floor cell" % str(entrance)
	return ""


## Derives the entrance cell from an authored sprite: the sprite bottom-centre sits on the
## bottom edge of the entrance cell, so probing half a tile up from there lands on the
## entrance cell centre.
static func _derive_entrance_cell_from_sprite(sprite: Sprite2D, floor_layer: TileMapLayer) -> Vector2i:
	var base_world: Vector2 = _sprite_bottom_center_world(sprite)
	var tile_height: float = _tile_size(floor_layer).y
	var probe_world: Vector2 = base_world - Vector2(0.0, tile_height * 0.5)
	return floor_layer.local_to_map(floor_layer.to_local(probe_world))


## Snaps a house sprite so the middle of its bottom edge lands on the bottom edge of the
## entrance cell (X = entrance centre X, Y = entrance centre Y + half a tile), then Y-sorts it
## against agents (agents use z_index = int(world Y)).
##
## The Y-sort anchor is the TOP edge of the entrance cell (the front face of the solid walls),
## NOT the sprite's bottom edge. The entrance is walkable, so an agent standing in the doorway
## must draw in FRONT of the house; anchoring at the bottom edge put an agent near the top of
## the entrance tile behind the sprite. With the top-edge anchor, any agent whose feet are at
## or below the entrance top edge (the whole entrance tile and everything south of it) sorts in
## front, while the purely-visual overhang rows above the walls still sort behind.
static func _snap_house_sprite_to_entrance(sprite: Sprite2D, entrance: Vector2i, floor_layer: TileMapLayer) -> void:
	var entrance_center_world: Vector2 = floor_layer.to_global(floor_layer.map_to_local(entrance))
	var half_tile_height: float = _tile_size(floor_layer).y * 0.5
	var target_bottom_center: Vector2 = entrance_center_world + Vector2(0.0, half_tile_height)
	var current_bottom_center: Vector2 = _sprite_bottom_center_world(sprite)
	sprite.global_position += target_bottom_center - current_bottom_center
	sprite.z_as_relative = false
	sprite.z_index = int(entrance_center_world.y - half_tile_height)


## Middle of the sprite's bottom edge in world space (centered sprites put the origin at the
## middle; otherwise the top-left corner is the origin). Uses the real texture + offset +
## transform so it works for any sprite size/scale.
static func _sprite_bottom_center_world(sprite: Sprite2D) -> Vector2:
	var tex_size: Vector2 = sprite.texture.get_size()
	var base_local: Vector2 = sprite.offset
	if sprite.centered:
		base_local += Vector2(0.0, tex_size.y * 0.5)
	else:
		base_local += Vector2(tex_size.x * 0.5, tex_size.y)
	return sprite.to_global(base_local)


## Generic "snap a node to a house entrance cell centre". Kept free of merchant/house-type
## logic so any marker can be aligned to an entrance.
static func snap_node_to_house_entrance(node: Node2D, entrance: Vector2i, floor_layer: TileMapLayer) -> void:
	node.global_position = floor_layer.to_global(floor_layer.map_to_local(entrance))


static func _tile_size(layer: TileMapLayer) -> Vector2:
	if layer != null and layer.tile_set != null:
		return Vector2(layer.tile_set.tile_size)
	return Vector2(16.0, 16.0)


static func _wallz_atlas_source_id(wallz: TileMapLayer) -> int:
	if wallz == null or wallz.tile_set == null:
		return -1
	var tile_set: TileSet = wallz.tile_set
	for i: int in range(tile_set.get_source_count()):
		var source_id: int = tile_set.get_source_id(i)
		if tile_set.get_source(source_id) is TileSetAtlasSource:
			return source_id
	return -1


func _authored_house_container() -> Node:
	var host: Node = _floor.get_parent() if _floor != null else null
	if host == null:
		return null
	return _find_spawner_container(host)


static func _find_spawner_container(root: Node) -> Node:
	for container_name: String in ["spawners", "spawner"]:
		var container: Node = root.get_node_or_null(NodePath(container_name))
		if container != null:
			return container
	return null
