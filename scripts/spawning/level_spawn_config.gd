extends Node
class_name LevelSpawnConfig

@export_group("Spawn Playlist")
@export var spawn_playlist: LevelSpawnPlaylist

@export_group("Starting Resources")
@export var starting_seeds: int = 20
@export var starting_gems: int = 1000
@export var starting_weapons: Array[StringName] = [&"spray"]

@export_group("Build Limits")
@export_range(0, 999, 1, "or_greater") var rose_shop_counter_limit: int = 2
