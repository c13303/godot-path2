extends RefCounted
class_name PlaceableDamageFeedback

const DAMAGE_FLASH_DURATION_SECONDS: float = 0.12

var _manager: BuildingManager = null


func setup(manager: BuildingManager, durability: PlayerPlaceableDurabilityService) -> void:
	_manager = manager
	if durability == null:
		return
	var callback: Callable = Callable(self, "_on_placeable_damaged")
	if not durability.placeable_damaged.is_connected(callback):
		durability.placeable_damaged.connect(callback)


func _on_placeable_damaged(
	cell: Vector2i,
	layer_name: StringName,
	item_id: String,
	_remaining_health: int,
	_max_health: int
) -> void:
	if _manager == null:
		return
	var duration: float = DAMAGE_FLASH_DURATION_SECONDS
	var building_objects: BuildingObjectManager = _manager.get_building_object_manager()
	if building_objects != null:
		var runtime_node: Node = building_objects.get_runtime_node(cell)
		if runtime_node != null and runtime_node.has_method("play_damage_flash"):
			runtime_node.call("play_damage_flash", duration)
			return
	if layer_name == &"plantz" and item_id == "imperial_seed":
		var imperial_visuals: Node = _find_node("Map/ImperialPlantVisuals")
		if imperial_visuals != null and imperial_visuals.has_method("play_damage_flash_at"):
			if bool(imperial_visuals.call("play_damage_flash_at", cell, duration)):
				return
	var rose_dance: Node = _find_node("Map/MonTilemap/plantz/GrownupRoseDance")
	if rose_dance != null and rose_dance.has_method("play_damage_flash_at"):
		rose_dance.call("play_damage_flash_at", layer_name, cell, item_id, duration)


func _find_node(path: String) -> Node:
	if _manager == null:
		return null
	var scene: Node = _manager.get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null(path)
