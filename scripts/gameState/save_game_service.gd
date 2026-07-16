extends RefCounted
class_name SaveGameService

# Owns the public save-game commands. Progression keeps compatibility helper
# implementations for now; this service is the stable owner that UI/input callers
# should route through.

var _progression: Node


func setup(progression: Node) -> void:
	_progression = progression


func save_progression(save_path: String, gameplay_phase_override: String = "", gameplay_phase_state_override: Dictionary = {}) -> bool:
	if _progression == null:
		return false
	return bool(_progression.call("_save_progression_impl", save_path, gameplay_phase_override, gameplay_phase_state_override))


func load_progression() -> void:
	if _progression == null:
		return
	_progression.call("_load_progression_impl")


func reset_game() -> void:
	if _progression == null:
		return
	_progression.call("_reset_game_impl")
