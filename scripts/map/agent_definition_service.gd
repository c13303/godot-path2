extends RefCounted
class_name AgentDefinitionService

# Owns agent definition resolution and visual/stat setup for spawned agents. It only
# applies data to an already-instantiated agent; it never spawns, registers, routes,
# assigns, or frees agents (BuildingManager's spawn orchestration keeps that).

const AGENT_SCENE: PackedScene = preload("res://scenes/entities/character.tscn")
const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/cat.png")
const MERCHANT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/merchent.png")
const INVENTOR_TEXTURE: Texture2D = preload("res://assets/sprites/legval/inventor.png")
const SHEEP_TEXTURE: Texture2D = preload("res://assets/sprites/legval/sheep_villager.png")
const BUILDER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/builder.png")
const FUNDAMENTAL_BUILDER_TEXTURE: Texture2D = preload("res://assets/sprites/legval/fundamental_builder.png")
const BUILDER_HAMMER_TEXTURE: Texture2D = preload("res://assets/sprites/house/marto.png")
const BUILDER_HAMMER_SCALE: Vector2 = Vector2(0.56, 0.56)
const VILLAGERS_GROUP: StringName = &"villagers"
const CLIENT_HEALTH: int = 10
const CLIENT_SPRITE_HFRAMES: int = 7
const CLIENT_SPRITE_FRAME_LAYOUT: StringName = &"client_directional_7_horizontal"
const BIG_MONSTER_BOUNCE_HEIGHT: float = 0.225
const BIG_MONSTER_WALK_SQUASH: float = 0.03
const VILLAGER_CONTACT_PUSH_POWER: float = 0.0
const VILLAGER_CONTACT_PUSH_RESIST: float = 2.0
const VILLAGER_CONTACT_PUSH_COOLDOWN: float = 0.2
const VILLAGER_CONTACT_PUSH_FRICTION_LOSS: float = 0.995
const VILLAGER_CONTACT_CONTROL_SUPPRESSION_SECONDS: float = 0.1

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
	if agent is FlowAgent:
		var flow_agent: FlowAgent = agent as FlowAgent
		flow_agent.set_monster_sprite_frame_layout(data.sprite_frame_layout)
		flow_agent.set_monster_size_classification(data.is_small)
	else:
		agent.set_meta("monster_sprite_frame_layout", data.sprite_frame_layout)
		agent.set_meta("monster_is_small", data.is_small)
	# _ready() already ran (add_child), so override both the exported cap and the
	# live pool.
	agent.set("max_health", data.max_health)
	agent.set("health", data.max_health)
	# Catalogued monsters are the only damageable agents; every other
	# agent kind keeps the invincible default from character.gd.
	agent.set("invincible", false)
	agent.set("drownable", data.drownable)
	agent.set_meta("monster_speed_scale", data.speed_scale)
	agent.set_meta("monster_crowd_resist", data.crowd_resist_scale)
	agent.set_meta("agent_contact_push_power", data.contact_push_power)
	agent.set_meta("agent_contact_push_resist", data.contact_push_resist)
	agent.set_meta("agent_contact_push_cooldown", data.contact_push_cooldown)
	agent.set_meta("agent_contact_push_friction_loss", data.contact_push_friction_loss)
	agent.set_meta("agent_contact_control_suppression_seconds", data.contact_control_suppression_seconds)
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
	if agent is FlowAgent:
		(agent as FlowAgent).set_client_sprite_frame_layout(CLIENT_SPRITE_FRAME_LAYOUT)
	else:
		agent.set_meta("client_sprite_frame_layout", CLIENT_SPRITE_FRAME_LAYOUT)
	_mark_crushes_placeables(agent)


func apply_merchant_data(agent: Node) -> void:
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = MERCHANT_TEXTURE
		sprite.hframes = 4
		sprite.frame = 0
		sprite.flip_h = false
	_apply_villager_traits(agent)


