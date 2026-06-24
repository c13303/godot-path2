extends Node

var _spray: WeaponData = preload("res://scripts/combat/weapons/spray.tres")
var _water: GunData = preload("res://scripts/combat/weapons/water.tres")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	if key_event.keycode == KEY_F1:
		_apply_hardcore_preset()
		get_viewport().set_input_as_handled()
	elif key_event.keycode == KEY_F2:
		_apply_easy_preset()
		get_viewport().set_input_as_handled()


func _apply_hardcore_preset() -> void:
	# Keep these values explicit so F1 always restores the intended baseline,
	# even after another preset changes the shared weapon resource at runtime.
	_spray.throw_offset = 16.0
	_spray.directional_area_angle = 86.0
	_spray.radius = 108.0
	_spray.aoe_duration = 0.0
	_spray.smash_force = 400.0
	_spray.control_suppression = 0.35
	_spray.control_suppression_duration = 0.15
	_spray.damage = 30
	_spray.friction = 0.91
	_spray.falloff = 0.0
	_spray.radial = false
	_spray.detach_flow = false
	_spray.affected_smash_classes = 4
	_spray.continuous = true
	_spray.damage_frequency = 0.1
	_spray.repulse_frequency = 0.03
	_spray.reserve_id = &"water"
	_spray.reserve_cost = 1
	_spray.reserve_cost_interval = 0.5
	_spray.waters_reactive_plants = true
	_spray.continuous_sound = &""
	_spray.aoe_visual_enabled = false
	_spray.aoe_fill_color = Color(0.12, 0.48, 1.0, 0.22)
	_spray.aoe_stroke_color = Color(0.35, 0.72, 1.0, 0.95)
	_spray.aoe_stroke_width = 2.0
	print("Difficulty changed: hardcore (F1)")


func _apply_easy_preset() -> void:
	_water.damage = 50
	print("Difficulty changed: easy (F2)")
