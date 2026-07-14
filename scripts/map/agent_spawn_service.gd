extends RefCounted
class_name AgentSpawnService

# Owns the agent spawning operation flow extracted from BuildingManager.
# Garden/route selection and navigation assignment remain delegated through
# BuildingManager wrappers and their existing services.

const IDLE_GROUP: int = 0
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const SPAWNER_KIND_MONSTER: StringName = &"monster"
const SPAWNER_KIND_CLIENT: StringName = &"client"

var _manager: BuildingManager


func setup(manager: BuildingManager) -> void:
	_manager = manager


func spawn_agent_from(spawner_cell: Vector2i, monster_type: StringName = &"basic", agent_kind: StringName = SPAWNER_KIND_MONSTER) -> bool:
	var agent_scene: PackedScene = _manager._resolve_monster_scene(monster_type)
	if agent_scene == null:
		return false
	var telemetry: BuildingDebugTelemetry = _manager.get_building_debug_telemetry()
	# Select target garden: iterates all gardens, checks targetable / edible plants,
	# and runs _nearest_garden_entry per garden. Prime suspect for select-garden lag.
	var t_sel: int = Time.get_ticks_usec()
	var garden_id: int = _manager._select_garden_for_client_spawner(spawner_cell) if agent_kind == SPAWNER_KIND_CLIENT else _manager._select_garden_for_spawner(spawner_cell)
	var spawn_directly_into_tantrum: bool = (
		agent_kind == SPAWNER_KIND_CLIENT
		and _manager.total_counter_stock() <= 0
		and _manager.grownup_rose_count() <= 0
	)
	var sel_us: int = Time.get_ticks_usec() - t_sel
	if telemetry.over_garden_threshold_us(sel_us):
		telemetry.warn_garden_task_lag_us("_process_spawners.select_garden", sel_us,
			"spawner_cell=%s gardens=%d garden=%d" % [str(spawner_cell), _manager.get_garden_topology_service().gardens().size(), garden_id])
	if garden_id <= 0 and not spawn_directly_into_tantrum:
		# Not an anomaly: every garden is eaten out, sold out, or walled off from this
		# spawner (a normal defensive state). Recorded for reporting, logged debug-gated.
		telemetry.log_expected_spawn_skip("spawner %s has no reachable garden" % spawner_cell)
		return false

	# Route/cache lookup (+ entry-cell resolution). Hits are O(1); misses recompute
	# the nearest garden entry. Hit/miss counters live in the called function.
	var route: Dictionary = {}
	var entry_cell: Vector2i = INVALID_CELL
	if not spawn_directly_into_tantrum:
		var t_route: int = Time.get_ticks_usec()
		route = _manager._get_or_create_spawner_garden_route(spawner_cell, garden_id)
		var route_us: int = Time.get_ticks_usec() - t_route
		if telemetry.over_garden_threshold_us(route_us):
			telemetry.warn_garden_task_lag_us("_process_spawners.route_lookup", route_us,
				"spawner_cell=%s garden=%d ready=%s" % [str(spawner_cell), garden_id, str(route.get("ready", false))])
		entry_cell = route.get("entry_cell", INVALID_CELL) as Vector2i
	# Lazy flow fields: the route's plant group is allocated immediately, but its flow
	# field may still be queued/computing. We no longer refuse the spawn here — as long
	# as a group exists, _assign_agent_to_garden_entry_flow parks the agent in the
	# waiting-entry-flow set (it freezes as "ff wait" / "ff being computed") and attaches
	# once the field is ready. Only a missing group means the route is genuinely unusable.
	if not spawn_directly_into_tantrum and int(route.get("plant_group", -1)) <= IDLE_GROUP:
		telemetry.log_spawn_failure("spawner %s garden %d has no flow group" % [spawner_cell, garden_id])
		return false
	if not spawn_directly_into_tantrum and entry_cell == INVALID_CELL:
		telemetry.log_spawn_failure("spawner %s garden %d has no entry cell" % [spawner_cell, garden_id])
		return false

	if not spawn_directly_into_tantrum and not _manager._is_sane_cell(entry_cell):
		telemetry.log_spawn_failure("spawner %s garden %d insane entry_cell %s" % [spawner_cell, garden_id, entry_cell])
		return false

	# Occupied-cell scan: walks the main_chars/monsters/player scene groups every
	# spawn. Grows with active unit count.
	var t_occ: int = Time.get_ticks_usec()
	var occupied: Array[Vector2i] = _manager._occupied_cells()
	var occ_us: int = Time.get_ticks_usec() - t_occ
	if telemetry.over_garden_threshold_us(occ_us):
		telemetry.warn_garden_task_lag_us("_process_spawners.occupied_cells", occ_us,
			"spawner_cell=%s occupied=%d" % [str(spawner_cell), occupied.size()])

	# Free-cell search: spirals out from the spawner doing per-cell walkable/wall
	# (TileMap) lookups until a free cell is found. Can spike when the spawner is
	# boxed in.
	var t_free: int = Time.get_ticks_usec()
	var spawn_cell: Vector2i = _manager._find_free_cell_near(spawner_cell, occupied)
	var free_us: int = Time.get_ticks_usec() - t_free
	if telemetry.over_garden_threshold_us(free_us):
		telemetry.warn_garden_task_lag_us("_process_spawners.find_free_cell", free_us,
			"spawner_cell=%s spawn_cell=%s" % [str(spawner_cell), str(spawn_cell)])
	if spawn_cell == INVALID_CELL or not _manager._is_sane_cell(spawn_cell):
		telemetry.log_spawn_failure("spawner %s could not find a sane walkable spawn cell (got %s)" % [spawner_cell, spawn_cell])
		return false

	# Instantiate + add_child + group registration of the agent scene.
	var t_inst: int = Time.get_ticks_usec()
	var agent: Node2D = agent_scene.instantiate() as Node2D
	var parent: Node = _manager.parent_for_agents if _manager.parent_for_agents else _manager.get_tree().current_scene
	parent.add_child(agent)
	agent.global_position = _manager._cell_center(spawn_cell)
	agent.z_index = int(agent.global_position.y)
	if agent_kind == SPAWNER_KIND_CLIENT:
		agent.add_to_group("clients")
		_manager._register_runtime_agent(agent, &"clients")
		_manager._apply_client_data(agent)
	else:
		agent.add_to_group("monsters")
		_manager._register_runtime_agent(agent, &"monsters")
		# Apply the monster bible entry (sprite + health + speed/inertia metas)
		# before the agent is registered with the native manager, which reads the
		# metas in spawn_agent.
		_manager._apply_monster_data(agent, monster_type)
	agent.set_meta("agent_kind", agent_kind)
	var inst_us: int = Time.get_ticks_usec() - t_inst
	if telemetry.over_garden_threshold_us(inst_us):
		telemetry.warn_garden_task_lag_us("_process_spawners.instantiate_agent", inst_us,
			"spawner_cell=%s spawn_cell=%s" % [str(spawner_cell), str(spawn_cell)])

	if _manager.agent_manager and _manager.agent_manager.has_method("spawn_agent"):
		# Register the agent with the nav/agent manager (flowfield/pathfinder side).
		var t_reg: int = Time.get_ticks_usec()
		var nav_id: int = int(_manager.agent_manager.call("spawn_agent", agent, IDLE_GROUP))
		agent.set("nav_id", nav_id)
		if _manager.agent_manager.has_method("set_agent_never_rest"):
			_manager.agent_manager.call("set_agent_never_rest", nav_id, true)
		var reg_us: int = Time.get_ticks_usec() - t_reg
		if telemetry.over_garden_threshold_us(reg_us):
			telemetry.warn_garden_task_lag_us("_process_spawners.register_agent", reg_us,
				"spawner_cell=%s nav_id=%d" % [str(spawner_cell), nav_id])

		if spawn_directly_into_tantrum:
			var tantrum_started: bool = _manager.get_client_tantrum_controller().start_for_client(agent)
			if not tantrum_started:
				if _manager.agent_manager.has_method("unregister_agent"):
					_manager.agent_manager.call("unregister_agent", nav_id)
				_manager._unregister_runtime_agent(agent)
				agent.remove_from_group(&"clients")
				agent.queue_free()
				telemetry.log_spawn_failure("spawner %s could not start rose-less client tantrum" % spawner_cell)
				return false
			_manager.get_spawn_tick_controller().increment_assigned_count()
			telemetry.log("spawned tantrum client nav_id=%d spawn_cell=%s spawner=%s" % [
				nav_id, spawn_cell, spawner_cell,
			])
			return true

		# Assign the garden-entry route: attaches the monster to the entry flow
		# group. Usually the heaviest leg when the route/flow is first created.
		var t_assign: int = Time.get_ticks_usec()
		var assigned: bool = _manager._assign_agent_to_garden_entry_flow(agent, spawner_cell, garden_id, entry_cell)
		var assign_us: int = Time.get_ticks_usec() - t_assign
		if telemetry.over_garden_threshold_us(assign_us):
			telemetry.warn_garden_task_lag_us("_process_spawners.assign_route", assign_us,
				"spawner_cell=%s garden=%d entry=%s assigned=%s" % [
					str(spawner_cell), garden_id, str(entry_cell), str(assigned)])
		if not assigned:
			if _manager.agent_manager.has_method("unregister_agent"):
				_manager.agent_manager.call("unregister_agent", nav_id)
			var failed_group: StringName = &"clients" if agent_kind == SPAWNER_KIND_CLIENT else &"monsters"
			_manager._unregister_runtime_agent(agent)
			agent.remove_from_group(failed_group)
			agent.queue_free()
			telemetry.log_spawn_failure("spawner %s garden %d entry flow not ready" % [spawner_cell, garden_id])
			return false
		_manager.get_spawn_tick_controller().increment_assigned_count()
		var kind_label: String = "client" if agent_kind == SPAWNER_KIND_CLIENT else "monster"
		telemetry.log("spawned %s nav_id=%d spawn_cell=%s entry=%s spawner=%s garden=%d" % [
			kind_label, nav_id, spawn_cell, entry_cell, spawner_cell, garden_id
		])

	return true
