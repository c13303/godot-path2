extends Resource
class_name SpawnWave

@export_group("Monster")
## Stable monster catalog ID. Available values come from MonsterCatalog.
@export var monster_type: StringName = &"basic"

@export_group("Schedule")
## Number of monsters this wave must successfully spawn before it completes.
@export_range(0, 100000, 1, "or_greater") var monster_count: int = 1
## Delay after a successful spawn before the next monster in this wave is requested.
@export_range(0.0, 3600.0, 0.1, "or_greater") var spawn_interval_seconds: float = 0.2

@export_group("Playlist Events")
## Optional playlist event that must already be emitted during this night.
@export var wait_for_event: StringName = &""
## Optional playlist event emitted after this wave's final successful spawn.
@export var emit_event: StringName = &""
## Seconds to wait after this wave finishes before emit_event is actually emitted.
@export_range(0.0, 3600.0, 0.1, "or_greater") var emit_delay_seconds: float = 6.0


func is_valid_config() -> bool:
	return monster_count >= 0 and spawn_interval_seconds >= 0.0 and monster_type != &""
