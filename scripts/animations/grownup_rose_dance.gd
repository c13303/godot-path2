extends Node2D
class_name GrownupRoseDance

## Gentle "ready to harvest" animation for full-bloom roses. Grownup rose tiles are
## represented by one Sprite2D copy per rose, with a subtle base-anchored sway plus
## a breathing squash/stretch, so each ready rose slightly balances and dances.
## Each rose is desynced by a random phase so the garden doesn't pulse in unison.
##
## Roses are TileMapLayer cells and so can't carry a per-tile transform. This node
## asks PlantManager to hide only the source visual for animated roses, while the
## logical plant state and tile metadata remain owned by PlantManager.

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
var _dancers: Dictionary = {}  # cell -> {"sprite": Sprite2D, "sway_phase": float, "breathe_phase": float, "pop_started_at": float}
var _contact_dancers: Dictionary = {}  # key -> {"sprite": Sprite2D, "layer": TileMapLayer, "cell": Vector2i, "until": float, "source_id": int, "atlas_coords": Vector2i, "alternative_tile": int}
var _damage_flash_tweens: Dictionary = {}  # key -> Tween
var _damage_flash_original_modulates: Dictionary = {}  # key -> Color
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
		_update_contact_dancer_visual(key)
		return
	var alternative_tile: int = layer.get_cell_alternative_tile(cell)
	var region: Rect2 = Rect2(src.get_tile_texture_region(atlas_coords))
	_contact_dancers[key] = {
		"sprite": _create_region_sprite(src.texture, region, "Contact_%s" % key),
		"layer_name": layer_name,
		"layer": layer,
		"cell": cell,
		"item_id": item_id,
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
	_update_contact_dancer_visual(key)


func play_damage_flash_at(layer_name: StringName, cell: Vector2i, item_id: String, duration: float) -> bool:
	if layer_name == &"plantz" and item_id == "rose" and _dancers.has(cell):
		var dancer_data: Dictionary = _dancers[cell] as Dictionary
		var dancer_sprite: Sprite2D = dancer_data.get("sprite", null) as Sprite2D
		return _flash_sprite(_flash_key(layer_name, cell), dancer_sprite, duration)
	var key: String = _contact_key(layer_name, cell)
	if not _contact_dancers.has(key):
		_on_plant_contact_dance_requested(layer_name, cell, item_id, duration)
	elif _contact_dancers.has(key):
		var existing: Dictionary = _contact_dancers[key] as Dictionary
		existing["until"] = maxf(float(existing.get("until", 0.0)), _time + maxf(0.0, duration))
		_contact_dancers[key] = existing
	if not _contact_dancers.has(key):
		return false
	var data: Dictionary = _contact_dancers[key] as Dictionary
	var sprite: Sprite2D = data.get("sprite", null) as Sprite2D
	return _flash_sprite(_flash_key(layer_name, cell), sprite, duration)


func _add_dancer(cell: Vector2i, play_pop: bool) -> void:
	if not _is_visual_grownup(cell) and not _is_logical_grownup(cell):
		return
	var pop_started_at: float = _time if play_pop else -1.0
	if _dancers.has(cell):
		if play_pop:
			var existing_phases: Dictionary = _dancers[cell] as Dictionary
			existing_phases["pop_started_at"] = pop_started_at
			_dancers[cell] = existing_phases
			_update_dancer_visual(cell)
		return
	_dancers[cell] = {
		"sprite": _create_region_sprite(_texture, _region, "Rose_%d_%d" % [cell.x, cell.y]),
		"sway_phase": randf() * TAU,
		"breathe_phase": randf() * TAU,
		"pop_started_at": pop_started_at,
	}
	_set_source_visual_hidden(cell, true)
	_update_dancer_visual(cell)


func _remove_dancer(cell: Vector2i) -> void:
	if not _dancers.has(cell):
		return
	var data: Dictionary = _dancers[cell] as Dictionary
	_dancers.erase(cell)
	var sprite: Sprite2D = data.get("sprite", null) as Sprite2D
	if is_instance_valid(sprite):
		sprite.queue_free()
	_clear_damage_flash(_flash_key(&"plantz", cell))
	_set_source_visual_hidden(cell, false)


func _remove_contact_dancer(key: String) -> void:
	if not _contact_dancers.has(key):
		return
	var data: Dictionary = _contact_dancers[key] as Dictionary
	_contact_dancers.erase(key)
	var sprite: Sprite2D = data.get("sprite", null) as Sprite2D
	if is_instance_valid(sprite):
		sprite.queue_free()
	var layer_name: StringName = StringName(data.get("layer_name", &""))
	var cell: Vector2i = data.get("cell", Vector2i.ZERO) as Vector2i
	_clear_damage_flash(_flash_key(layer_name, cell))
	if layer_name == &"plantz" and _plant_manager != null and _plant_manager.has_method("set_rose_visual_hidden"):
		_plant_manager.call("set_rose_visual_hidden", cell, false)
	else:
		var layer: TileMapLayer = data.get("layer", null) as TileMapLayer
		var item_id: String = str(data.get("item_id", ""))
		if item_id != "" and not _building_still_exists(cell, item_id):
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


func _process(delta: float) -> void:
	if _dancers.is_empty() and _contact_dancers.is_empty():
		return
	_time += delta
	_expire_contact_dancers()
	_update_dancer_visuals()
	_update_contact_dancer_visuals()


func _create_region_sprite(texture: Texture2D, region: Rect2, node_name: String) -> Sprite2D:
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = region
	var sprite: Sprite2D = Sprite2D.new()
	sprite.name = node_name.replace(":", "_")
	sprite.texture = atlas
	sprite.centered = false
	var half: Vector2 = _tile_size * 0.5
	sprite.offset = Vector2(-half.x, -_tile_size.y)
	add_child(sprite)
	return sprite


func _update_dancer_visuals() -> void:
	for raw_cell: Variant in _dancers.keys():
		_update_dancer_visual(raw_cell as Vector2i)


func _update_dancer_visual(cell: Vector2i) -> void:
	if not _dancers.has(cell):
		return
	if not _is_logical_grownup(cell):
		return
	var data: Dictionary = _dancers[cell] as Dictionary
	var sprite: Sprite2D = data.get("sprite", null) as Sprite2D
	if sprite == null or not is_instance_valid(sprite):
		return
	var sway_phase: float = float(data.get("sway_phase", 0.0))
	var breathe_phase: float = float(data.get("breathe_phase", 0.0))
	var pop_started_at: float = float(data.get("pop_started_at", -1.0))
	_apply_dance_transform(sprite, _plantz, cell, sway_phase, breathe_phase, pop_started_at)


func _update_contact_dancer_visuals() -> void:
	for raw_key: Variant in _contact_dancers.keys():
		_update_contact_dancer_visual(str(raw_key))


func _update_contact_dancer_visual(key: String) -> void:
	if not _contact_dancers.has(key):
		return
	var data: Dictionary = _contact_dancers[key] as Dictionary
	var sprite: Sprite2D = data.get("sprite", null) as Sprite2D
	var layer: TileMapLayer = data.get("layer", null) as TileMapLayer
	if sprite == null or not is_instance_valid(sprite) or layer == null or not is_instance_valid(layer):
		return
	var cell: Vector2i = data.get("cell", Vector2i.ZERO) as Vector2i
	var sway_phase: float = float(data.get("sway_phase", 0.0))
	var breathe_phase: float = float(data.get("breathe_phase", 0.0))
	_apply_dance_transform(sprite, layer, cell, sway_phase, breathe_phase, -1.0)


func _apply_dance_transform(
	sprite: Sprite2D,
	layer: TileMapLayer,
	cell: Vector2i,
	sway_phase: float,
	breathe_phase: float,
	pop_started_at: float
) -> void:
	if layer == null:
		return
	var half: Vector2 = _tile_size * 0.5
	var cell_center_world: Vector2 = WorldDepthSort.cell_center_world(layer, cell)
	var base_world: Vector2 = cell_center_world + Vector2(0.0, half.y)
	var sway_rad: float = deg_to_rad(sway_degrees)
	var sway_omega: float = sway_speed * TAU
	var breathe_omega: float = breathe_speed * TAU
	var angle: float = sway_rad * sin(_time * sway_omega + sway_phase)
	var scale_y: float = 1.0 + breathe_amount * sin(_time * breathe_omega + breathe_phase)
	var scale_x: float = (1.0 / scale_y) if preserve_volume else 1.0
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
	sprite.global_position = base_world + Vector2(0.0, bob + pop_jump)
	sprite.rotation = angle + pop_angle
	sprite.scale = Vector2(scale_x, scale_y) * pop_scale
	WorldDepthSort.apply_world_depth(sprite, cell_center_world)


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


func _flash_sprite(key: String, sprite: Sprite2D, duration: float) -> bool:
	if sprite == null or not is_instance_valid(sprite):
		return false
	_kill_damage_flash_tween(key)
	if not _damage_flash_original_modulates.has(key):
		_damage_flash_original_modulates[key] = sprite.modulate
	var original: Color = _damage_flash_original_modulates[key] as Color
	sprite.modulate = Color(1.0, 0.12, 0.12, original.a)
	var tween: Tween = create_tween()
	_damage_flash_tweens[key] = tween
	tween.tween_property(sprite, "modulate", original, maxf(0.0, duration)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.finished.connect(Callable(self, "_on_damage_flash_finished").bind(key, sprite))
	return true


func _on_damage_flash_finished(key: String, sprite: Sprite2D) -> void:
	_damage_flash_tweens.erase(key)
	if _damage_flash_original_modulates.has(key) and is_instance_valid(sprite):
		sprite.modulate = _damage_flash_original_modulates[key] as Color
	_damage_flash_original_modulates.erase(key)


func _clear_damage_flash(key: String) -> void:
	_kill_damage_flash_tween(key)
	_damage_flash_original_modulates.erase(key)


func _kill_damage_flash_tween(key: String) -> void:
	var tween: Tween = _damage_flash_tweens.get(key, null) as Tween
	_damage_flash_tweens.erase(key)
	if tween != null and tween.is_valid():
		tween.kill()


func _flash_key(layer_name: StringName, cell: Vector2i) -> String:
	return "flash:%s:%d:%d" % [String(layer_name), cell.x, cell.y]
