class_name AgentRegistrationConsistencyWatcher
extends Node

# ---------------------------------------------------------------------------
# Diagnostic-only watcher for Godot/native agent registration leaks.
#
# Agents are registered through AgentRegistry.spawn_agent() and normally
# removed through unregister_agent(). Some Godot navigation-phase collections
# discard invalid node references without being able to check whether the
# matching native agent was ever unregistered. An agent freed outside the
# authoritative removal path can therefore stay registered natively and cause a
# slow, persistent performance drift over several nights.
#
# This node compares the live Godot agent set against the native registration
# snapshot once per second and, only when a suspicious condition persists across
# consecutive checks, emits a single push_error() describing the leak.
#
# It NEVER unregisters agents, repairs state, mutates anything, or prints routine
# status. It reads native state through the read-only, gameplay-agnostic
# AgentRegistry.get_registration_debug_snapshot(). When Debug Enabled is off
# it performs no scans and no native calls at all.
# ---------------------------------------------------------------------------

## Groups that hold live agents registered natively. These mirror the groups
## already considered by scene-agent cleanup.
const TRACKED_GROUPS: Array[StringName] = [
	&"player",
	&"main_chars",
	&"monsters",
	&"clients",
	AgentDefinitionService.VILLAGERS_GROUP,
]

## Seconds between consistency checks. Kept low on purpose: registration and
## removal can legitimately span part of a frame, so checking every frame would
## report harmless transients.
const CHECK_INTERVAL_SECONDS: float = 1.0

## Scene-start grace period. Native/Godot spawn and wiring settle during the
## first moments of a scene, so no check runs before this has elapsed.
const GRACE_PERIOD_SECONDS: float = 3.0

## A mismatch must be seen with the same signature this many consecutive checks
## before it is reported. Filters out single-check transients.
const CONFIRMATIONS_REQUIRED: int = 2

var _agent_manager: Node = null

var _time_alive: float = 0.0
var _time_since_check: float = 0.0

## Signature of the mismatch currently being confirmed, and how many consecutive
## checks it has held. Cleared whenever state is healthy or debug is disabled.
var _pending_signature: String = ""
var _pending_count: int = 0

## Signature of the last mismatch actually reported. Prevents spamming the same
## error every second; a materially different mismatch produces a new signature
## and is allowed through.
var _reported_signature: String = ""


func _process(delta: float) -> void:
	# Master gate. When Debug Enabled is off, do nothing: no scan, no native
	# snapshot, no pending state kept, no output. logs_enabled mirrors the master
	# CppDebugOptions.debug_enabled option.
	if not CppDebugOptions.logs_enabled:
		_reset_pending_state()
		return

	_time_alive += delta
	if _time_alive < GRACE_PERIOD_SECONDS:
		return

	_time_since_check += delta
	if _time_since_check < CHECK_INTERVAL_SECONDS:
		return
	_time_since_check = 0.0

	_run_check()


func _reset_pending_state() -> void:
	_pending_signature = ""
	_pending_count = 0
	_reported_signature = ""


func _run_check() -> void:
	var agent_manager: Node = _resolve_agent_manager()
	if agent_manager == null:
		return
	if not agent_manager.has_method(&"get_registration_debug_snapshot"):
		return

	var report: Dictionary = _build_report(agent_manager)
	if not bool(report["has_mismatch"]):
		# Healthy: drop any pending confirmation and clear the report latch so a
		# future genuine mismatch is reported again.
		_pending_signature = ""
		_pending_count = 0
		_reported_signature = ""
		return

	var signature: String = String(report["signature"])
	if signature == _pending_signature:
		_pending_count += 1
	else:
		_pending_signature = signature
		_pending_count = 1

	if _pending_count < CONFIRMATIONS_REQUIRED:
		return

	# Persistent mismatch confirmed. Report once per distinct signature.
	if signature != _reported_signature:
		push_error(_format_error(report))
		_reported_signature = signature


