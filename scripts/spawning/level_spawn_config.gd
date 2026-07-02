extends Node
class_name LevelSpawnConfig

@export_group("Spawn Playlist")
@export var spawn_playlist: LevelSpawnPlaylist

@export_group("Starting Resources")
@export var starting_seeds: int = 20
@export var starting_gems: int = 1000
@export var starting_money: int = 0
@export var starting_weapons: Array[StringName] = [&"spray"]

@export_group("Monster Drop")
@export_range(0, 100, 1, "suffix:%") var monster_drop_seed_chance_percent: int = 0

@export_group("Tool Shop")
@export var tool_shop_available_items: Array[StringName] = [&"rose", &"turret1", &"wall"]
@export var tool_shop_prices: Dictionary = {
	&"rose": 1,
	&"turret1": 5,
	&"wall": 100,
}
@export var tool_shop_days: Dictionary = {}
@export_range(1, 99, 1) var rose_shop_counter_limit: int = 2

@export_group("Merchent")
@export var merchant_available_items: Array[StringName] = [&"seed", &"spray", &"beam", &"sword", &"bomb"]
@export var merchant_prices: Dictionary = {
	&"seed": 2,
	&"spray": 100,
	&"beam": 100,
	&"sword": 100,
	&"bomb": 100,
}
@export var merchant_days: Dictionary = {}

@export_group("Legacy Shop")
@export var shop_available_items: Array[StringName] = [&"rose", &"turret1", &"wall", &"seed", &"spray", &"beam", &"sword", &"bomb"]
@export var shop_prices: Dictionary = {
	&"rose": 1,
	&"turret1": 5,
	&"wall": 100,
	&"seed": 2,
	&"spray": 100,
	&"beam": 100,
	&"sword": 100,
	&"bomb": 100,
}
