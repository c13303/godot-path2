extends SceneTree

## Guards the project<->CPathLib boundary contracts that broke during the migration.
##
## Every check here corresponds to a regression that actually shipped. They all live
## at the boundary on purpose: CPathLib's own smoke tests passed the whole time spray
## was broken, because the library was correct and the project handed it the wrong
## field. A test that only drives the library cannot see that class of bug.
##
## Run headless:
##   godot --headless --path <project> --script res://scripts/native/migration_parity_smoke.gd

const CrowdRuntimeScript: Script = preload("res://scripts/native/crowd_runtime.gd")
const AgentRegistryScript: Script = preload("res://scripts/native/agent_handle_registry.gd")
const DebugLabelScript: Script = preload("res://scripts/native/agent_debug_label_controller.gd")
const SimulationConfigScript: Script = preload("res://scripts/native/native_simulation_config.gd")

const TILE: float = 10.0
const GAMEPLAY_IMPULSE_PRIORITY: int = 100

## Methods NativeSimulationConfig.apply_to_crowd/apply_to_navigation depend on. Each
## call site is guarded by has_method, so a rename here does not raise an error - it
## silently stops applying that block. Both the impulse bounds and the debug flags
## were dead this way.
const REQUIRED_CROWD_METHODS: Array[StringName] = [
	&"configure_default_profile",
	&"configure_static_obstacle_avoidance",
	&"configure_agent_interactions",
	&"configure_navigation_behavior",
	&"configure_crowd_steering",
	&"configure_impulse_response",
]
const REQUIRED_NAVIGATION_METHODS: Array[StringName] = [
	&"configure_flow",
	&"configure_grid",
	&"find_path_cells",
]

## The navigation-area API and its garden_* alias set must stay in step: this project
## calls the garden names, a reusable library should not require them, and an
## operation added to one family and not the other is how the two drift apart.
const AREA_ALIAS_PAIRS: Dictionary = {
	&"create_area": &"create_garden",
	&"create_area_from_seed": &"create_garden_from_seed",
	&"create_portal": &"create_garden_portal",
	&"remove_area": &"remove_garden",
	&"set_area_cells": &"set_garden_cells",
	&"set_area_target_cells": &"set_garden_target_cells",
	&"get_area_info": &"get_garden_info",
	&"get_area_handles": &"get_garden_handles",
	&"plan_enter_area_with_options": &"plan_enter_garden",
	&"plan_exit_area_with_options": &"plan_exit_garden",
}

var _failed: bool = false


func _initialize() -> void:
	_check_configuration_reaches_the_world()
	await _check_weapon_impulse_releases_the_agent()
	await _check_impulse_respects_its_lifetime()
	await _check_separation_does_not_scale_with_crowd_size()
	await _check_debug_flags_are_wired()
	if _failed:
		quit(1)
		return
	print("migration parity smoke passed")
	quit(0)


# ---------------------------------------------------------------------------
# 1. Authored configuration actually reaches the native world.
# ---------------------------------------------------------------------------
func _check_configuration_reaches_the_world() -> void:
	var navigation: Node = ClassDB.instantiate(&"NavigationWorld2D") as Node
	var crowd: Node = ClassDB.instantiate(&"CrowdWorld2D") as Node
	if navigation == null or crowd == null:
		_fail("CPathLib classes are not registered")
		return
	root.add_child(navigation)
	root.add_child(crowd)
	for method: StringName in REQUIRED_CROWD_METHODS:
		if not crowd.has_method(method):
			_fail("CrowdWorld2D is missing %s; NativeSimulationConfig silently skips it" % method)
	for method: StringName in REQUIRED_NAVIGATION_METHODS:
		if not navigation.has_method(method):
			_fail("NavigationWorld2D is missing %s" % method)
	for area_method: StringName in AREA_ALIAS_PAIRS:
		var garden_method: StringName = AREA_ALIAS_PAIRS[area_method]
		if not navigation.has_method(area_method):
			_fail("NavigationWorld2D has no neutral %s; the area API is incomplete "
				% area_method + "and a reusable consumer would have to say 'garden'")
		if not navigation.has_method(garden_method):
			_fail("NavigationWorld2D lost the %s alias; this project still calls it"
				% garden_method)
	var configuration: Resource = SimulationConfigScript.new() as Resource
	if not configuration.apply_to_crowd(crowd):
		_fail("apply_to_crowd reported failure")
	if not configuration.apply_to_navigation(navigation):
		_fail("apply_to_navigation reported failure")
	crowd.queue_free()
	navigation.queue_free()


