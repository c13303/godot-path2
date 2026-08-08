extends SceneTree

const AgentRegistryScript: Script = preload("res://scripts/native/agent_handle_registry.gd")
const CrowdRuntimeScript: Script = preload("res://scripts/native/crowd_runtime.gd")
const ProjectileRuntimeScript: Script = preload("res://scripts/native/projectile_runtime.gd")


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var harness: Node = Node.new()
	harness.name = "CPP"

	var crowd: Node = ClassDB.instantiate(&"CrowdWorld2D") as Node
	crowd.name = "CrowdWorld"
	harness.add_child(crowd)

	var crowd_runtime: Node = CrowdRuntimeScript.new() as Node
	crowd_runtime.name = "CrowdRuntime"
	harness.add_child(crowd_runtime)

	var registry: Node = AgentRegistryScript.new() as Node
	registry.name = "AgentRegistry"
	harness.add_child(registry)

	var projectile_world: Node = ClassDB.instantiate(&"ProjectileWorld2D") as Node
	projectile_world.name = "ProjectileWorld"
	harness.add_child(projectile_world)

	var projectile_runtime: Node = ProjectileRuntimeScript.new() as Node
	projectile_runtime.name = "ProjectileRuntime"
	harness.add_child(projectile_runtime)

	root.add_child(harness)
	await process_frame

	var target: Node2D = Node2D.new()
	target.add_to_group(&"monsters")
	target.global_position = Vector2(100.0, 0.0)
	harness.add_child(target)
	var target_handle: int = int(registry.call(&"spawn_agent", target, 0))
	_assert(target_handle != 0, "agent registration")
	crowd_runtime.call(&"set_agent_profile", target_handle, {
		"max_speed": 30.0,
		"terrain_speed_channel": 5,
		"foot_offset_y": -7.0,
		"contact_push_power": 12.0,
	})
	crowd_runtime.call(&"set_agent_profile", target_handle, {"max_speed": 40.0})
	var updated_profile: Dictionary = crowd.call(
		&"get_agent_diagnostics", target_handle
	) as Dictionary
	_assert(
		is_equal_approx(float(updated_profile.get("maximum_speed", 0.0)), 40.0),
		"partial profile speed update"
	)
	_assert(
		int(updated_profile.get("terrain_speed_channel", -1)) == 5,
		"partial profile preserves terrain channel"
	)
	var collision_offset: Vector2 = updated_profile.get(
		"collision_offset", Vector2.ZERO
	) as Vector2
	_assert(
		is_equal_approx(collision_offset.y, -7.0),
		"partial profile preserves collision offset"
	)
	_assert(
		is_equal_approx(float(updated_profile.get("contact_push_strength", 0.0)), 12.0),
		"partial profile preserves contact settings"
	)

	var start: Vector2 = target.global_position
	crowd_runtime.call(&"set_agent_input", target_handle, Vector2.RIGHT)
	for _index: int in range(4):
		await physics_frame
	_assert(target.global_position.x > start.x, "manual crowd movement")

	crowd_runtime.call(
		&"spawn_aoe_zone", target.global_position, Vector2.RIGHT,
		32.0, 360.0, 0.2, 20.0, 0.5, 0.0, false,
		1.0, 0.1, 0, 4, Vector2.ZERO, 3
	)
	for _index: int in range(3):
		await physics_frame
		await process_frame
	var damage_events: Array = crowd_runtime.call(&"take_damage_events") as Array
	_assert(not damage_events.is_empty(), "generic effect event to project damage payload")

	crowd_runtime.call(&"set_agent_position", target_handle, Vector2(100.0, 0.0), true)
	crowd_runtime.call(&"set_agent_input", target_handle, Vector2.ZERO)
	var type_handle: int = int(projectile_runtime.call(&"register_type", {
		"speed": 1000.0,
		"lifetime": 1.0,
		"radius": 4.0,
		"aoe_radius": 16.0,
		"damage": 2,
		"direct_hit_only": true,
		"static_collision_mask": 0,
		"target_category_mask": 4,
		"pool_size": 4,
	}))
	_assert(type_handle != 0, "projectile type registration")
	_assert(bool(projectile_runtime.call(&"fire", type_handle, Vector2.ZERO, Vector2.RIGHT, 0, 4)), "projectile spawn")
	for _index: int in range(12):
		await physics_frame
		await process_frame
	var impacts: Array = projectile_runtime.call(&"get_impacts") as Array
	_assert(not impacts.is_empty(), "projectile impact translation")
	var projectile_damage: Array = crowd_runtime.call(&"take_damage_events") as Array
	_assert(not projectile_damage.is_empty(), "projectile gameplay effect")

	print("game_runtime_adapter_smoke: PASS")
	quit(0)


func _assert(condition: bool, label: String) -> void:
	if condition:
		return
	push_error("game_runtime_adapter_smoke: FAIL: %s" % label)
	quit(1)
