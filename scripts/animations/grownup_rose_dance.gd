extends Node2D
class_name GrownupRoseDance

## Gentle "ready to harvest" animation for full-bloom roses. Grownup rose tiles are
## redrawn on top of the plantz TileMapLayer with a subtle base-anchored sway plus a
## breathing squash/stretch, so each ready rose slightly balances and dances — the
## same "alive" idle feel the characters get from CharacterAnimation. Each rose is
## desynced by a random phase so the garden doesn't pulse in unison.
##
## Roses are TileMapLayer cells and so can't carry a per-tile transform; this node
## draws a copy of the grownup tile and animates that copy. It only reads which cells
## are grownup (from PlantManager) and never mutates the tilemap or plant state.

@export var plant_manager_path: NodePath
@export var plantz_path: NodePath

@export_group("Dance")
## Peak sway rotation, in degrees, of the flower head around its planted base.
@export var sway_degrees: float = 5.0
## Sway oscillations per second.
@export var sway_speed: float = 1.1
## Breathing scale delta on Y (0.05 = ±5%).
@export_range(0.0, 0.5) var breathe_amount: float = 0.05
## Breaths per second.
@export var breathe_speed: float = 1.4
## Widen X as Y squashes to fake constant volume (the classic cartoon look).
@export var preserve_volume: bool = true
## Tiny upward bob at the base, in px, for a touch more life.
@export var bob_pixels: float = 1.0

@export_group("Pop")
## Short squash/stretch pop played once when a wet rose visually opens.
@export var pop_duration: float = 0.22
## Extra scale at the peak of the pop.
@export var pop_overshoot: float = 0.33
## Starting scale for the pop.
@export_range(0.05, 1.0) var pop_start_scale: float = 0.36
## Quick spin at bloom time, in degrees.
@export var pop_twist_degrees: float = 8.0
## Upward kick at bloom time, in px.
@export var pop_jump_pixels: float = 6.0

const ROSE_GROWNUP_ATLAS: Vector2i = Vector2i(0, 1)
const SOURCE_ID: int = 0

var _plant_manager: Node
var _plantz: TileMapLayer
var _texture: Texture2D
var _region: Rect2
var _tile_size: Vector2
var _dancers: Dictionary = {}  # cell -> {"sway_phase": float, "breathe_phase": float, "pop_started_at": float}
var _contact_dancers: Dictionary = {}  # key -> {"layer": TileMapLayer, "cell": Vector2i, "region": Rect2, "until": float, "source_id": int, "atlas_coords": Vector2i, "alternative_tile": int}
var _time: float = 0.0


func _ready() -> void:
	_plant_manager = get_node_or_null(plant_manager_path)
	_plantz = get_node_or_null(plantz_path) as TileMapLayer
	if _plantz == null and get_parent() is TileMapLayer:
		_plantz = get_parent() as TileMapLayer
	if _plantz == null or _plantz.tile_set == null:
		push_warning("GrownupRoseDance: needs a plantz TileMapLayer; disabling.")
		set_process(false)
		return
	var src: TileSetAtlasSource = _plantz.tile_set.get_source(SOURCE_ID) as TileSetAtlasSource
	if src == null:
		push_warning("GrownupRoseDance: tileset source %d not found; disabling." % SOURCE_ID)
		set_process(false)
		return
	_texture = src.texture
	_region = Rect2(src.get_tile_texture_region(ROSE_GROWNUP_ATLAS))
	_tile_size = Vector2(_plantz.tile_set.tile_size)
	_connect_plant_manager()
	_connect_contact_source()
	_rescan()


func _connect_plant_manager() -> void:
	if _plant_manager == null:
		return
	if _plant_manager.has_signal("plant_state_changed"):
		_plant_manager.plant_state_changed.connect(_on_plant_state_changed)
	if _plant_manager.has_signal("plant_removed"):
		_plant_manager.plant_removed.connect(_on_plant_removed)