# ---------------------------------------------------------------------------
# 2. A weapon smash hands the agent back once control returns.
#
# The regression: CrowdRuntime derived preserve_navigation from smash_detach_flow,
# so weapon impulses opted out of both the control-suppression window and the rule
# that cancels an impulse whose direction opposes the agent's route. A sprayed enemy
# stayed shoved for the whole impulse lifetime instead of walking it off.
# ---------------------------------------------------------------------------
func _check_weapon_impulse_releases_the_agent() -> void:
	var fixture: Dictionary = await _make_runtime_fixture()
	if fixture.is_empty():
		return
	var crowd: Node = fixture["crowd"] as Node
	var runtime: Node = fixture["runtime"] as Node
	var agent_handle: int = int(fixture["agent"])

	# Route runs +x; the hit pushes -x, straight against it.
	var impact: Dictionary = {
		"hit_agent_handle": agent_handle,
		"position": crowd.call(&"get_agent_position", agent_handle),
		"direction": Vector2.LEFT,
		"owner_agent_handle": 0,
	}
	var weapon_config: Dictionary = {
		"direct_hit_only": true,
		"radius": TILE,
		"smash_force": 300.0,
		"smash_friction_loss": 0.09,
		"smash_detach_flow": false,
		"smash_control_suppression": 0.35,
		"smash_control_suppression_duration": 0.15,
		"damage": 0,
	}
	runtime.call(&"apply_projectile_effect", impact, weapon_config)
	crowd.call(&"step", 0.016)
	if not bool(_diagnostics(crowd, agent_handle).get("impulse_active", false)):
		_fail("weapon impulse was not applied at all")
		_free_fixture(fixture)
		return

	# Well past the 0.15s suppression window, but far short of the 8s lifetime and
	# nowhere near enough time for a 0.09/s decay to fade a 300px/s shove.
	for _index: int in range(60):
		crowd.call(&"step", 0.016)
	if bool(_diagnostics(crowd, agent_handle).get("impulse_active", false)):
		_fail("weapon impulse still owns the agent ~1s after control returned; "
			+ "preserve_navigation is set on a weapon path again")
	_free_fixture(fixture)


# ---------------------------------------------------------------------------
# 3. An impulse always ends, even when nothing opposes it.
#
# The regression: the impulse system had only exponential decay - no lifetime, no
# residual-speed floor - so a gentle decay rate left an agent drifting for minutes.
# ---------------------------------------------------------------------------
func _check_impulse_respects_its_lifetime() -> void:
	var fixture: Dictionary = await _make_runtime_fixture()
	if fixture.is_empty():
		return
	var crowd: Node = fixture["crowd"] as Node
	var agent_handle: int = int(fixture["agent"])
	var configuration: Resource = SimulationConfigScript.new() as Resource
	var lifetime: float = configuration.impulse_maximum_duration
	if lifetime <= 0.0:
		_fail("impulse_maximum_duration is 0; nothing bounds a slow-decaying impulse")
		_free_fixture(fixture)
		return

	# preserve_navigation so the opposition cancel cannot end it early, and a decay
	# slow enough that only the lifetime can. This is the pure lifetime check.
	crowd.call(
		&"apply_impulse", agent_handle, Vector2(400.0, 0.0), 0.0, 0.01, 0.0,
		true, GAMEPLAY_IMPULSE_PRIORITY, true)
	crowd.call(&"step", 0.016)
	if not bool(_diagnostics(crowd, agent_handle).get("impulse_active", false)):
		_fail("impulse was not applied")
		_free_fixture(fixture)
		return
	var steps: int = int(ceil((lifetime + 1.0) / 0.05))
	for _index: int in range(steps):
		crowd.call(&"step", 0.05)
	if bool(_diagnostics(crowd, agent_handle).get("impulse_active", false)):
		_fail("impulse outlived impulse_maximum_duration (%.1fs)" % lifetime)
	_free_fixture(fixture)


