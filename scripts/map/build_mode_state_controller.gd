extends RefCounted
class_name BuildModeStateController

# Owns build-mode/selection state: which direction the selected buildable faces and
# the composed "selected placeable def" query (game_ui's selected item + the current
# build direction). BuildSystem keeps subsystem orchestration and exposes thin wrappers
# for UI/input/turret callers; the actual selected item id and tool state live in game_ui,
# and remove/unbuild state lives in BuildDragController.
#
# Pure direction/orientation rules (directional detection, forward/backward cycle,
# facing constants) live in BuildDirectionRules; this controller only owns the mutable
# current _build_direction and the composed selected-placeable query.

var _manager: BuildSystem

var _build_direction: Vector2i = BuildDirectionRules.DIRECTION_RIGHT


func setup(manager: BuildSystem) -> void:
	_manager = manager


func get_build_direction() -> Vector2i:
	return _build_direction


# Rotates the selected buildable's facing when it is directional. Returns false (and
# leaves state untouched) when nothing directional is selected, so callers can pass the
# input event through instead of consuming it.
func rotate_selected_build_direction(reverse: bool = false) -> bool:
	var placeable_def: Dictionary = selected_placeable_def()
	if placeable_def.is_empty() or not BuildDirectionRules.is_directional_placeable(placeable_def):
		return false
	_build_direction = BuildDirectionRules.previous_direction(_build_direction) if reverse else BuildDirectionRules.next_direction(_build_direction)
	_clear_hover()
	return true


# The placeable currently selected in game_ui, with the active build direction injected
# for directional buildables. Returns {} when nothing is selected or placement is disabled.
func selected_placeable_def() -> Dictionary:
	var game_ui: Object = _manager.game_ui
	if game_ui == null or not game_ui.has_method("get_selected_build_item_id"):
		return {}
	if _placement_disabled():
		return {}
	var placeable_def: Dictionary = ItemCatalog.get_placeable_def(String(game_ui.call("get_selected_build_item_id")))
	if BuildDirectionRules.is_directional_placeable(placeable_def):
		var directed_def: Dictionary = placeable_def.duplicate(true)
		directed_def["direction"] = _build_direction
		return directed_def
	return placeable_def


# --- BuildSystem wrappers -----------------------------------------------------

func _placement_disabled() -> bool:
	return _manager._placement_disabled()


func _clear_hover() -> void:
	_manager._clear_hover()