func _connect_contact_source() -> void:
	var source: Node = get_node_or_null("../../../BuildingManager")
	if source == null and get_parent() != null:
		var map_root: Node = get_parent().get_parent().get_parent() if get_parent().get_parent() != null else null
		source = map_root.get_node_or_null("BuildingManager") if map_root != null else null
	if source == null or not source.has_signal("plant_contact_dance_requested"):
		return
	var callback: Callable = Callable(self, "_on_plant_contact_dance_requested")
	if not source.is_connected("plant_contact_dance_requested", callback):
		source.connect("plant_contact_dance_requested", callback)


## Pick up any roses already in bloom (e.g. a scene loaded mid-harvest).
func _rescan() -> void:
	if _plant_manager and _plant_manager.has_method("get_grownup_rose_cells"):
		for raw_cell in _plant_manager.get_grownup_rose_cells():
			var cell: Vector2i = raw_cell as Vector2i
			if _is_visual_grownup(cell):
				_add_dancer(cell, false)


func _on_plant_state_changed(cell: Vector2i, atlas_coords: Vector2i) -> void:
	if atlas_coords == ROSE_GROWNUP_ATLAS:
		_remove_contact_dancer(_contact_key(&"plantz", cell))
		_add_dancer(cell, true)
	else:
		_remove_dancer(cell)


func _on_plant_removed(cell: Vector2i) -> void:
	_remove_dancer(cell)
	_remove_contact_dancer(_contact_key(&"plantz", cell))


func _on_plant_contact_dance_requested(layer_name: StringName, cell: Vector2i, item_id: String, duration: float) -> void:
	if layer_name == &"plantz" and item_id != "rose":
		return
	if layer_name == &"plantz" and _dancers.has(cell):
		return
	if layer_name == &"blocking_buildings" and item_id == "turret_epine":
		return
	var layer: TileMapLayer = _contact_layer(layer_name)
	if layer == null or layer.tile_set == null:
		return
	var source_id: int = layer.get_cell_source_id(cell)
	if source_id < 0:
		return
	var src: TileSetAtlasSource = layer.tile_set.get_source(source_id) as TileSetAtlasSource
	if src == null:
		return
	var atlas_coords: Vector2i = layer.get_cell_atlas_coords(cell)
	var key: String = _contact_key(layer_name, cell)
	if _contact_dancers.has(key):
		var existing: Dictionary = _contact_dancers[key] as Dictionary
		existing["until"] = maxf(float(existing.get("until", 0.0)), _time + maxf(0.0, duration))
		_contact_dancers[key] = existing
		queue_redraw()
		return
	var alternative_tile: int = layer.get_cell_alternative_tile(cell)
	_contact_dancers[key] = {
		"layer_name": layer_name,
		"layer": layer,
		"cell": cell,
		"item_id": item_id,
		"texture": src.texture,
		"region": Rect2(src.get_tile_texture_region(atlas_coords)),
		"until": _time + maxf(0.0, duration),
		"source_id": source_id,
		"atlas_coords": atlas_coords,
		"alternative_tile": alternative_tile,
		"sway_phase": randf() * TAU,
		"breathe_phase": randf() * TAU,
	}
	if layer_name == &"plantz" and _plant_manager != null and _plant_manager.has_method("set_rose_visual_hidden"):
		_plant_manager.call("set_rose_visual_hidden", cell, true)
	else:
		layer.erase_cell(cell)
		layer.update_internals()
		layer.queue_redraw()
	queue_redraw()


func _add_dancer(cell: Vector2i, play_pop: bool) -> void:
	if not _is_visual_grownup(cell) and not _is_logical_grownup(cell):
		return
	var pop_started_at: float = _time if play_pop else -1.0
	if _dancers.has(cell):
		if play_pop:
			var existing_phases: Dictionary = _dancers[cell] as Dictionary
			existing_phases["pop_started_at"] = pop_started_at
			_dancers[cell] = existing_phases
			queue_redraw()
		return
	_dancers[cell] = {
		"sway_phase": randf() * TAU,
		"breathe_phase": randf() * TAU,
		"pop_started_at": pop_started_at,
	}
	_set_source_visual_hidden(cell, true)
	queue_redraw()


