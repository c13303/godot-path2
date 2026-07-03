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
	_rescan()


func _connect_plant_manager() -> void:
	if _plant_manager == null:
		return
	if _plant_manager.has_signal("plant_state_changed"):
		_plant_manager.plant_state_changed.connect(_on_plant_state_changed)
	if _plant_manager.has_signal("plant_removed"):
		_plant_manager.plant_removed.connect(_on_plant_removed)


## Pick up any roses already in bloom (e.g. a scene loaded mid-harvest).
func _rescan() -> void:
	if _plant_manager and _plant_manager.has_method("get_grownup_rose_cells"):
		for raw_cell in _plant_manager.get_grownup_rose_cells():
			var cell: Vector2i = raw_cell as Vector2i
			if _is_visual_grownup(cell):
				_add_dancer(cell, false)


func _on_plant_state_changed(cell: Vector2i, atlas_coords: Vector2i) -> void:
	if atlas_coords == ROSE_GROWNUP_ATLAS:
		_add_dancer(cell, true)
	else:
		_remove_dancer(cell)


func _on_plant_removed(cell: Vector2i) -> void:
	_remove_dancer(cell)


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


func _process(delta: float) -> void:
	if _dancers.is_empty():
		return
	_time += delta
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
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


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
	var center_map: Vector2 = _plantz.map_to_local(cell)
	if get_parent() == _plantz:
		return center_map
	return to_local(_plantz.to_global(center_map))