# ---------------------------------------------------------------------------
# 4. Crowd depth changes which way separation points, never how hard it pushes.
#
# The regression: separation became a raw sum over every neighbour instead of a
# unit direction scaled to separation_weight, so a dense pack pushed proportionally
# harder and drowned out navigation and obstacle repulsion.
#
# Measured as the steering direction an agent picks with navigation pulling +x and
# a stack of neighbours pushing -y. If separation is normalised, changing only the
# neighbour count leaves that direction unchanged. Read after a single step so the
# geometry cannot drift and make the comparison noisy.
# ---------------------------------------------------------------------------
func _check_separation_does_not_scale_with_crowd_size() -> void:
	var few: Variant = await _steering_angle_under_crowd_pressure(2)
	var many: Variant = await _steering_angle_under_crowd_pressure(6)
	if few == null or many == null:
		return
	var difference: float = absf(float(few) - float(many))
	if difference > 0.05:
		_fail("steering direction moved %.3f rad between 2 and 6 neighbours; "
			% difference + "separation magnitude is scaling with crowd size again")


func _steering_angle_under_crowd_pressure(neighbor_count: int) -> Variant:
	var fixture: Dictionary = await _make_runtime_fixture()
	if fixture.is_empty():
		return null
	var crowd: Node = fixture["crowd"] as Node
	var profile: Dictionary = fixture["profile"] as Dictionary
	var agent_handle: int = int(fixture["agent"])
	var origin: Vector2 = crowd.call(&"get_agent_position", agent_handle) as Vector2
	# Stacked at one point so every neighbour contributes an identical vector and
	# only the count differs. Inside the contact distance (two radii), and well under
	# the 16-neighbour cap so that cap cannot explain a difference.
	var radius: float = float(profile["radius"])
	var crowd_position: Vector2 = origin + Vector2(0.0, radius * 1.5)
	for _index: int in range(neighbor_count):
		var handle: int = int(crowd.call(
			&"add_agent", crowd_position, radius,
			float(profile["maximum_speed"]),
			float(profile["separation_radius"]),
			float(profile["separation_weight"])
		))
		if handle == 0:
			_fail("could not add a crowding neighbour")
			_free_fixture(fixture)
			return null
	crowd.call(&"step", 0.016)
	var steering: Vector2 = _diagnostics(crowd, agent_handle).get(
		"desired_direction", Vector2.ZERO) as Vector2
	_free_fixture(fixture)
	if steering.length() < 0.5:
		_fail("crowded agent produced no steering direction; cannot measure balance")
		return null
	return steering.angle()


# ---------------------------------------------------------------------------
# 5. The debug toggles reach something.
#
# The regression: every CrowdRuntime.set_debug_* wrote into a dictionary nothing
# read, so the whole debug layer was inert while still looking wired.
# ---------------------------------------------------------------------------
func _check_debug_flags_are_wired() -> void:
	var fixture: Dictionary = await _make_runtime_fixture()
	if fixture.is_empty():
		return
	var runtime: Node = fixture["runtime"] as Node
	var labels: Node = fixture["labels"] as Node
	runtime.call(&"set_debug_disable_all_debug", false)
	runtime.call(&"set_debug_show_agent_state_labels", true)
	if not bool(labels.call(&"is_enabled")):
		_fail("set_debug_show_agent_state_labels did not enable the label controller")
	runtime.call(&"set_debug_disable_all_debug", true)
	if bool(labels.call(&"is_enabled")):
		_fail("the master debug gate does not switch agent labels off")
	if not runtime.has_method(&"set_debug_disable_bottlenecks"):
		_fail("set_debug_disable_bottlenecks is gone; CppDebugOptions silently skips it")
	_free_fixture(fixture)


