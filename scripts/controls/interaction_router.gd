extends RefCounted
class_name InteractionRouter

## Generic nearest-interaction selection so PlayerController never branches per villager.
##
## Interaction targets (dialog controllers) register by joining the `interaction_targets` scene
## group in their _ready and implementing this small duck-typed contract:
##   can_interact() -> bool                     is the player allowed to interact right now
##   get_interaction_world_position() -> Vector2  where the target sits (for nearest selection)
##   request_interaction() -> bool              open/toggle it; true when the press was consumed
##   is_interaction_open() -> bool              is its dialog currently open
##
## The group is only read on an interact press (never per frame), so adding an ordinary villager
## is a matter of adding its dialog controller to the group — no PlayerController edit.

const INTERACTION_TARGETS_GROUP: StringName = &"interaction_targets"
const PLAYER_GROUP: StringName = &"player"

var _tree: SceneTree = null


func setup(tree: SceneTree) -> void:
	_tree = tree


## True while any registered interaction dialog is open (used to suppress other UI input).
func is_any_open() -> bool:
	for target: Node in _targets():
		if target.has_method("is_interaction_open") and bool(target.call("is_interaction_open")):
			return true
	return false


## Opens the nearest interactable target, or reports the press consumed when one is already open.
## Returns true when the press was consumed, so the caller can fall back to another action.
func try_toggle_nearest() -> bool:
	var targets: Array = _targets()
	# A press while a dialog is open is consumed here; each dialog owns its own close input.
	for target: Node in targets:
		if target.has_method("is_interaction_open") and bool(target.call("is_interaction_open")):
			return true
	var player: Node2D = _tree.get_first_node_in_group(PLAYER_GROUP) as Node2D if _tree != null else null
	var best: Node = null
	var best_distance_sq: float = INF
	for target: Node in targets:
		if not (target.has_method("can_interact") and bool(target.call("can_interact"))):
			continue
		var distance_sq: float = 0.0
		if player != null and target.has_method("get_interaction_world_position"):
			var target_position: Vector2 = target.call("get_interaction_world_position") as Vector2
			distance_sq = player.global_position.distance_squared_to(target_position)
		if best == null or distance_sq < best_distance_sq:
			best = target
			best_distance_sq = distance_sq
	if best == null:
		return false
	return best.has_method("request_interaction") and bool(best.call("request_interaction"))


func _targets() -> Array:
	if _tree == null:
		return []
	return _tree.get_nodes_in_group(INTERACTION_TARGETS_GROUP)