func _remove_dancer(cell: Vector2i) -> void:
	if _dancers.erase(cell):
		_set_source_visual_hidden(cell, false)
		queue_redraw()


func _remove_contact_dancer(key: String) -> void:
	if not _contact_dancers.has(key):
		return
	var data: Dictionary = _contact_dancers[key] as Dictionary
	_contact_dancers.erase(key)
	var layer_name: StringName = data.get("layer_name", &"") as StringName
	var cell: Vector2i = data.get("cell", Vector2i.ZERO) as Vector2i
	if layer_name == &"plantz" and _plant_manager != null and _plant_manager.has_method("set_rose_visual_hidden"):
		_plant_manager.call("set_rose_visual_hidden", cell, false)
	else:
		var layer: TileMapLayer = data.get("layer", null) as TileMapLayer
		var item_id: String = str(data.get("item_id", ""))
		if item_id != "" and not _building_still_exists(cell, item_id):
			queue_redraw()
			return
		if layer != null and is_instance_valid(layer) and layer.get_cell_source_id(cell) < 0:
			layer.set_cell(
				cell,
				int(data.get("source_id", -1)),
				data.get("atlas_coords", Vector2i.ZERO) as Vector2i,
				int(data.get("alternative_tile", 0))
			)
			layer.update_internals()
			layer.queue_redraw()
	queue_redraw()


func _process(delta: float) -> void:
	if _dancers.is_empty() and _contact_dancers.is_empty():
		return
	_time += delta
	_expire_contact_dancers()
	queue_redraw()


func _draw() -> void:
	if _texture == null:
		return
	var half: Vector2 = _tile_size * 0.5
	var sway_rad: float = deg_to_rad(sway_degrees)
	var sway_omega: float = sway_speed * TAU
	var breathe_omega: float = breathe_speed * TAU
	# Draw the tile so its bottom-centre sits at the transform origin (the planted
	# base): sway rotates and breathe scales pivot from the base, like a stem swaying
	# in the breeze, so the copy stays anchored to the ground it grew from.
	var rect: Rect2 = Rect2(-half.x, -_tile_size.y, _tile_size.x, _tile_size.y)
	for raw_cell in _dancers.keys():
		var cell: Vector2i = raw_cell as Vector2i
		if not _is_logical_grownup(cell):
			continue
		var phases: Dictionary = _dancers[cell] as Dictionary
		var sway_phase: float = float(phases["sway_phase"])
		var breathe_phase: float = float(phases["breathe_phase"])
		var pop_started_at: float = float(phases.get("pop_started_at", -1.0))
		var base: Vector2 = _cell_center_local(cell) + Vector2(0.0, half.y)
		var angle: float = sway_rad * sin(_time * sway_omega + sway_phase)
		var sy: float = 1.0 + breathe_amount * sin(_time * breathe_omega + breathe_phase)
		var sx: float = (1.0 / sy) if preserve_volume else 1.0
		var bob: float = -bob_pixels * absf(sin(_time * breathe_omega * 0.5 + sway_phase))
		var pop_scale: Vector2 = Vector2.ONE
		var pop_angle: float = 0.0
		var pop_jump: float = 0.0
		if pop_started_at >= 0.0 and pop_duration > 0.0:
			var pop_t: float = clampf((_time - pop_started_at) / pop_duration, 0.0, 1.0)
			var pop_out: float = 1.0 - pow(1.0 - pop_t, 3.0)
			var pop_ring: float = sin(pop_t * PI)
			var scale_value: float = lerpf(pop_start_scale, 1.0, pop_out) + (pop_ring * pop_overshoot)
			var squash_value: float = 1.0 - (pop_ring * 0.18)
			pop_scale = Vector2(scale_value / squash_value, scale_value * squash_value)
			pop_angle = deg_to_rad(pop_twist_degrees) * (1.0 - pop_out) * sin(pop_t * TAU)
			pop_jump = -pop_jump_pixels * pop_ring
		draw_set_transform(base + Vector2(0.0, bob + pop_jump), angle + pop_angle, Vector2(sx, sy) * pop_scale)
		draw_texture_rect_region(_texture, rect, _region)
	for raw_key: Variant in _contact_dancers.keys():
		var data: Dictionary = _contact_dancers[str(raw_key)] as Dictionary
		var layer: TileMapLayer = data.get("layer", null) as TileMapLayer
		if layer == null or not is_instance_valid(layer):
			continue
		var texture: Texture2D = data.get("texture", null) as Texture2D
		if texture == null:
			continue
		var cell: Vector2i = data.get("cell", Vector2i.ZERO) as Vector2i
		var contact_region: Rect2 = data.get("region", Rect2()) as Rect2
		var sway_phase_contact: float = float(data.get("sway_phase", 0.0))
		var breathe_phase_contact: float = float(data.get("breathe_phase", 0.0))
		var base_contact: Vector2 = _cell_center_local_for_layer(layer, cell) + Vector2(0.0, half.y)
		var angle_contact: float = sway_rad * sin(_time * sway_omega + sway_phase_contact)
		var sy_contact: float = 1.0 + breathe_amount * sin(_time * breathe_omega + breathe_phase_contact)
		var sx_contact: float = (1.0 / sy_contact) if preserve_volume else 1.0
		var bob_contact: float = -bob_pixels * absf(sin(_time * breathe_omega * 0.5 + sway_phase_contact))
		draw_set_transform(base_contact + Vector2(0.0, bob_contact), angle_contact, Vector2(sx_contact, sy_contact))
		draw_texture_rect_region(texture, rect, contact_region)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _expire_contact_dancers() -> void:
	var expired: Array[String] = []
	for raw_key: Variant in _contact_dancers.keys():
		var key: String = str(raw_key)
		var data: Dictionary = _contact_dancers[key] as Dictionary
		if _time >= float(data.get("until", 0.0)):
			expired.append(key)
	for key: String in expired:
		_remove_contact_dancer(key)


