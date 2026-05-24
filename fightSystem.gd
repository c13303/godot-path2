extends Node
class_name FightSystem

@export var visualize_AOE_weapons: bool = true
@export var weapons: Array[WeaponData] = [
	preload("res://weapons/bomb.tres"),
	preload("res://weapons/sword.tres"),
]

var _steering: Node
var _drawer
var _weapons_by_id: Dictionary = {}

func _ready() -> void:
	_steering = get_node_or_null("../CPP/SteeringSystemNative")
	_drawer = WeaponAOEDrawer.new()
	add_child(_drawer)
	_rebuild_weapon_index()

func use_weapon(weapon_id: String, origin: Vector2, direction: Vector2, source_agent_id: int = -1) -> bool:
	var weapon: WeaponData = _weapon_by_id(weapon_id)
	if not weapon:
		return false
	var radius: float = weapon.radius
	var angle: float = weapon.directional_area_angle
	var duration: float = weapon.aoe_duration
	if radius <= 0.0 or duration <= 0.0:
		return false

	var facing: Vector2 = direction.normalized() if direction.length_squared() > 0.000001 else Vector2.RIGHT
	if visualize_AOE_weapons:
		_drawer.show_weapon_area(origin, facing, radius, angle, duration)

	if not _steering:
		return true

	if not _steering.has_method("spawn_aoe_zone"):
		return false

	_steering.call(
		"spawn_aoe_zone",
		origin,
		facing,
		radius,
		angle,
		duration,
		weapon.smash_force,
		weapon.friction,
		weapon.falloff,
		weapon.detach_flow,
		weapon.control_suppression,
		weapon.control_suppression_duration,
		source_agent_id,
		weapon.affected_smash_classes
	)
	return true

func _rebuild_weapon_index() -> void:
	_weapons_by_id.clear()
	for weapon in weapons:
		if weapon and weapon.id != "":
			_weapons_by_id[weapon.id] = weapon

func _weapon_by_id(weapon_id: String) -> WeaponData:
	if _weapons_by_id.is_empty():
		_rebuild_weapon_index()
	return _weapons_by_id.get(weapon_id) as WeaponData

class WeaponAOEDrawer:
	extends Node2D

	var _areas: Array[Dictionary] = []
	var _fill := Color(1.0, 0.0, 0.0, 0.18)
	var _stroke := Color(1.0, 0.0, 0.0, 0.85)

	func show_weapon_area(origin: Vector2, direction: Vector2, radius: float, angle_degrees: float, duration: float) -> void:
		if duration <= 0.0:
			return
		_areas.append({
			"origin": origin,
			"direction": direction.normalized() if direction.length_squared() > 0.000001 else Vector2.RIGHT,
			"radius": radius,
			"angle": angle_degrees,
			"time_left": duration,
		})
		queue_redraw()

	func _process(delta: float) -> void:
		var changed := false
		for i in range(_areas.size() - 1, -1, -1):
			_areas[i]["time_left"] = float(_areas[i]["time_left"]) - delta
			if float(_areas[i]["time_left"]) <= 0.0:
				_areas.remove_at(i)
				changed = true
		if changed or not _areas.is_empty():
			queue_redraw()

	func _draw() -> void:
		for area in _areas:
			var origin: Vector2 = area["origin"]
			var radius: float = float(area["radius"])
			var angle: float = float(area["angle"])
			var direction: Vector2 = area["direction"]
			if angle >= 359.9:
				draw_circle(origin, radius, _fill)
				draw_arc(origin, radius, 0.0, TAU, 64, _stroke, 2.0)
			else:
				_draw_cone(origin, direction, radius, angle)

	func _draw_cone(origin: Vector2, direction: Vector2, radius: float, angle_degrees: float) -> void:
		var points: PackedVector2Array = PackedVector2Array()
		points.append(origin)
		var base_angle: float = direction.angle()
		var half_angle: float = deg_to_rad(angle_degrees * 0.5)
		var steps: int = max(6, int(ceil(angle_degrees / 8.0)))
		for i in range(steps + 1):
			var t: float = float(i) / float(steps)
			var a: float = base_angle - half_angle + half_angle * 2.0 * t
			points.append(origin + Vector2(cos(a), sin(a)) * radius)
		draw_colored_polygon(points, _fill)
		for i in range(points.size()):
			draw_line(points[i], points[(i + 1) % points.size()], _stroke, 2.0)
