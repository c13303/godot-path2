extends RefCounted
class_name AgentDefinitionService

# Owns agent definition resolution and visual/stat setup for spawned agents. It only
# applies data to an already-instantiated agent; it never spawns, registers, routes,
# assigns, or frees agents (BuildingManager's spawn orchestration keeps that).

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/cat.png")
const MERCHANT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/merchent.png")
const BUILDER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/builder.png")
const BUILDER_HAMMER_TEXTURE: Texture2D = preload("res://assets/sprites/house/marto.png")
const BUILDER_HAMMER_SCALE: Vector2 = Vector2(0.56, 0.56)
const CLIENT_HEALTH: int = 10
const CLIENT_SPRITE_HFRAMES: int = 7
const CLIENT_SPRITE_FRAME_LAYOUT: StringName = &"client_directional_7_horizontal"
const BIG_MONSTER_BOUNCE_HEIGHT: float = 0.225
const BIG_MONSTER_WALK_SQUASH: float = 0.03

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
# native agent manager reads in spawn_agent (speed/crowd/smash scales).
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
	agent.set_meta("monster_sprite_frame_layout", data.sprite_frame_layout)
	# _ready() already ran (add_child), so override both the exported cap and the
	# live pool.
	agent.set("max_health", data.max_health)
	agent.set("health", data.max_health)
	agent.set_meta("monster_speed_scale", data.speed_scale)
	agent.set_meta("monster_crowd_resist", data.crowd_resist_scale)
	agent.set_meta("agent_contact_push_power", data.contact_push_power)
	agent.set_meta("agent_contact_push_resist", data.contact_push_resist)
	agent.set_meta("agent_contact_push_cooldown", data.contact_push_cooldown)
	agent.set_meta("monster_smash_resist", data.smash_resist_scale)
	if agent is CanvasItem:
		var canvas_item: CanvasItem = agent as CanvasItem
		canvas_item.queue_redraw()
	if monster_type == MonsterCatalog.BIG_MONSTER_ID:
		_apply_bigmonster_animation(agent)


# Apply the client visual setup to a freshly instantiated client agent.
func apply_client_data(agent: Node) -> void:
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = CLIENT_TEXTURE
		sprite.hframes = CLIENT_SPRITE_HFRAMES
		sprite.frame = 0
		sprite.flip_h = false
	agent.set("max_health", CLIENT_HEALTH)
	agent.set("health", CLIENT_HEALTH)
	agent.set_meta("client_sprite_frame_layout", CLIENT_SPRITE_FRAME_LAYOUT)


func apply_merchant_data(agent: Node) -> void:
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = MERCHANT_TEXTURE
		sprite.hframes = 4
		sprite.frame = 0
		sprite.flip_h = false


func apply_builder_data(agent: Node) -> void:
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = BUILDER_TEXTURE
		sprite.hframes = 4
		sprite.frame = 0
		sprite.flip_h = false
	# The hammer is part of the Builder's permanent look; construction only spins it.
	if agent.has_method("set_held_object"):
		agent.call("set_held_object", BUILDER_HAMMER_TEXTURE, 1, 0, BUILDER_HAMMER_SCALE)


func _apply_bigmonster_animation(agent: Node) -> void:
	var animation: CharacterAnimation = agent.get_node_or_null("characterAnimation") as CharacterAnimation
	if animation == null:
		return
	animation.bounce_height = BIG_MONSTER_BOUNCE_HEIGHT
	animation.walk_squash = BIG_MONSTER_WALK_SQUASH


func _debug_telemetry() -> BuildingDebugTelemetry:
	return _manager.get_building_debug_telemetry()
