extends Node

var _spray: WeaponData = preload("res://scripts/combat/weapons/spray.tres")
var _water: GunData = preload("res://scripts/combat/weapons/water.tres")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	if key_event.keycode == KEY_F3:
		_apply_hardcore_preset()
		get_viewport().set_input_as_handled()
	elif key_event.keycode == KEY_F2:
		_apply_easy_preset()
		get_viewport().set_input_as_handled()


func _apply_hardcore_preset() -> void:
	# Keep these values explicit so F3 always restores the intended baseline,
	# even after another preset changes the shared weapon resource at runtime.
	_spray.throw_offset = 16.0
	_spray.directional_area_angle = 86.0
	_spray.smash_force = 400.0
	_spray.control_suppression = 0.35
	_spray.control_suppression_duration = 0.15
	_spray.friction = 0.91
	_spray.falloff = 0.0
	_spray.detach_flow = false
	_spray.affected_smash_classes = 4
	_spray.spray_projectiles_enabled = true
	_spray.spray_reserve_id = &"water"
	_spray.spray_reserve_cost = 1
	_spray.spray_reserve_cost_interval = 0.5
	_spray.spray_projectiles_per_second = 28.0
	_spray.spray_aim_inertia = 0.05
	_spray.spray_projectile_speed = 760.0
	_spray.spray_projectile_lifetime = 0.27
	_spray.spray_projectile_radius = 5.25
	_spray.spray_projectile_damage = 4
	_spray.spray_projectile_spread_jitter_degrees = 3.0
	_spray.spray_projectile_static_collision_mask = 1
	_spray.spray_projectile_pool_size = 128
	_spray.spray_waters_reactive_plants = true
	_spray.spray_visual_radius = 13.0
	_spray.spray_visual_projectiles_grow = true
	_spray.spray_visual_min_size = 1.0
	_spray.spray_visual_threshold = 0.75
	_spray.spray_visual_softness = 0.0
	print("Difficulty changed: hardcore (F3)")


func _apply_easy_preset() -> void:
	_water.damage = 50
	print("Difficulty changed: easy (F2)")
