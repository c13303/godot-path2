extends Node2D
class_name BuildingHealthOverlay

# Single lightweight overlay that draws a health bar for every currently damaged,
# registered player-built structure. TileMap-only targets (walls, fences) are
# supported without creating one runtime node per tile: the bars are drawn here
# from the durability service's records. Follows BuildingConstructionOverlay:
# purely visual, and it redraws only when the durability service reports a
# health/registration change (see PlayerPlaceableDurabilityService._bump_and_redraw).
#
# Bars are hidden at full health and while a structure is instant-destroy (plants
# never show a bar); they appear after the first damage and disappear when the
# structure is removed.

const BAR_SIZE: Vector2 = Vector2(22.0, 3.0)
const BAR_Y_OFFSET: float = -14.0
const BG_COLOR: Color = Color(0.05, 0.05, 0.05, 0.85)
const FILL_COLOR: Color = Color(0.9, 0.05, 0.05, 1.0)

var building_manager: BuildingManager = null
var _durability: PlayerPlaceableDurabilityService = null


func _ready() -> void:
	z_as_relative = false
	z_index = 320


func setup(manager: BuildingManager, durability: PlayerPlaceableDurabilityService) -> void:
	building_manager = manager
	_durability = durability


func refresh() -> void:
	queue_redraw()


func _draw() -> void:
	if building_manager == null or _durability == null:
		return
	for raw_record: Variant in _durability.damaged_records():
		var record: Dictionary = raw_record as Dictionary
		var health: int = int(record.get("health", 0))
		var max_health: int = int(record.get("max_health", 0))
		if max_health <= 0 or health >= max_health:
			continue
		# Ask durability where the bar belongs: cell centre for tile buildings, above the roof
		# sprite for a multi-cell house (whose attack cell is the walkable ground entrance).
		var anchor_world: Vector2 = _durability.health_bar_world_position(str(record.get("key", "")))
		var local_center: Vector2 = to_local(anchor_world)
		var bar_position: Vector2 = local_center + Vector2(-BAR_SIZE.x * 0.5, BAR_Y_OFFSET)
		draw_rect(Rect2(bar_position, BAR_SIZE), BG_COLOR)
		var ratio: float = float(health) / float(maxi(1, max_health))
		var fill_size: Vector2 = Vector2((BAR_SIZE.x - 2.0) * ratio, BAR_SIZE.y - 2.0)
		draw_rect(Rect2(bar_position + Vector2.ONE, fill_size), FILL_COLOR)
