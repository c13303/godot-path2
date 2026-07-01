extends Resource
class_name NightSpawnPlaylist

@export_group("Spawner Tracks")
@export var spawner_tracks: Array[SpawnerWaveTrack] = []

@export_group("Special Reward")
## Free currencies handed to the player at the merchant during this night's day.
## Every entry with a positive amount is granted together when collected.
@export var special_rewards: Array[NightReward] = []
## When true the reward is collectible only once for the whole run, even after the
## playlist loops back to this night; repeatable every loop otherwise.
@export var special_reward_one_time: bool = false
