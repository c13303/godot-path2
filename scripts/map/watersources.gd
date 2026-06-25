extends TileMapLayer
class_name WaterSources

@export var refill_amount: int = 10
@export var refill_interval_seconds: float = 0.1
@export_range(0.01, 1.0, 0.01) var player_slowdown: float = 0.5
@export var foot_sample_offset: Vector2 = Vector2.ZERO


func has_water_at_foot_position(world_position: Vector2) -> bool:
	var sample_position: Vector2 = world_position + foot_sample_offset
	var cell: Vector2i = local_to_map(to_local(sample_position))
	return get_cell_source_id(cell) != -1