## Resolves AgentRegistry once (a sibling under the shared CPP node) without
## hardcoding a level scene name. Re-resolves if the cached reference went stale.
func _resolve_agent_manager() -> Node:
	if _agent_manager != null and is_instance_valid(_agent_manager):
		return _agent_manager
	var parent: Node = get_parent()
	if parent == null:
		return null
	_agent_manager = parent.get_node_or_null(^"AgentRegistry")
	return _agent_manager


# ---------------------------------------------------------------------------
# Scan + comparison
# ---------------------------------------------------------------------------

func _build_report(agent_manager: Node) -> Dictionary:
	# --- Godot live agent set -------------------------------------------------
	var nav_id_to_descriptors: Dictionary = {}  # nav_id(int) -> Array[String]
	var invalid_nav_nodes: Array[String] = []
	_collect_live_agents(nav_id_to_descriptors, invalid_nav_nodes)

	var godot_ids: Array[int] = []
	var duplicate_nav_ids: Dictionary = {}  # nav_id(int) -> Array[String]
	for raw_id: Variant in nav_id_to_descriptors:
		var nav_id: int = int(raw_id)
		godot_ids.append(nav_id)
		var descriptors: Array = nav_id_to_descriptors[nav_id] as Array
		if descriptors.size() > 1:
			duplicate_nav_ids[nav_id] = descriptors
	godot_ids.sort()

	# --- Native registration snapshot ----------------------------------------
	var snapshot: Dictionary = agent_manager.call(&"get_registration_debug_snapshot") as Dictionary
	var crowd_handles: PackedInt64Array = snapshot.get("crowd_agent_handles", PackedInt64Array()) as PackedInt64Array
	var mapped_handles: PackedInt64Array = snapshot.get("agent_node_mapping_handles", PackedInt64Array()) as PackedInt64Array

	var crowd_set: Dictionary = _to_set(crowd_handles)
	var mapped_set: Dictionary = _to_set(mapped_handles)
	var godot_set: Dictionary = _array_to_set(godot_ids)

	# Union of every native structure: an id present in any of them but with no
	# live Godot node is the leak this watcher exists to find.
	var native_union: Dictionary = {}
	_merge_set(native_union, crowd_set)
	_merge_set(native_union, mapped_set)

	var native_without_godot: Array[int] = _difference(native_union, godot_set)
	var godot_without_native: Array[int] = _difference(godot_set, crowd_set)

	# Suspicious set disagreements (compare sets, not counts).
	var agent_mapping_differs: bool = not _sets_equal(mapped_set, crowd_set)

	var has_mismatch: bool = agent_mapping_differs \
		or native_without_godot.size() > 0 \
		or godot_without_native.size() > 0 \
		or duplicate_nav_ids.size() > 0 \
		or invalid_nav_nodes.size() > 0

	var report: Dictionary = {
		"has_mismatch": has_mismatch,
		"godot_live_count": godot_ids.size(),
		"crowd_count": crowd_handles.size(),
		"mapped_count": mapped_handles.size(),
		"native_without_godot": native_without_godot,
		"godot_without_native": godot_without_native,
		"duplicate_nav_ids": duplicate_nav_ids,
		"invalid_nav_nodes": invalid_nav_nodes,
		"agent_mapping_differs": agent_mapping_differs,
	}
	report["signature"] = _signature_for(report)
	return report


## Fills the two out-parameters from every live, non-freed node in the tracked
## groups. A node appearing in several groups is counted once (deduplicated by
## instance id) while all its groups are retained for reporting.
func _collect_live_agents(nav_id_to_descriptors: Dictionary, invalid_nav_nodes: Array[String]) -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return

	var nodes_by_instance: Dictionary = {}  # instance_id(int) -> {node, groups}
	for group: StringName in TRACKED_GROUPS:
		for node: Node in tree.get_nodes_in_group(group):
			if node == null or not is_instance_valid(node):
				continue
			if node.is_queued_for_deletion():
				continue
			var instance_id: int = node.get_instance_id()
			var info: Dictionary = nodes_by_instance.get(instance_id, {}) as Dictionary
			if info.is_empty():
				info = {"node": node, "groups": [] as Array[String]}
				nodes_by_instance[instance_id] = info
			(info["groups"] as Array).append(String(group))

	for raw_instance: Variant in nodes_by_instance:
		var info: Dictionary = nodes_by_instance[raw_instance] as Dictionary
		var node: Node = info["node"] as Node
		# Nodes in these groups are expected to be agents. Skip anything that is
		# not (no nav_id property) rather than mislabel it as an invalid agent.
		if not ("nav_id" in node):
			continue
		var groups: Array = info["groups"] as Array
		var descriptor: String = "%s %s" % [str(node.get_path()), str(groups)]
		var nav_id: int = int(node.get(&"nav_id"))
		if nav_id <= 0:
			invalid_nav_nodes.append(descriptor)
			continue
		var descriptors: Array = nav_id_to_descriptors.get(nav_id, [] as Array) as Array
		descriptors.append(descriptor)
		nav_id_to_descriptors[nav_id] = descriptors


