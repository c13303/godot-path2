extends Node
class_name AgentDebugLabelController

## Renders one debug state label per registered agent.
##
## CPathLib reports state and never draws, so the label text is composed here from
## the crowd diagnostics plus the project's own mission phase. Labels refresh on an
## interval with a per-handle stagger so the string work stays spread across frames
## instead of spiking with the agent count.

## The pre-migration overlay redrew from C++ every frame when the interval was 0,
## because nothing persisted between frames. Labels are real nodes now, so they stay
## on screen between refreshes and only the text needs rebuilding — a floor here
## keeps a 0 authored interval from re-querying diagnostics for the whole crowd
## every frame for no visible gain.
## Preloaded rather than referenced by class_name: see agent_phase.gd.
const AgentPhase = preload("res://scripts/native/agent_phase.gd")

const REFRESH_INTERVAL_MINIMUM: float = 0.05

# ffcore::NavigationSource
const SOURCE_NONE: int = 0
const SOURCE_FLOW_FIELD: int = 1
const SOURCE_PATH: int = 2
const SOURCE_MANUAL: int = 3
const SOURCE_DIRECTIONAL_FIELD: int = 4

# ffcore::RouteProgress
const ROUTE_IDLE: int = 0
const ROUTE_FOLLOWING: int = 1
const ROUTE_ARRIVED: int = 2
const ROUTE_FAILED: int = 3

# NavigationRuntime cohort flow-wait states.
const FLOW_WAIT_NONE: int = 0
const FLOW_WAIT_PENDING: int = 1

const MOVING_SPEED_THRESHOLD: float = 1.0

@export var runtime_path: NodePath = NodePath("../CrowdRuntime")
@export var registry_path: NodePath = NodePath("../AgentRegistry")

var _runtime: Node
var _registry: AgentHandleRegistry
var _enabled: bool = false
var _refresh_interval: float = 0.2
var _elapsed: float = 0.0
var _next_refresh_by_handle: Dictionary = {}
var _visuals_by_handle: Dictionary = {}


func _ready() -> void:
	_runtime = get_node_or_null(runtime_path)
	_registry = get_node_or_null(registry_path) as AgentHandleRegistry
	# CrowdRuntime is an earlier sibling, so it may already have enabled us before
	# this _ready runs. Never clobber that with an unconditional set_process(false).
	set_process(_enabled)


func set_enabled(value: bool) -> void:
	if value == _enabled:
		return
	_enabled = value
	set_process(value)
	if not value:
		_clear_all_labels()


func is_enabled() -> bool:
	return _enabled


func set_refresh_interval(value: float) -> void:
	_refresh_interval = maxf(value, REFRESH_INTERVAL_MINIMUM)


func _process(delta: float) -> void:
	if _runtime == null or _registry == null:
		return
	_elapsed += delta
	var handles: PackedInt64Array = _registry.registered_handles()
	var live_handles: Dictionary = {}
	for agent_handle: int in handles:
		live_handles[agent_handle] = true
		if _elapsed < float(_next_refresh_by_handle.get(agent_handle, -1.0)):
			continue
		_next_refresh_by_handle[agent_handle] = _elapsed + _refresh_interval \
			+ _stagger_for(agent_handle)
		_refresh_label(agent_handle)
	_release_stale_handles(live_handles)


func _refresh_label(agent_handle: int) -> void:
	var visual: AgentDebugLabelVisual = _visual_for(agent_handle)
	if visual == null:
		return
	var snapshot: Dictionary = _runtime.call(
		&"get_agent_debug_snapshot", agent_handle
	) as Dictionary
	if snapshot.is_empty():
		visual.clear()
		return
	visual.set_text(compose_label(snapshot))


## Two lines: the project's mission phase on top, the CPathLib motion state below.
## Public so a smoke test can check the wording without building a scene.
func compose_label(snapshot: Dictionary) -> String:
	var phase_text: String = _phase_text(snapshot)
	var motion_text: String = _motion_text(snapshot)
	if phase_text.is_empty():
		return motion_text
	if motion_text.is_empty():
		return phase_text
	return "%s\n%s" % [phase_text, motion_text]


