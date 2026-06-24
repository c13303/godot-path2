extends Node2D
class_name TurretSystem

const TURRET_ID: String = "turret1"
const TURRET_SHOW_RADIUS: bool = true
const RADIUS_COLOR: Color = Color(0.55, 0.55, 0.55, 0.8)
const RADIUS_LINE_WIDTH: float = 1.0
const RADIUS_SEGMENTS: int = 96

var _fight_system: FightSystem
var _building_objects: BuildingObjectManager
var _turrets: Dictionary = {}
var _has_hovered_turret: bool = false
var _hovered_turret_cell: Vector2i = Vector2i.ZERO

func _ready() -> void:
	_fight_system = get_parent() as FightSystem
	_building_objects = get_node_or_null("../../Map/BuildingObjectManager") as BuildingObjectManager
	if _fight_system == null or _building_objects == null:
		push_error("TurretSystem: FightSystem or BuildingObjectManager is missing.")
		set_process(false)
		return
	z_as_relative = false
	z_index = 4095
	_building_objects.building_added.connect(_on_building_added)
	_building_objects.building_removed.connect(_on_building_removed)
	for cell: Vector2i in _building_objects.get_building_cells():
		var building: Dictionary = _building_objects.get_building(cell)
		if str(building.get("item_id", "")) == TURRET_ID:
			_register_turret(cell)
	if TURRET_SHOW_RADIUS:
		queue_redraw()

func _process(delta: float) -> void:
	_update_hovered_turret()
	for raw_cell: Variant in _turrets.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var state: Dictionary = _turrets[cell] as Dictionary
		var shoot_frequency: float = float(state.get("shoot_frequency", 3.0))
		var elapsed: float = float(state.get("elapsed", 0.0)) + delta
		if elapsed < shoot_frequency:
			state["elapsed"] = elapsed
			continue
		var origin: Vector2 = _turret_world_position(cell)
		var activation_range: float = float(state.get("range", 0.0))
		var target: Node2D = _nearest_enemy_in_range(origin, activation_range)
		if target == null:
			state["elapsed"] = shoot_frequency
			continue
		var weapon_id: String = str(state.get("weapon", ""))
		var direction: Vector2 = target.global_position - origin
		if _fight_system.fire_gun_once(weapon_id, origin, direction):
			state["elapsed"] = 0.0

func _draw() -> void:
	if not TURRET_SHOW_RADIUS or not _has_hovered_turret:
		return
	var state: Dictionary = _turrets.get(_hovered_turret_cell, {}) as Dictionary
	var activation_range: float = float(state.get("range", 0.0))
	if activation_range > 0.0:
		draw_arc(to_local(_turret_world_position(_hovered_turret_cell)), activation_range, 0.0, TAU, RADIUS_SEGMENTS, RADIUS_COLOR, RADIUS_LINE_WIDTH, true)

func _on_building_added(cell: Vector2i, item_id: String) -> void:
	if item_id == TURRET_ID:
		_register_turret(cell)

func _on_building_removed(cell: Vector2i, item_id: String) -> void:
	if item_id != TURRET_ID:
		return
	_turrets.erase(cell)
	if _has_hovered_turret and _hovered_turret_cell == cell:
		_has_hovered_turret = false
	if TURRET_SHOW_RADIUS:
		queue_redraw()

func _register_turret(cell: Vector2i) -> void:
	var turret_def: Dictionary = ItemCatalog.get_item_def(TURRET_ID)
	var shoot_frequency: float = maxf(0.001, float(turret_def.get("shoot_frequency", 3.0)))
	_turrets[cell] = {
		"elapsed": shoot_frequency,
		"shoot_frequency": shoot_frequency,
		"weapon": str(turret_def.get("weapon", "water")),
		"range": float(turret_def.get("range", 382.0)),
	}
	if TURRET_SHOW_RADIUS:
		queue_redraw()

func _update_hovered_turret() -> void:
	if not TURRET_SHOW_RADIUS:
		return
	var layer: TileMapLayer = _building_objects.blocking_buildings
	if layer == null:
		return
	var mouse_world_position: Vector2 = get_global_mouse_position()
	var mouse_cell: Vector2i = layer.local_to_map(layer.to_local(mouse_world_position))
	var has_hovered_turret: bool = _turrets.has(mouse_cell)
	if has_hovered_turret == _has_hovered_turret and (not has_hovered_turret or mouse_cell == _hovered_turret_cell):
		return
	_has_hovered_turret = has_hovered_turret
	_hovered_turret_cell = mouse_cell
	queue_redraw()

func _nearest_enemy_in_range(origin: Vector2, activation_range: float) -> Node2D:
	var nearest: Node2D = null
	var nearest_distance_squared: float = activation_range * activation_range
	for raw_enemy: Node in get_tree().get_nodes_in_group(&"monsters"):
		var enemy: Node2D = raw_enemy as Node2D
		if enemy == null or not is_instance_valid(enemy):
			continue
		var distance_squared: float = origin.distance_squared_to(enemy.global_position)
		if distance_squared <= nearest_distance_squared:
			nearest = enemy
			nearest_distance_squared = distance_squared
	return nearest

func _turret_world_position(cell: Vector2i) -> Vector2:
	var layer: TileMapLayer = _building_objects.blocking_buildings
	return layer.to_global(layer.map_to_local(cell))
