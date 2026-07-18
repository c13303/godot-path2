extends RefCounted
class_name InteractionRouter

## Player-owned interaction proximity coordinator.
##
## Dialog controllers are stable adapters registered once from the scene group. This coordinator
## caches their eligibility and tile, selects one deterministic nearest target, and only refreshes
## the cache when the player changes tile or the centralized fallback detects target state/motion.
## The fallback covers native avoidance movement and eligibility changes which currently expose no
## signal; it never performs a scene-tree search and does not recompute while nothing changed.

signal selected_target_changed(target: Node)

const INTERACTION_TARGETS_GROUP: StringName = &"interaction_targets"
const STATE_REFRESH_INTERVAL_SECONDS: float = 0.1
const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)
const POSITION_CHANGE_EPSILON_SQUARED: float = 0.01

var _tree: SceneTree = null
var _player: Node2D = null
var _floor_layer: TileMapLayer = null
var _targets: Array[Node] = []
var _state_by_target_id: Dictionary = {}
var _selected_target: Node = null
var _player_cell: Vector2i = INVALID_CELL
var _refresh_elapsed: float = 0.0
var _gamepad_input_mode: bool = false


func setup(tree: SceneTree, player: Node2D, floor_layer: TileMapLayer) -> void:
	_tree = tree
	_player = player
	_floor_layer = floor_layer


## Called once after every scene node has completed _ready(). Runtime villagers are represented by
## these persistent dialog adapters, so their spawn/removal is an adapter state change, not a new
## registry entry.
func register_scene_targets() -> void:
	_clear_selected_target()
	_targets.clear()
	_state_by_target_id.clear()
	if _tree == null:
		return
	for raw_target: Node in _tree.get_nodes_in_group(INTERACTION_TARGETS_GROUP):
		if not _has_required_contract(raw_target):
			continue
		_targets.append(raw_target)
	_targets.sort_custom(_target_precedes)
	_refresh_target_states(true)
	_update_player_cell()
	_recompute_selected_target()


func process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_clear_selected_target()
		return
	var player_moved_tile: bool = _update_player_cell()
	_refresh_elapsed += maxf(0.0, delta)
	var target_state_changed: bool = false
	if _refresh_elapsed >= STATE_REFRESH_INTERVAL_SECONDS:
		_refresh_elapsed = fmod(_refresh_elapsed, STATE_REFRESH_INTERVAL_SECONDS)
		target_state_changed = _refresh_target_states(false)
	if player_moved_tile or target_state_changed:
		_recompute_selected_target()


func selected_target() -> Node:
	return _selected_target if _selected_target != null and is_instance_valid(_selected_target) else null


func set_selected_target_input_mode(is_gamepad: bool) -> void:
	_gamepad_input_mode = is_gamepad
	_apply_selected_target_input_mode()


## True while any registered interaction dialog is open (used to suppress other UI input).
func is_any_open() -> bool:
	for target: Node in _targets:
		if is_instance_valid(target) and target.has_method("is_interaction_open") \
				and bool(target.call("is_interaction_open")):
			return true
	return false


## Routes input only to the cached selected target. One final local validity/range check protects
## against state changing between refreshes; no scene-wide search occurs on input.
func try_toggle_selected() -> bool:
	if is_any_open():
		return true
	var target: Node = selected_target()
	if target == null:
		return false
	if not _target_is_currently_selectable(target):
		_refresh_target_state(target)
		_recompute_selected_target()
		return false
	return bool(target.call("request_interaction"))


func _refresh_target_states(force_changed: bool) -> bool:
	var changed: bool = force_changed
	var stale_targets: Array[Node] = []
	for target: Node in _targets:
		if target == null or not is_instance_valid(target) or target.is_queued_for_deletion():
			stale_targets.append(target)
			changed = true
			continue
		if _refresh_target_state(target):
			changed = true
	for target: Node in stale_targets:
		_targets.erase(target)
	return changed


func _refresh_target_state(target: Node) -> bool:
	var target_id: int = target.get_instance_id()
	var old_state: Dictionary = _state_by_target_id.get(target_id, {}) as Dictionary
	var position: Vector2 = target.call("get_interaction_world_position") as Vector2
	var cell: Vector2i = _world_to_cell(position)
	var eligible: bool = bool(target.call("can_interact"))
	if target.has_method("is_interaction_open") and bool(target.call("is_interaction_open")):
		eligible = false
	var changed: bool = old_state.is_empty() \
		or bool(old_state.get("eligible", false)) != eligible \
		or (old_state.get("cell", INVALID_CELL) as Vector2i) != cell \
		or (old_state.get("position", Vector2.ZERO) as Vector2).distance_squared_to(position) > POSITION_CHANGE_EPSILON_SQUARED
	_state_by_target_id[target_id] = {
		"eligible": eligible,
		"cell": cell,
		"position": position,
	}
	return changed


