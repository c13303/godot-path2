extends Resource
class_name SpawnerWaveTrack

@export_group("Spawner")
## Stable authored ID resolved through the level's spawner bindings.
@export var spawner_id: StringName = &""

@export_group("Waves")
@export var waves: Array[SpawnWave] = []
