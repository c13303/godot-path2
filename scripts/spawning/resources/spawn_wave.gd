extends Resource
class_name SpawnWave

@export_group("Monster")
## Stable monster catalog ID. Currently supported: "basic".
@export var monster_type: StringName = &"basic"

@export_group("Schedule")
## Number of monsters this wave must successfully spawn before it completes.
@export_range(0, 100000, 1, "or_greater") var monster_count: int = 1
## Delay after a successful spawn before the next monster in this wave is requested.
@export_range(0.0, 3600.0, 0.1, "or_greater") var spawn_interval_seconds: float = 3.0

@export_group("Playlist Events")
## Optional playlist event that must already be emitted during this night.
@export var wait_for_event: StringName = &""
## Optional playlist event emitted immediately after this wave's final successful spawn.
@export var emit_event: StringName = &""


func is_valid_config() -> bool:
	return monster_count >= 0 and spawn_interval_seconds >= 0.0 and monster_type != &""