# ---------------------------------------------------------------------------
# Set helpers (Dictionary used as an int set: id -> true)
# ---------------------------------------------------------------------------

func _to_set(ids: PackedInt64Array) -> Dictionary:
	var out: Dictionary = {}
	for id: int in ids:
		out[id] = true
	return out


func _array_to_set(ids: Array[int]) -> Dictionary:
	var out: Dictionary = {}
	for id: int in ids:
		out[id] = true
	return out


func _merge_set(into: Dictionary, other: Dictionary) -> void:
	for id: Variant in other:
		into[id] = true


## Sorted ids present in `a` but not in `b`.
func _difference(a: Dictionary, b: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for raw_id: Variant in a:
		var id: int = int(raw_id)
		if not b.has(id):
			out.append(id)
	out.sort()
	return out


func _sets_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for id: Variant in a:
		if not b.has(id):
			return false
	return true


# ---------------------------------------------------------------------------
# Signature + error formatting
# ---------------------------------------------------------------------------

## Compact fingerprint of the mismatch content. Identical mismatches produce the
## same signature (so the error is reported once); a materially different
## mismatch produces a new signature (so it is allowed through once confirmed).
func _signature_for(report: Dictionary) -> String:
	var duplicate_keys: Array = (report["duplicate_nav_ids"] as Dictionary).keys()
	duplicate_keys.sort()
	var invalid_nav_nodes: Array = report["invalid_nav_nodes"] as Array
	return "nwg=%s|gwn=%s|dup=%s|inv=%s|am=%s" % [
		str(report["native_without_godot"]),
		str(report["godot_without_native"]),
		str(duplicate_keys),
		str(invalid_nav_nodes),
		str(report["agent_mapping_differs"]),
	]


func _format_error(report: Dictionary) -> String:
	var scene_name: String = "unknown"
	var scene: Node = get_tree().get_current_scene() if get_tree() != null else null
	if scene != null:
		scene_name = scene.name

	var phase: String = "night" if GameState.is_night else "day"

	var lines: Array[String] = []
	lines.append("[AgentRegistrationWatcher] Persistent Godot/native mismatch:")
	lines.append("Godot live=%d, CPathLib crowd=%d, mapped nodes=%d" % [
		int(report["godot_live_count"]),
		int(report["crowd_count"]),
		int(report["mapped_count"]),
	])
	lines.append("agent_mapping_differs=%s" % str(report["agent_mapping_differs"]))
	lines.append("native_without_godot=%s" % str(report["native_without_godot"]))
	lines.append("godot_without_native=%s" % str(report["godot_without_native"]))
	lines.append("duplicates=%s" % _format_descriptor_map(report["duplicate_nav_ids"] as Dictionary))
	lines.append("invalid_nav_nodes=%s" % str(report["invalid_nav_nodes"] as Array))
	lines.append("scene=%s, phase=%s" % [scene_name, phase])
	return "\n".join(lines)


func _format_descriptor_map(descriptor_map: Dictionary) -> String:
	if descriptor_map.is_empty():
		return "{}"
	var parts: Array[String] = []
	var keys: Array = descriptor_map.keys()
	keys.sort()
	for raw_key: Variant in keys:
		var nav_id: int = int(raw_key)
		parts.append("%d: %s" % [nav_id, str(descriptor_map[nav_id])])
	return "{%s}" % ", ".join(parts)