func _recompute_selected_target() -> void:
	var best: Node = null
	var best_distance_squared: float = INF
	for target: Node in _targets:
		if not _cached_target_in_range(target):
			continue
		var state: Dictionary = _state_by_target_id.get(target.get_instance_id(), {}) as Dictionary
		var target_position: Vector2 = state.get("position", Vector2.ZERO) as Vector2
		var distance_squared: float = _player.global_position.distance_squared_to(target_position)
		if best == null or distance_squared < best_distance_squared:
			best = target
			best_distance_squared = distance_squared
		elif is_equal_approx(distance_squared, best_distance_squared) and _target_precedes(target, best):
			best = target
	_set_selected_target(best)


func _cached_target_in_range(target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var state: Dictionary = _state_by_target_id.get(target.get_instance_id(), {}) as Dictionary
	if state.is_empty() or not bool(state.get("eligible", false)):
		return false
	var target_cell: Vector2i = state.get("cell", INVALID_CELL) as Vector2i
	return _cells_within_radius(_player_cell, target_cell, _interaction_radius(target))


func _target_is_currently_selectable(target: Node) -> bool:
	if target == null or not is_instance_valid(target) or not bool(target.call("can_interact")):
		return false
	if target.has_method("is_interaction_open") and bool(target.call("is_interaction_open")):
		return false
	var target_position: Vector2 = target.call("get_interaction_world_position") as Vector2
	return _cells_within_radius(_world_to_cell(_player.global_position), _world_to_cell(target_position), _interaction_radius(target))


func _set_selected_target(target: Node) -> void:
	if target == _selected_target:
		return
	if _selected_target != null and is_instance_valid(_selected_target) \
			and _selected_target.has_method("set_interaction_selected"):
		_selected_target.call("set_interaction_selected", false)
	_selected_target = target
	if _selected_target != null and is_instance_valid(_selected_target) \
			and _selected_target.has_method("set_interaction_selected"):
		_selected_target.call("set_interaction_selected", true)
	_apply_selected_target_input_mode()
	selected_target_changed.emit(_selected_target)


func _apply_selected_target_input_mode() -> void:
	if _selected_target != null and is_instance_valid(_selected_target) \
			and _selected_target.has_method("set_interaction_input_mode"):
		_selected_target.call("set_interaction_input_mode", _gamepad_input_mode)


func _clear_selected_target() -> void:
	_set_selected_target(null)


func _update_player_cell() -> bool:
	var next_cell: Vector2i = _world_to_cell(_player.global_position) if _player != null else INVALID_CELL
	if next_cell == _player_cell:
		return false
	_player_cell = next_cell
	return true


func _world_to_cell(world_position: Vector2) -> Vector2i:
	if _floor_layer == null or not is_instance_valid(_floor_layer):
		return INVALID_CELL
	return _floor_layer.local_to_map(_floor_layer.to_local(world_position))


func _interaction_radius(target: Node) -> int:
	if target.has_method("get_interaction_radius_tiles"):
		return maxi(0, int(target.call("get_interaction_radius_tiles")))
	return 0


func _cells_within_radius(a: Vector2i, b: Vector2i, radius: int) -> bool:
	if a == INVALID_CELL or b == INVALID_CELL or radius <= 0:
		return false
	var cell_delta: Vector2i = a - b
	return abs(cell_delta.x) <= radius and abs(cell_delta.y) <= radius


func _has_required_contract(target: Node) -> bool:
	return target != null \
		and target.has_method("can_interact") \
		and target.has_method("get_interaction_world_position") \
		and target.has_method("get_interaction_radius_tiles") \
		and target.has_method("request_interaction")


func _target_precedes(a: Node, b: Node) -> bool:
	var a_key: String = String(a.get_path()) if a != null and a.is_inside_tree() else str(a.get_instance_id())
	var b_key: String = String(b.get_path()) if b != null and b.is_inside_tree() else str(b.get_instance_id())
	return a_key < b_key
