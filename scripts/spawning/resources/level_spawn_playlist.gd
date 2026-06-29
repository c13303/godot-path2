extends Resource
class_name LevelSpawnPlaylist

@export_group("Nights")
@export var nights: Array[NightSpawnPlaylist] = []


func get_night_count() -> int:
	return nights.size()
