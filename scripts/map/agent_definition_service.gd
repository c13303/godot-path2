extends RefCounted
class_name AgentDefinitionService

# Owns agent definition resolution and visual/stat setup for spawned agents. It only
# applies data to an already-instantiated agent; it never spawns, registers, routes,
# assigns, or frees agents (BuildingManager's spawn orchestration keeps that).

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/client.png")

var _manager: Node


func setup(manager: Node) -> void:
	_manager = manager


func resolve_monster_scene(monster_type: StringName) -> PackedScene:
	# Every monster type shares character.tscn; MonsterData (applied at spawn via
	# apply_monster_data) drives the per-type sprite and stats.
	if MonsterCatalog.has_monster(monster_type):
		return AGENT_SCENE
	var debug_telemetry: BuildingDebugTelemetry = _debug_telemetry()
	if debug_telemetry != null:
		debug_telemetry.log_spawn_failure("unknown monster_type '%s'" % String(monster_type))
	return null


# Apply a MonsterData bible entry to a freshly instantiated monster agent: swaps the
# sprite, sets health, and stashes the per-agent stat overrides as metadata that the
# native agent manager reads in spawn_agent (speed/crowd/smash scales). The
# "monster_type" meta is also kept so the corpse can reuse the same sprite.
func apply_monster_data(agent: Node, monster_type: StringName) -> void:
	agent.set_meta("monster_type", monster_type)
	var data: MonsterData = MonsterCatalog.get_monster(monster_type)
	if data == null:
		return
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		if data.texture != null:
			sprite.texture = data.texture
		sprite.hframes = data.sprite_hframes
		sprite.scale = data.sprite_scale
		sprite.position = data.sprite_offset
	# _ready() already ran (add_child), so override both the exported cap and the
	# live pool.
	agent.set("max_health", data.max_health)
	agent.set("health", data.max_health)
	agent.set_meta("monster_speed_scale", data.speed_scale)
	agent.set_meta("monster_crowd_resist", data.crowd_resist_scale)
	agent.set_meta("monster_smash_resist", data.smash_resist_scale)


# Apply the client visual setup to a freshly instantiated client agent.
func apply_client_data(agent: Node) -> void:
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = CLIENT_TEXTURE
		sprite.hframes = 5


func _debug_telemetry() -> BuildingDebugTelemetry:
	return _manager.get("_debug_telemetry") as BuildingDebugTelemetry