# ---------------------------------------------------------------------------
# Fixture: a minimal CPP subtree wired the way mainRun.tscn wires it, with one
# agent following a flow field along +x.
# ---------------------------------------------------------------------------
func _make_runtime_fixture() -> Dictionary:
	# The whole subtree is assembled detached and attached in one go, so every node's
	# _ready sees its siblings - the way scene instantiation behaves. Adding children
	# one at a time to an attached parent fires _ready early and CrowdRuntime would
	# resolve its label controller to null.
	var host: Node = Node.new()
	host.name = &"CPP"

	var navigation: Node = ClassDB.instantiate(&"NavigationWorld2D") as Node
	var crowd: Node = ClassDB.instantiate(&"CrowdWorld2D") as Node
	if navigation == null or crowd == null:
		_fail("CPathLib classes are not registered")
		host.free()
		return {}
	navigation.name = &"NavigationWorld"
	crowd.name = &"CrowdWorld"
	host.add_child(navigation)
	host.add_child(crowd)
	crowd.set(&"automatic_step", false)

	var walkable: PackedVector2Array = PackedVector2Array()
	for x: int in range(12):
		for y: int in range(3):
			walkable.append(Vector2(x, y))
	if not bool(navigation.call(
		&"configure_grid", Rect2i(0, 0, 12, 3), TILE, Vector2.ZERO,
		walkable, PackedVector2Array()
	)):
		_fail("navigation fixture configuration failed")
		host.free()
		return {}

	var registry: Node = AgentRegistryScript.new() as Node
	registry.name = &"AgentRegistry"
	host.add_child(registry)
	var labels: Node = DebugLabelScript.new() as Node
	labels.name = &"AgentDebugLabels"
	host.add_child(labels)
	var runtime: Node = CrowdRuntimeScript.new() as Node
	runtime.name = &"CrowdRuntime"
	host.add_child(runtime)
	var actor: Node2D = Node2D.new()
	actor.name = &"Actor"
	actor.position = Vector2(TILE * 1.5, TILE * 1.5)
	host.add_child(actor)

	root.add_child(host)
	# _ready does not fire for nodes attached during SceneTree._initialize; the tree
	# runs it on the first frame. CrowdRuntime resolves its crowd, registry and label
	# controller there, so without this wait its references are all null and every
	# check that goes through it reports a false failure.
	await process_frame
	if not registry.setup(crowd, false):
		_fail("registry setup failed")
		host.queue_free()
		return {}
	# World configuration first, then agents - the order the real startup uses.
	# The impulse bounds and steering weights only exist once this is applied; without
	# it the lifetime check below would be measuring an unconfigured world. The agent is
	# sized to this fixture's tile, not the game's 32px one, so a body still fits inside
	# a cell and collision resolution does not pin it in place.
	var configuration: Resource = SimulationConfigScript.new() as Resource
	configuration.tile_size = TILE
	configuration.agent_diameter_tile_ratio = 0.4
	if not configuration.apply_to_crowd(crowd):
		_fail("fixture configuration failed")
		host.queue_free()
		return {}
	var profile: Dictionary = configuration.default_agent_profile()
	var agent_handle: int = registry.register_agent(actor, profile, 0)
	if agent_handle == 0:
		_fail("agent registration failed")
		host.queue_free()
		return {}

	# A ready-made flow toward the far end so the agent has a real route to oppose.
	if not bool(navigation.call(&"build_flow_to_cell", Vector2i(11, 1))) \
			or not bool(crowd.call(&"use_navigation_flow", navigation)):
		_fail("flow construction failed")
		host.queue_free()
		return {}
	if not bool(crowd.call(&"follow_flow", agent_handle)):
		_fail("agent did not attach to the fixture flow")
		host.queue_free()
		return {}
	crowd.call(&"step", 0.016)

	return {
		"host": host, "crowd": crowd, "navigation": navigation,
		"registry": registry, "runtime": runtime, "labels": labels,
		"agent": agent_handle, "profile": profile,
	}


func _free_fixture(fixture: Dictionary) -> void:
	var host: Node = fixture.get("host", null) as Node
	if host != null:
		host.queue_free()


func _diagnostics(crowd: Node, agent_handle: int) -> Dictionary:
	return crowd.call(&"get_agent_diagnostics", agent_handle) as Dictionary


func _fail(message: String) -> void:
	push_error(message)
	printerr("FAIL: %s" % message)
	_failed = true
