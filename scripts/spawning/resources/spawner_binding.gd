extends Resource
class_name SpawnerBinding

@export_group("Spawner Binding")
## Stable ID referenced by playlist tracks.
@export var spawner_id: StringName = &""
@export var kind: StringName = &"monster"
## Physical tile cell scanned from the level's authored spawner tile.
@export var cell: Vector2i = Vector2i.ZERO
@export var exit_cell: Vector2i = Vector2i.ZERO
@export_range(0.0, 3600.0, 0.1, "or_greater") var frequency_client: float = 1.0
