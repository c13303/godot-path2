extends Node
class_name LevelSpawnConfig

@export_group("Spawn Playlist")
@export var spawn_playlist: LevelSpawnPlaylist

@export_group("Starting Resources")
@export var starting_seeds: int = 20
@export var starting_gems: int = 1000
@export var starting_money: int = 0
@export var starting_bamboo: int = 0
# Generic currency starts. Keys are CurrencyCatalog ids (StringName) and values are int >= 0.
# Legacy fields above remain for existing levels and inspector readability.
@export var starting_currencies: Dictionary = {}
@export var starting_weapons: Array[StringName] = [&"spray"]
# Any non-weapon item granted to the player at the start of a fresh run, as
# item_id (StringName) -> quantity (int > 0). Placed into the inventory alongside the
# starting weapons; e.g. { &"pasteque": 10 }. Weapons use starting_weapons above.
@export var starting_items: Dictionary = {}
# Item ids whose "Available" box is unchecked in the Rose Level editor's Items tab: they
# are hidden entirely from the in-game toolbuild vertical build menu, even always-shown
# inventory-backed buildables like pasteque. Empty = every buildable stays
# available as before.
@export var starting_item_toolbuild_hidden: Array[StringName] = []

@export_group("Monster Drop")
@export_range(0, 100, 1, "suffix:%") var monster_drop_seed_chance_percent: int = 0

@export_group("Tool Shop")
@export var tool_shop_available_items: Array[StringName] = [&"rose", &"turret_epine", &"wall", &"ronce", &"fence"]
@export var tool_shop_prices: Dictionary = {
	&"rose": 1,
	&"turret_epine": 10,
	&"wall": 100,
	&"ronce": 1,
	&"fence": 1,
}
@export var tool_shop_growth_price_factors: Dictionary = {
	&"ronce": 2.0,
}
@export var tool_shop_days: Dictionary = {}
@export_range(1, 99, 1) var rose_shop_counter_limit: int = 2

@export_group("Merchant")
@export var merchant_available_items: Array[StringName] = [&"seed", &"spray", &"beam", &"sword", &"bomb"]
@export var merchant_prices: Dictionary = {
	&"seed": 2,
	&"spray": 100,
	&"beam": 100,
	&"sword": 100,
	&"bomb": 100,
}
@export var merchant_days: Dictionary = {}
@export var merchant_growth_price_factors: Dictionary = {}

@export_group("Legacy Shop")
@export var shop_available_items: Array[StringName] = [&"rose", &"turret_epine", &"wall", &"ronce", &"fence", &"seed", &"spray", &"beam", &"sword", &"bomb"]
@export var shop_prices: Dictionary = {
	&"rose": 1,
	&"turret_epine": 10,
	&"wall": 100,
	&"ronce": 1,
	&"fence": 1,
	&"seed": 2,
	&"spray": 100,
	&"beam": 100,
	&"sword": 100,
	&"bomb": 100,
}