func _is_visual_grownup(cell: Vector2i) -> bool:
	if _plantz == null:
		return false
	return _plantz.get_cell_atlas_coords(cell) == ROSE_GROWNUP_ATLAS


func _is_logical_grownup(cell: Vector2i) -> bool:
	if _plant_manager == null or not _plant_manager.has_method("is_rose_grownup"):
		return false
	return bool(_plant_manager.call("is_rose_grownup", cell))


func _set_source_visual_hidden(cell: Vector2i, is_hidden: bool) -> void:
	if _plant_manager == null or not _plant_manager.has_method("set_rose_visual_hidden"):
		return
	_plant_manager.call("set_rose_visual_hidden", cell, is_hidden)


func _cell_center_local(cell: Vector2i) -> Vector2:
	return _cell_center_local_for_layer(_plantz, cell)


func _cell_center_local_for_layer(layer: TileMapLayer, cell: Vector2i) -> Vector2:
	if layer == null:
		return Vector2.ZERO
	var center_map: Vector2 = _plantz.map_to_local(cell)
	if layer != _plantz:
		center_map = layer.map_to_local(cell)
	if get_parent() == layer:
		return center_map
	return to_local(layer.to_global(center_map))


func _contact_layer(layer_name: StringName) -> TileMapLayer:
	if layer_name == &"plantz":
		return _plantz
	var map_root: Node = _plantz.get_parent() if _plantz != null else null
	if map_root == null:
		return null
	return map_root.get_node_or_null(String(layer_name)) as TileMapLayer


func _contact_key(layer_name: StringName, cell: Vector2i) -> String:
	return "%s:%d:%d" % [String(layer_name), cell.x, cell.y]


func _building_still_exists(cell: Vector2i, item_id: String) -> bool:
	var manager: Node = get_node_or_null("../../../BuildingObjectManager")
	if manager == null or not manager.has_method("get_building"):
		return true
	var data: Dictionary = manager.call("get_building", cell) as Dictionary
	return str(data.get("item_id", "")) == item_id
