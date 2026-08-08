extends SceneTree


func _initialize() -> void:
	var crowd: Node = ClassDB.instantiate(&"CrowdWorld2D") as Node
	var projectiles: Node = ClassDB.instantiate(&"ProjectileWorld2D") as Node
	if crowd == null or projectiles == null:
		_fail("generic crowd or projectile class is not registered")
		return
	root.add_child(crowd)
	root.add_child(projectiles)
	crowd.set(&"automatic_step", false)
	projectiles.set(&"automatic_step", false)
	projectiles.call(&"set_crowd_world", crowd)

	var profile: int = int(crowd.call(
		&"create_profile", 2.0, 0.0, 0.0, 0.0,
		0.0, 0.0, 1.0, 0, 2
	))
	var target: int = int(crowd.call(
		&"add_agent_with_profile", Vector2(25.0, 5.0), profile
	))
	var type_handle: int = int(projectiles.call(&"create_projectile_type", {
		"speed": 100.0,
		"lifetime": 1.0,
		"radius": 1.0,
		"static_collision_mask": 0,
		"target_category_mask": 2,
		"pool_size": 2,
	}))
	if target <= 0 or type_handle <= 0:
		_fail("generic projectile fixture setup failed")
		return
	var type_handles: PackedInt64Array = projectiles.call(
		&"get_projectile_type_handles"
	) as PackedInt64Array
	if type_handles.find(type_handle) < 0:
		_fail("active projectile type diagnostics are incomplete")
		return

	var instance: int = int(projectiles.call(
		&"spawn_projectile", type_handle, Vector2(0.0, 5.0), Vector2.RIGHT,
		Vector2.ZERO, 0, 73
	))
	if instance <= 0 or int(projectiles.call(&"get_active_count", type_handle)) != 1:
		_fail("generic projectile spawn failed")
		return
	var active_states: Array = projectiles.call(
		&"get_active_projectile_states", type_handle
	) as Array
	if active_states.size() != 1 or int(active_states[0].get("caller_token", 0)) != 73:
		_fail("generic projectile active-state diagnostics changed")
		return
	projectiles.call(&"step", 0.3)
	var impacts: Array = projectiles.call(&"take_impacts") as Array
	if impacts.size() != 1 or int(impacts[0].get("kind", -1)) != 2 \
			or int(impacts[0].get("hit_agent_handle", 0)) != target \
			or int(impacts[0].get("caller_token", 0)) != 73:
		_fail("generic swept agent impact event changed")
		return

	if not bool(projectiles.call(
		&"set_static_collision_grid", Rect2i(0, 0, 4, 1), 10.0, Vector2.ZERO,
		PackedVector2Array([Vector2(1, 0)]), PackedInt64Array([4])
	)):
		_fail("generic projectile static-grid upload failed")
		return
	if not bool(projectiles.call(&"update_projectile_type", type_handle, {
		"speed": 100.0,
		"lifetime": 1.0,
		"radius": 1.0,
		"static_collision_mask": 4,
		"target_category_mask": 0,
		"pool_size": 2,
	})):
		_fail("generic projectile type update failed")
		return
	projectiles.call(
		&"spawn_projectile", type_handle, Vector2(5.0, 5.0), Vector2.RIGHT,
		Vector2.ZERO, 0, 84
	)
	projectiles.call(&"step", 0.2)
	impacts = projectiles.call(&"take_impacts") as Array
	if impacts.size() != 1 or int(impacts[0].get("kind", -1)) != 0 \
			or int(impacts[0].get("collider_mask", 0)) != 4 \
			or impacts[0].get("collider_cell", Vector2i(-1, -1)) != Vector2i(1, 0):
		_fail("generic swept static impact event changed")
		return

	projectiles.call(&"clear_static_collision_grid")
	if not bool(projectiles.call(&"remove_projectile_type", type_handle)):
		_fail("generic projectile type removal failed")
		return
	if int(projectiles.call(
		&"spawn_projectile", type_handle, Vector2.ZERO, Vector2.RIGHT
	)) != 0:
		_fail("stale projectile type handle remained usable")
		return

	projectiles.queue_free()
	crowd.queue_free()
	print("ProjectileWorld2D smoke test passed")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
