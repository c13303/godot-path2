extends Resource
class_name SpawnerBinding

@export_group("Spawner Binding")
## Stable ID referenced by playlist tracks.
@export var spawner_id: StringName = &""
## Physical tile cell scanned from the level's authored spawner tile.
@export var cell: Vector2i = Vector2i.ZERO