## Inventor villager visuals. Identical frame layout / animation rules to the other ordinary
## villagers (same 4-frame directional sheet, default scale/offset/z-index from character.tscn);
## only the texture differs. Inherits person crushing via the generic crushes_placeables flag.
func apply_inventor_data(agent: Node) -> void:
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = INVENTOR_TEXTURE
		sprite.hframes = 4
		sprite.frame = 0
		sprite.flip_h = false
	_apply_villager_traits(agent)


## Sheep villager visuals. Same 4-frame directional sheet as the other ordinary villagers, but the
## sheep is deliberately NOT flagged crushes_placeables: it is the one villager that leaves its idle
## spot and walks the garden (to eat debris), so the shared flag would make it trample the player's
## roses. Its errand paths already refuse live-plant cells (see SheepGardenRole), and dropping the
## flag extends that guarantee to the paths the sheep does not choose itself — the controller-owned
## night return and house-destruction evacuation, which both use the plain walkable map.
func apply_sheep_data(agent: Node) -> void:
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = SHEEP_TEXTURE
		sprite.hframes = 4
		sprite.frame = 0
		sprite.flip_h = false
	_apply_villager_traits(agent, false)


func apply_builder_data(agent: Node) -> void:
	_apply_builder_visuals(agent, BUILDER_TEXTURE)


func apply_fundamental_builder_data(agent: Node) -> void:
	_apply_builder_visuals(agent, FUNDAMENTAL_BUILDER_TEXTURE)


func _apply_builder_visuals(agent: Node, texture: Texture2D) -> void:
	var sprite: Sprite2D = agent.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = texture
		sprite.hframes = 4
		sprite.frame = 0
		sprite.flip_h = false
	# The hammer is part of the Builder's permanent look; construction only swings it.
	if agent.has_method("set_held_object"):
		agent.call("set_held_object", BUILDER_HAMMER_TEXTURE, 1, 0, BUILDER_HAMMER_SCALE)
	_apply_villager_traits(agent)


## Shared villager identity/contact traits. `crushes_placeables` is a parameter because it is a
## behaviour rule rather than part of being a villager: every villager that only walks in and parks
## crushes, but the sheep wanders the garden and must not (see apply_sheep_data).
func _apply_villager_traits(agent: Node, crushes_placeables: bool = true) -> void:
	agent.add_to_group(VILLAGERS_GROUP)
	agent.set_meta("agent_contact_push_power", VILLAGER_CONTACT_PUSH_POWER)
	agent.set_meta("agent_contact_push_resist", VILLAGER_CONTACT_PUSH_RESIST)
	agent.set_meta("agent_contact_push_cooldown", VILLAGER_CONTACT_PUSH_COOLDOWN)
	agent.set_meta("agent_contact_push_friction_loss", VILLAGER_CONTACT_PUSH_FRICTION_LOSS)
	agent.set_meta("agent_contact_control_suppression_seconds", VILLAGER_CONTACT_CONTROL_SUPPRESSION_SECONDS)
	if crushes_placeables:
		_mark_crushes_placeables(agent)


## People (clients, merchant, builders, future villagers) crush placeables by walking over them.
## AgentTileInteractionController reads this per-agent flag instead of a hardcoded category list,
## so a new person-type agent inherits crushing purely from its definition. Monsters crush via
## their own category and are not flagged here.
func _mark_crushes_placeables(agent: Node) -> void:
	agent.set_meta("crushes_placeables", true)


func _apply_bigmonster_animation(agent: Node) -> void:
	var animation: CharacterAnimation = agent.get_node_or_null("characterAnimation") as CharacterAnimation
	if animation == null:
		return
	animation.bounce_height = BIG_MONSTER_BOUNCE_HEIGHT
	animation.walk_squash = BIG_MONSTER_WALK_SQUASH


func _debug_telemetry() -> BuildingDebugTelemetry:
	return _manager.get_building_debug_telemetry()
