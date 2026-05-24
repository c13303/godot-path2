extends Node
class_name FightSystem

@export var visualize_AOE_weapons: bool = true
@export var weapons: Array[WeaponData] = [
	preload("res://weapons/bomb.tres"),
	preload("res://weapons/sword.tres"),
]
@export var guns: Array[GunData] = [
	preload("res://weapons/water.tres"),
]

var _steering: Node
var _projectiles: Node
var _drawer
var _projectile_drawer
var _weapons_by_id: Dictionary = {}
var _guns_by_id: Dictionary = {}
var _gun_type_ids: Dictionary = {}
var _gun_fire_timers: Dictionary = {}

func _ready() -> void:
	_steering = get_node_or_null("../CPP/SteeringSystemNative")
	_projectiles = get_node_or_null("../CPP/ProjectileSystemNative")
	_drawer = WeaponAOEDrawer.new()
	add_child(_drawer)
	_rebuild_weapon_index()
	_register_guns()
	if _projectiles:
		_projectile_drawer = ProjectileDrawer.new()
		_projectile_drawer.setup(_projectiles, _guns_by_id, _gun_type_ids)
		add_child(_projectile_drawer)

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

func is_gun(item_id: String) -> bool:
	return _guns_by_id.has(item_id)

func _register_guns() -> void:
	_guns_by_id.clear()
	_gun_type_ids.clear()
	if not _projectiles:
		return
	for gun in guns:
		if not gun or gun.id == "":
			continue
		_guns_by_id[gun.id] = gun
		var cfg: Dictionary = {
			"speed": gun.projectile_speed,
			"lifetime": gun.projectile_lifetime,
			"radius": gun.projectile_size * 0.5,
			"aoe_radius": gun.aoe_radius,
			"smash_force": gun.smash_force,
			"smash_friction_loss": gun.smash_friction_loss,
			"smash_falloff": gun.smash_falloff,
			"smash_detach_flow": gun.smash_detach_flow,
			"smash_control_suppression": gun.smash_control_suppression,
			"smash_control_suppression_duration": gun.smash_control_suppression_duration,
			"pool_size": gun.pool_size,
		}
		var type_id: int = int(_projectiles.call("register_type", cfg))
		_gun_type_ids[gun.id] = type_id
		_gun_fire_timers[gun.id] = 0.0

func fire_gun_held(gun_id: String, origin: Vector2, direction: Vector2, source_agent_id: int, delta: float) -> void:
	var gun: GunData = _guns_by_id.get(gun_id) as GunData
	if not gun or not _projectiles:
		return
	var t: float = float(_gun_fire_timers.get(gun_id, 0.0))
	t -= delta
	if t <= 0.0:
		var type_id: int = int(_gun_type_ids.get(gun_id, -1))
		if type_id >= 0:
			_projectiles.call("fire", type_id, origin, direction, source_agent_id, gun.affected_smash_classes)
		t = max(0.0, gun.fire_delay_ms * 0.001)
	_gun_fire_timers[gun_id] = t

func reset_gun_cooldown(gun_id: String) -> void:
	if _gun_fire_timers.has(gun_id):
		_gun_fire_timers[gun_id] = 0.0

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

class ProjectileDrawer:
	extends Node2D

	var _projectile_system: Node
	var _guns_by_id: Dictionary = {}
	var _gun_type_ids: Dictionary = {}
	var _textures_by_type: Dictionary = {}
	var _half_size_by_type: Dictionary = {}

	func setup(projectile_system: Node, guns_by_id: Dictionary, gun_type_ids: Dictionary) -> void:
		_projectile_system = projectile_system
		_guns_by_id = guns_by_id
		_gun_type_ids = gun_type_ids
		for gun_id in _gun_type_ids.keys():
			var gun: GunData = _guns_by_id[gun_id] as GunData
			var tid: int = int(_gun_type_ids[gun_id])
			if gun and gun.projectile_sprite:
				_textures_by_type[tid] = gun.projectile_sprite
				_half_size_by_type[tid] = gun.projectile_size * 0.5

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		if not _projectile_system:
			return
		for tid_key in _textures_by_type.keys():
			var tid: int = int(tid_key)
			var tex: Texture2D = _textures_by_type[tid] as Texture2D
			if not tex:
				continue
			var half: float = float(_half_size_by_type[tid])
			var positions: PackedVector2Array = _projectile_system.call("get_active_positions", tid)
			var size: Vector2 = Vector2(half * 2.0, half * 2.0)
			var offset: Vector2 = Vector2(-half, -half)
			for p in positions:
				draw_texture_rect(tex, Rect2(p + offset, size), false)