## Reads AgentPhase rather than FlowAgent on purpose: see agent_phase.gd.
func _phase_text(snapshot: Dictionary) -> String:
	var phase: int = int(snapshot.get("phase", AgentPhase.NONE))
	if phase == AgentPhase.FLOW_IN:
		return "flow in"
	if phase == AgentPhase.ASTAR_IN:
		return "path in"
	if phase == AgentPhase.EATING:
		return "eating %ds" % int(snapshot.get("eating_seconds", 0.0))
	if phase == AgentPhase.ASTAR_OUT:
		return "path out"
	if phase == AgentPhase.FLOW_OUT:
		return "flow out"
	if phase == AgentPhase.WAITING_NEW_STATUS:
		return "waiting new status"
	if phase == AgentPhase.DROWNING:
		return "drowning"
	return ""


## Named in CPathLib terms (navigation source, route progress, impulse, recovery)
## rather than the pre-migration steering vocabulary.
func _motion_text(snapshot: Dictionary) -> String:
	if bool(snapshot.get("impulse_active", false)):
		return "impulse" if float(snapshot.get(
			"impulse_control_suppression_remaining", 0.0
		)) <= 0.0 else "impulse (no control)"
	if bool(snapshot.get("paused", false)):
		return "paused"
	if not bool(snapshot.get("forces_enabled", true)):
		return "forces off"
	if bool(snapshot.get("navigation_suspended", false)):
		return "flow pending" if int(snapshot.get(
			"flow_wait", FLOW_WAIT_NONE
		)) == FLOW_WAIT_PENDING else "navigation suspended"

	var source: int = int(snapshot.get("navigation_source", SOURCE_NONE))
	var speed: float = (snapshot.get("velocity", Vector2.ZERO) as Vector2).length()
	var moving: bool = speed > MOVING_SPEED_THRESHOLD
	match source:
		SOURCE_MANUAL:
			return "manual moving" if moving else "manual idle"
		SOURCE_PATH:
			return _route_text("path", snapshot, moving)
		SOURCE_DIRECTIONAL_FIELD:
			return "directional field" if moving else "directional field idle"
		SOURCE_FLOW_FIELD:
			return _flow_text(snapshot, moving)
	return "no navigation"


func _flow_text(snapshot: Dictionary, moving: bool) -> String:
	if not bool(snapshot.get("has_flow", false)):
		return "no flow"
	if not bool(snapshot.get("flow_ready", false)):
		return "flow not ready"
	if bool(snapshot.get("zero_flow_recovery_active", false)):
		return "flow lost (waiting)" if float(snapshot.get(
			"zero_flow_recovery_remaining", 0.0
		)) > 0.0 else "flow lost (recovering)"
	if float(snapshot.get("blocked_motion_seconds", 0.0)) > 0.0:
		return "motion blocked"
	if bool(snapshot.get("bottleneck_waiting", false)):
		return "bottleneck wait"
	if float(snapshot.get("flow_goal_timer", 0.0)) > 0.0:
		return "goal slowdown"
	return _route_text("flow", snapshot, moving)


func _route_text(prefix: String, snapshot: Dictionary, moving: bool) -> String:
	match int(snapshot.get("route_progress", ROUTE_IDLE)):
		ROUTE_ARRIVED:
			return "%s arrived" % prefix
		ROUTE_FAILED:
			return "%s failed" % prefix
	return prefix if moving else "%s idle" % prefix


func _visual_for(agent_handle: int) -> AgentDebugLabelVisual:
	var existing: AgentDebugLabelVisual = _visuals_by_handle.get(
		agent_handle
	) as AgentDebugLabelVisual
	if existing != null:
		return existing
	var node: Node2D = _registry.find_node(agent_handle)
	if node == null:
		return null
	var visual: AgentDebugLabelVisual = AgentDebugLabelVisual.new()
	visual.setup(node)
	_visuals_by_handle[agent_handle] = visual
	return visual


func _release_stale_handles(live_handles: Dictionary) -> void:
	var stale: Array[int] = []
	for raw_handle: Variant in _visuals_by_handle:
		if not live_handles.has(raw_handle):
			stale.append(int(raw_handle))
	for agent_handle: int in stale:
		_visuals_by_handle.erase(agent_handle)
		_next_refresh_by_handle.erase(agent_handle)


func _clear_all_labels() -> void:
	for raw_visual: Variant in _visuals_by_handle.values():
		var visual: AgentDebugLabelVisual = raw_visual as AgentDebugLabelVisual
		if visual != null:
			visual.clear()
	_next_refresh_by_handle.clear()


## Spreads the per-agent refresh across the interval so the string work never lands
## on one frame for the whole crowd.
func _stagger_for(agent_handle: int) -> float:
	return _refresh_interval * (float((agent_handle * 37) % 100) * 0.01)
