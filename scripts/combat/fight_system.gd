extends Node
class_name FightSystem

const STATIC_COLLISION_TERRAIN: int = 1 << 0
const STATIC_COLLISION_REACTIVE_PLANT: int = 1 << 1
const STATIC_IMPACT_KIND: int = 0
const WATER_RESERVE_ID: StringName = &"water"
const WATER_RESERVE_KEY: StringName = &"water_reserve"
const WATER_RESERVE_MAX_KEY: StringName = &"water_reserve_max"
const SPRAY_SOUND: AudioStream = preload("res://assets/sfx/spray.wav")
const SPRAY_METABALL_SHADER: Shader = preload("res://scripts/combat/spray_metaball.gdshader")

@export var visualize_AOE_weapons: bool = true
# When off, projectiles are drawn in a single batched layer with no per-Y z
# sorting against agents (cheaper). When on, projectiles bucket by ground Y so
# they interleave correctly with agents.
@export var z_order_projectiles: bool = false
@export var weapons: Array[WeaponData] = [
	preload("res://scripts/combat/weapons/bomb.tres"),
	preload("res://scripts/combat/weapons/sword.tres"),
	preload("res://scripts/combat/weapons/spray.tres"),
	preload("res://scripts/combat/weapons/beam.tres"),
]
@export var guns: Array[GunData] = [
	preload("res://scripts/combat/weapons/water.tres"),
]

var _steering: Node
var _projectiles: Node
var _agent_manager: Node
var _building_manager: Node
var _plant_manager: Node
var _plant_layer: TileMapLayer
var _wall_layer: TileMapLayer
var _floor_layer: TileMapLayer
var _water_sources: WaterSources
var _player: Node2D
var _progression: Node
var _drawer
var _projectile_drawer
var _damage_number_drawer: DamageNumberDrawer
var _weapons_by_id: Dictionary = {}
var _guns_by_id: Dictionary = {}
var _gun_type_ids: Dictionary = {}
var _gun_by_type_id: Dictionary = {}  # type_id (int) -> GunData, for impact visuals
var _spray_type_ids: Dictionary = {}
var _spray_weapon_by_type_id: Dictionary = {}
var _gun_fire_timers: Dictionary = {}
var _water_refill_elapsed: float = 0.0
var _held_spray_weapon_id: String = ""
var _held_spray_facing: Vector2 = Vector2.RIGHT
var _held_spray_cost_time_left: float = 0.0
var _held_spray_fire_time_left: float = 0.0
var _spray_projectile_drawer
var _spray_audio_player: AudioStreamPlayer
# Per-turret spray instances: cell (Vector2i) -> {cost_time_left, fire_time_left,
# facing}. Turrets use the same projectile spray as the player.
var _turret_sprays: Dictionary = {}
var _static_colliders_dirty: bool = true
var _static_collider_prepare_generation: int = 0
var _paused: bool = false

func _ready() -> void:
	_steering = get_node_or_null("../CPP/SteeringSystemNative")
	_projectiles = get_node_or_null("../CPP/ProjectileSystemNative")
	_agent_manager = get_node_or_null("../CPP/AgentManagerNative")
	_building_manager = get_node_or_null("../Map/BuildingManager")
	_plant_manager = get_node_or_null("../Map/PlantManager")
	_plant_layer = get_node_or_null("../Map/MonTilemap/plantz") as TileMapLayer
	_wall_layer = get_node_or_null("../Map/MonTilemap/wallz") as TileMapLayer
	_floor_layer = get_node_or_null("../Map/MonTilemap/floor") as TileMapLayer
	_water_sources = get_node_or_null("../Map/MonTilemap/watersources") as WaterSources
	_player = get_node_or_null("../Player") as Node2D
	_progression = get_node_or_null("../progression")
	if _steering and not _steering.has_method("take_damage_events"):
		push_error("FightSystem: native damage API is unavailable. Rebuild the GDExtension and restart Godot.")
	_drawer = WeaponAOEDrawer.new()
	_drawer.setup(_steering)
	add_child(_drawer)
	_setup_spray_audio()
	_damage_number_drawer = DamageNumberDrawer.new()
	add_child(_damage_number_drawer)
	_rebuild_weapon_index()
	_register_spray_projectiles()
	_register_guns()
	_connect_static_collider_updates()
	GameState.mode_changed.connect(_on_game_mode_changed)
	if _projectiles:
		_projectile_drawer = ProjectileDrawer.new()
		_projectile_drawer.z_order_enabled = z_order_projectiles
		_projectile_drawer.setup(_projectiles, _guns_by_id, _gun_type_ids)
		add_child(_projectile_drawer)
	if _projectiles:
		_spray_projectile_drawer = SprayProjectileDrawer.new()
		_spray_projectile_drawer.setup(_projectiles, _spray_type_ids, _weapons_by_id, SPRAY_METABALL_SHADER)
		add_child(_spray_projectile_drawer)

func _on_game_mode_changed(is_night: bool) -> void:
	if is_night:
		return
	# Cancel a partially collected snapshot. A later night will restart from the
	# final daytime layers instead of publishing stale cells.
	_static_collider_prepare_generation += 1
	_static_colliders_dirty = true

func _process(_delta: float) -> void:
	if _paused:
		return
	_drain_projectile_impacts()
	_drain_damage_events()
	_water_roses_under_spray_projectiles()

func set_paused(paused: bool) -> void:
	_paused = paused
	if _projectiles and _projectiles.has_method("set_paused"):
		_projectiles.call("set_paused", paused)
	if paused:
		for raw_cell: Variant in _turret_sprays.keys():
			var cell: Vector2i = raw_cell as Vector2i
			stop_turret_spray(cell)

func is_paused() -> bool:
	return _paused

func _drain_damage_events() -> void:
	if not _steering or not _steering.has_method("take_damage_events") or not _agent_manager:
		return
	var events: Array = _steering.call("take_damage_events") as Array
	for event_variant: Variant in events:
		var event: Dictionary = event_variant as Dictionary
		var agent_id: int = int(event.get("agent_id", -1))
		var damage: int = int(event.get("damage", 0))
		if agent_id < 0 or damage <= 0:
			continue
		var enemy: Node2D = _agent_manager.call("find_node_by_agent", agent_id) as Node2D
		if not is_instance_valid(enemy) or not enemy.is_in_group("monsters") or not enemy.has_method("take_damage"):
			continue
		var number_position: Vector2 = event.get("position", enemy.global_position) as Vector2
		_damage_number_drawer.show_damage(number_position, damage)
		var died: bool = bool(enemy.call("take_damage", damage))
		Sfx.play_random_scream()
		if died:
			_remove_dead_enemy(enemy, agent_id)

func _water_roses_under_spray_projectiles() -> void:
	if not _projectiles or _spray_type_ids.is_empty() or not _plant_manager or not _plant_layer:
		return
	if not _plant_manager.has_method("is_rose_cell") or not _plant_manager.has_method("wet_rose"):
		return
	var checked_cells: Dictionary = {}
	for weapon_id_variant: Variant in _spray_type_ids.keys():
		var weapon: WeaponData = _weapons_by_id.get(str(weapon_id_variant)) as WeaponData
		if weapon == null or not weapon.spray_waters_reactive_plants:
			continue
		var type_id: int = int(_spray_type_ids[weapon_id_variant])
		var positions: PackedVector2Array = _projectiles.call("get_active_positions", type_id) as PackedVector2Array
		for droplet_pos: Vector2 in positions:
			var center_cell: Vector2i = _plant_layer.local_to_map(_plant_layer.to_local(droplet_pos))
			for y: int in range(center_cell.y - 1, center_cell.y + 2):
				for x: int in range(center_cell.x - 1, center_cell.x + 2):
					var cell: Vector2i = Vector2i(x, y)
					if checked_cells.has(cell):
						continue
					checked_cells[cell] = true
					if bool(_plant_manager.call("is_rose_cell", cell)):
						_plant_manager.call("wet_rose", cell)

func _remove_dead_enemy(enemy: Node2D, agent_id: int) -> void:
	_spawn_gem_harvest(enemy.global_position)
	if _building_manager and _building_manager.has_method("remove_dead_monster"):
		_building_manager.call("remove_dead_monster", enemy)
		return
	if _agent_manager and _agent_manager.has_method("unregister_agent"):
		_agent_manager.call("unregister_agent", agent_id)
	enemy.remove_from_group("monsters")
	enemy.queue_free()


func _spawn_gem_harvest(world_position: Vector2) -> void:
	Sfx.play_sound(&"gem")
	var scene: Node = get_tree().current_scene
	var gem_icon: Node = scene.get_node_or_null("GameUI/top right/gemIcon") if scene != null else null
	if gem_icon != null and gem_icon.has_method("animate_gem_harvest"):
		var animation_started: bool = bool(gem_icon.call("animate_gem_harvest", world_position))
		if animation_started:
			return
	var progression_node: Node = scene.get_node_or_null("progression") if scene != null else null
	if progression_node != null and progression_node.has_method("update_gems"):
		progression_node.call("update_gems", 1)

class DamageNumberDrawer:
	extends Node2D

	const LIFETIME: float = 0.65
	const RISE_SPEED: float = 26.0
	const FONT_SIZE: int = 14
	const DRAW_Z_INDEX: int = 4096

	var _positions: PackedVector2Array = PackedVector2Array()
	var _damages: PackedInt32Array = PackedInt32Array()
	var _times_left: PackedFloat32Array = PackedFloat32Array()

	func _ready() -> void:
		z_as_relative = false
		z_index = DRAW_Z_INDEX

	func show_damage(world_position: Vector2, damage: int) -> void:
		_positions.push_back(world_position + Vector2(0.0, -28.0))
		_damages.push_back(damage)
		_times_left.push_back(LIFETIME)
		queue_redraw()

	func _process(delta: float) -> void:
		var had_numbers: bool = not _positions.is_empty()
		for index: int in range(_positions.size() - 1, -1, -1):
			var number_position: Vector2 = _positions[index]
			number_position.y -= RISE_SPEED * delta
			_positions[index] = number_position
			_times_left[index] = _times_left[index] - delta
			if _times_left[index] <= 0.0:
				_remove_number_at(index)
		if had_numbers:
			queue_redraw()

	# Order is visually irrelevant, so swap-remove keeps expiry O(1) and avoids
	# shifting every later number during large bursts.
	func _remove_number_at(index: int) -> void:
		var last_index: int = _positions.size() - 1
		if index != last_index:
			_positions[index] = _positions[last_index]
			_damages[index] = _damages[last_index]
			_times_left[index] = _times_left[last_index]
		_positions.resize(last_index)
		_damages.resize(last_index)
		_times_left.resize(last_index)

	func _draw() -> void:
		var font: Font = ThemeDB.fallback_font
		for index: int in range(_positions.size()):
			var text_value: String = str(_damages[index])
			var number_position: Vector2 = _positions[index]
			var text_size: Vector2 = font.get_string_size(text_value, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
			var draw_position: Vector2 = number_position - Vector2(text_size.x * 0.5, 0.0)
			var alpha: float = min(1.0, _times_left[index] / 0.18)
			var outline_color: Color = Color(0.0, 0.0, 0.0, alpha)
			for offset: Vector2 in [Vector2(-1.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, -1.0), Vector2(0.0, 1.0)]:
				draw_string(font, draw_position + offset, text_value, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, outline_color)
			draw_string(font, draw_position, text_value, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(1.0, 1.0, 1.0, alpha))

# Drain this frame's projectile AoE impacts (wall/expiry/agent) from the native
# system and render each as a fading ring via the shared WeaponAOEDrawer. The
# native buffer holds events for exactly one update, so this must run every frame.
func _drain_projectile_impacts() -> void:
	if not _projectiles or not _projectiles.has_method("get_impacts"):
		return
	var impacts: Array = _projectiles.call("get_impacts") as Array
	if impacts.is_empty():
		return
	for impact_variant: Variant in impacts:
		var impact: Dictionary = impact_variant as Dictionary
		var type_id: int = int(impact.get("type_id", -1))
		var gun: GunData = _gun_by_type_id.get(type_id) as GunData
		var spray_weapon: WeaponData = _spray_weapon_by_type_id.get(type_id) as WeaponData
		if gun != null and gun.id == "water":
			Sfx.play_sound(&"splash")
		if gun != null:
			_handle_static_projectile_impact(impact, gun.id == "water")
		elif spray_weapon != null:
			_handle_static_projectile_impact(impact, spray_weapon.spray_waters_reactive_plants)
		if not gun or not gun.impact_visual_enabled:
			continue
		var pos: Vector2 = impact.get("pos", Vector2.ZERO) as Vector2
		var dir: Vector2 = impact.get("dir", Vector2.RIGHT) as Vector2
		var radius: float = float(impact.get("radius", 0.0))
		if radius <= 0.0 or gun.impact_display_duration <= 0.0:
			continue
		# The native impact is the GROUND point (shadow). The projectile sprite was
		# drawn lifted by altitude, so lift the ring the same amount to center it on
		# where the projectile visually was. impact_visual_offset is extra fine-tuning.
		var visual_pos: Vector2 = pos - Vector2(0.0, gun.projectile_altitude_px) + gun.impact_visual_offset
		# Impacts are world-anchored circles (owner_id = -1, angle = 360).
		_drawer.show_weapon_area(visual_pos, dir, radius, 360.0, gun.impact_display_duration, -1, Vector2.ZERO, gun.impact_fill_color, gun.impact_stroke_color, gun.impact_stroke_width)

func _handle_static_projectile_impact(impact: Dictionary, waters_plants: bool) -> void:
	if not waters_plants or not _plant_manager or not _plant_layer:
		return
	if int(impact.get("kind", -1)) != STATIC_IMPACT_KIND:
		return
	var collider_mask: int = int(impact.get("collider_mask", 0))
	if (collider_mask & STATIC_COLLISION_REACTIVE_PLANT) == 0:
		return
	var raw_collision_cell: Variant = impact.get("collider_cell", Vector2i.ZERO)
	if not raw_collision_cell is Vector2i:
		return
	var collision_cell: Vector2i = raw_collision_cell as Vector2i
	var rose_cell: Vector2i = _static_grid_cell_to_layer_cell(collision_cell, _plant_layer)
	if _plant_manager.has_method("is_rose_cell") and not bool(_plant_manager.call("is_rose_cell", rose_cell)):
		return
	if _plant_manager.has_method("wet_rose"):
		_plant_manager.call("wet_rose", rose_cell)

func _static_grid_cell_to_layer_cell(collision_cell: Vector2i, layer: TileMapLayer) -> Vector2i:
	var tile_size: float = 1.0
	if layer.tile_set:
		tile_size = maxf(1.0, float(layer.tile_set.tile_size.x))
	var world_center: Vector2 = Vector2(
		(float(collision_cell.x) + 0.5) * tile_size,
		(float(collision_cell.y) + 0.5) * tile_size
	)
	return layer.local_to_map(layer.to_local(world_center))

# Upload generic static collider channels. Atlas filtering keeps future non-rose
# plants out of the water-reactive channel.
func _upload_static_projectile_colliders() -> void:
	if not _projectiles or not _projectiles.has_method("set_static_collision_layers"):
		return
	if not _wall_layer:
		return
	var collider_configs: Array[Dictionary] = [
		{
			"layer": _wall_layer,
			"channel": STATIC_COLLISION_TERRAIN,
		},
	]
	if _plant_layer:
		collider_configs.append({
			"layer": _plant_layer,
			"channel": STATIC_COLLISION_REACTIVE_PLANT,
			"atlas_coords": [PlantManager.ROSE_DRY_ATLAS, PlantManager.ROSE_WET_ATLAS],
		})
	_projectiles.call("set_static_collision_layers", collider_configs, _floor_layer)

func _ensure_static_projectile_colliders_ready() -> void:
	if _static_colliders_dirty:
		_upload_static_projectile_colliders()
		_static_colliders_dirty = false

func _connect_static_collider_updates() -> void:
	if not _plant_manager:
		return
	var refresh_callback: Callable = Callable(self, "_on_plant_collision_cells_changed")
	if _plant_manager.has_signal("plant_added") and not _plant_manager.is_connected("plant_added", refresh_callback):
		_plant_manager.connect("plant_added", refresh_callback)
	if _plant_manager.has_signal("plant_removed") and not _plant_manager.is_connected("plant_removed", refresh_callback):
		_plant_manager.connect("plant_removed", refresh_callback)

func _on_plant_collision_cells_changed(_cell: Vector2i) -> void:
	# Daytime edits are accumulated. BuildingManager uploads the final snapshot
	# once during capped night preparation instead of once per placed rose.
	_static_colliders_dirty = true

func prepare_night_static_colliders() -> void:
	if not _static_colliders_dirty:
		return
	_upload_static_projectile_colliders()
	_static_colliders_dirty = false

func prepare_night_static_colliders_budgeted(budget_ms: float) -> bool:
	# Always snapshot at night start: walls do not emit PlantManager signals, so
	# `_static_colliders_dirty` alone cannot prove the wall channel is current.
	if not _projectiles or not _projectiles.has_method("set_static_collision_cells"):
		push_error("FightSystem: rebuilt ProjectileSystemNative is required for capped night preparation")
		return false
	_static_collider_prepare_generation += 1
	var generation: int = _static_collider_prepare_generation
	var budget_us: int = maxi(500, int(budget_ms * 1000.0))
	var slice_started_us: int = Time.get_ticks_usec()
	var tile_size: float = 1.0
	if _floor_layer and _floor_layer.tile_set:
		tile_size = maxf(1.0, float(_floor_layer.tile_set.tile_size.x))
	var cells: PackedVector2Array = PackedVector2Array()
	var channels: PackedInt32Array = PackedInt32Array()

	if _wall_layer:
		for wall_cell: Vector2i in _wall_layer.get_used_cells():
			if generation != _static_collider_prepare_generation:
				return false
			var wall_world: Vector2 = _wall_layer.to_global(_wall_layer.map_to_local(wall_cell))
			cells.append(Vector2(floorf(wall_world.x / tile_size), floorf(wall_world.y / tile_size)))
			channels.append(STATIC_COLLISION_TERRAIN)
			if Time.get_ticks_usec() - slice_started_us >= budget_us:
				await get_tree().process_frame
				slice_started_us = Time.get_ticks_usec()

	if _plant_layer:
		for plant_cell: Vector2i in _plant_layer.get_used_cells():
			if generation != _static_collider_prepare_generation:
				return false
			var atlas: Vector2i = _plant_layer.get_cell_atlas_coords(plant_cell)
			if atlas != PlantManager.ROSE_DRY_ATLAS and atlas != PlantManager.ROSE_WET_ATLAS:
				continue
			var plant_world: Vector2 = _plant_layer.to_global(_plant_layer.map_to_local(plant_cell))
			cells.append(Vector2(floorf(plant_world.x / tile_size), floorf(plant_world.y / tile_size)))
			channels.append(STATIC_COLLISION_REACTIVE_PLANT)
			if Time.get_ticks_usec() - slice_started_us >= budget_us:
				await get_tree().process_frame
				slice_started_us = Time.get_ticks_usec()

	_projectiles.call("set_static_collision_cells", cells, channels, tile_size)
	_static_colliders_dirty = false
	return true

# Public hook: re-upload walls after the build system adds/removes wall tiles.
func refresh_projectile_walls() -> void:
	_static_colliders_dirty = true
	if GameState.is_night:
		prepare_night_static_colliders()

func use_weapon(weapon_id: String, origin: Vector2, direction: Vector2, source_agent_id: int = -1, follow_offset: Vector2 = Vector2.ZERO) -> bool:
	var weapon: WeaponData = _weapon_by_id(weapon_id)
	if not weapon:
		return false
	var radius: float = weapon.radius
	var angle: float = weapon.directional_area_angle
	var duration: float = weapon.aoe_duration
	if radius <= 0.0 or duration <= 0.0:
		return false

	var facing: Vector2 = direction.normalized() if direction.length_squared() > 0.000001 else Vector2.RIGHT
	# The AoE zone (and its visual) re-anchor to the owner each frame as
	# agent_pos + follow_offset, so the throw offset must live in follow_offset —
	# baking it into the spawn position alone is overwritten on the next tick.
	var aoe_follow_offset: Vector2 = follow_offset
	if weapon.throw_offset != 0.0:
		aoe_follow_offset += facing * weapon.throw_offset
	var spawn_origin: Vector2 = origin + (aoe_follow_offset - follow_offset)
	if visualize_AOE_weapons and weapon.aoe_visual_enabled:
		_drawer.show_weapon_area(spawn_origin, facing, radius, angle, duration, source_agent_id, aoe_follow_offset, weapon.aoe_fill_color, weapon.aoe_stroke_color, weapon.aoe_stroke_width)

	if not _steering:
		return true

	if not _steering.has_method("spawn_aoe_zone"):
		return false

	_steering.call(
		"spawn_aoe_zone",
		spawn_origin,
		facing,
		radius,
		angle,
		duration,
		weapon.smash_force,
		weapon.friction,
		weapon.falloff,
		weapon.detach_flow,
		weapon.control_suppression,
		weapon.control_suppression_duration,
		source_agent_id,
		weapon.affected_smash_classes,
		aoe_follow_offset,
		weapon.damage
	)
	return true

func _rebuild_weapon_index() -> void:
	_weapons_by_id.clear()
	for weapon in weapons:
		if weapon and weapon.id != "":
			_weapons_by_id[weapon.id] = weapon

func _register_spray_projectiles() -> void:
	_spray_type_ids.clear()
	_spray_weapon_by_type_id.clear()
	if not _projectiles:
		return
	for weapon in weapons:
		if not weapon or weapon.id == "" or not weapon.spray_projectiles_enabled:
			continue
		var cfg: Dictionary = {
			"speed": weapon.spray_projectile_speed,
			"lifetime": weapon.spray_projectile_lifetime,
			"radius": weapon.spray_projectile_radius,
			"aoe_radius": weapon.spray_projectile_radius,
			"smash_force": weapon.smash_force,
			"smash_friction_loss": 1.0 - weapon.friction,
			"smash_falloff": weapon.falloff,
			"smash_detach_flow": weapon.detach_flow,
			"smash_control_suppression": weapon.control_suppression,
			"smash_control_suppression_duration": weapon.control_suppression_duration,
			"damage": weapon.spray_projectile_damage,
			"static_collision_mask": weapon.spray_projectile_static_collision_mask,
			"end_of_life_aoe_enabled": false,
			"pool_size": weapon.spray_projectile_pool_size,
		}
		var type_id: int = int(_projectiles.call("register_type", cfg))
		_spray_type_ids[weapon.id] = type_id
		_spray_weapon_by_type_id[type_id] = weapon

func _weapon_by_id(weapon_id: String) -> WeaponData:
	if _weapons_by_id.is_empty():
		_rebuild_weapon_index()
	return _weapons_by_id.get(weapon_id) as WeaponData

func is_gun(item_id: String) -> bool:
	return _guns_by_id.has(item_id)

func is_held_weapon(item_id: String) -> bool:
	if is_gun(item_id):
		return true
	var weapon: WeaponData = _weapon_by_id(item_id)
	return weapon != null and weapon.spray_projectiles_enabled

func get_spray_weapon_throw_offset(item_id: String) -> float:
	var weapon: WeaponData = _weapon_by_id(item_id)
	if weapon == null or not weapon.spray_projectiles_enabled:
		return 0.0
	return weapon.throw_offset

func _register_guns() -> void:
	_guns_by_id.clear()
	_gun_type_ids.clear()
	_gun_by_type_id.clear()
	if not _projectiles:
		return
	for gun in guns:
		if not gun or gun.id == "":
			continue
		_guns_by_id[gun.id] = gun
		var cfg: Dictionary = {
			"speed": gun.projectile_speed,
			"lifetime": gun.projectile_lifetime,
			"radius": gun.projectile_size * 0.5,
			"aoe_radius": gun.aoe_radius,
			"smash_force": gun.smash_force,
			"smash_friction_loss": gun.smash_friction_loss,
			"smash_falloff": gun.smash_falloff,
			"smash_detach_flow": gun.smash_detach_flow,
			"smash_control_suppression": gun.smash_control_suppression,
			"smash_control_suppression_duration": gun.smash_control_suppression_duration,
			"damage": gun.damage,
			"stopped_by_walls": gun.stopped_by_walls,
			"static_collision_mask": gun.static_collision_mask,
			"end_of_life_aoe_enabled": gun.end_of_life_aoe_enabled,
			"end_aoe_radius": gun.end_aoe_radius,
			"end_aoe_force": gun.end_aoe_force,
			"end_aoe_friction_loss": gun.end_aoe_friction_loss,
			"end_aoe_falloff": gun.end_aoe_falloff,
			"end_aoe_detach_flow": gun.end_aoe_detach_flow,
			"end_aoe_control_suppression": gun.end_aoe_control_suppression,
			"end_aoe_control_suppression_duration": gun.end_aoe_control_suppression_duration,
			"pool_size": gun.pool_size,
		}
		var type_id: int = int(_projectiles.call("register_type", cfg))
		_gun_type_ids[gun.id] = type_id
		_gun_by_type_id[type_id] = gun
		_gun_fire_timers[gun.id] = 0.0
	# If the drawer already exists (guns re-registered at runtime), rebuild its
	# cached per-type visual params. Otherwise _ready() builds it after this call.
	if _projectile_drawer:
		_projectile_drawer.rebuild_visual_cache()

## Called once per player frame. Water-source refill advances every frame, and
## a non-empty weapon id means the trigger is held for that weapon.
func process_held_weapon(weapon_id: String, origin: Vector2, direction: Vector2, source_agent_id: int, _follow_offset: Vector2, delta: float, source_velocity: Vector2 = Vector2.ZERO) -> void:
	_refill_water_reserve(delta)
	var gun: GunData = _guns_by_id.get(weapon_id) as GunData
	if gun != null:
		_stop_held_spray()
		fire_gun_held(weapon_id, origin, direction, source_agent_id, delta)
		return

	var weapon: WeaponData = _weapon_by_id(weapon_id)
	if weapon != null and weapon.spray_projectiles_enabled:
		_update_spray_projectile_weapon(weapon, origin, direction, source_agent_id, delta, source_velocity)
		return

	_stop_held_spray()

func _update_spray_projectile_weapon(weapon: WeaponData, origin: Vector2, direction: Vector2, source_agent_id: int, delta: float, source_velocity: Vector2) -> void:
	if not _projectiles or direction.length_squared() <= 0.000001:
		_stop_held_spray()
		return
	_ensure_static_projectile_colliders_ready()
	var type_id: int = int(_spray_type_ids.get(weapon.id, -1))
	if type_id < 0:
		_stop_held_spray()
		return
	if _held_spray_weapon_id != "" and _held_spray_weapon_id != weapon.id:
		_stop_held_spray()

	var facing: Vector2 = direction.normalized()
	var collision_facing: Vector2 = facing
	if _held_spray_weapon_id == "" or weapon.spray_aim_inertia <= 0.0:
		_held_spray_facing = facing
	else:
		var response: float = 1.0 - exp(-maxf(delta, 0.0) / weapon.spray_aim_inertia)
		var collision_angle: float = lerp_angle(_held_spray_facing.angle(), facing.angle(), response)
		_held_spray_facing = Vector2.from_angle(collision_angle)
		collision_facing = _held_spray_facing

	var spawn_origin: Vector2 = origin + facing * weapon.throw_offset
	if _held_spray_weapon_id == "":
		if not _spend_reserve(weapon.spray_reserve_id, weapon.spray_reserve_cost):
			return
		_held_spray_weapon_id = weapon.id
		_held_spray_cost_time_left = weapon.spray_reserve_cost_interval
		_held_spray_fire_time_left = 0.0
	else:
		_held_spray_cost_time_left -= delta
		while _held_spray_cost_time_left <= 0.0:
			if not _spend_reserve(weapon.spray_reserve_id, weapon.spray_reserve_cost):
				_stop_held_spray()
				return
			_held_spray_cost_time_left += maxf(weapon.spray_reserve_cost_interval, 0.001)

	_held_spray_fire_time_left = _advance_spray_projectile_emission(weapon, type_id, spawn_origin, collision_facing, source_agent_id, delta, _held_spray_fire_time_left, source_velocity)
	_start_spray_audio()

func _advance_spray_projectile_emission(weapon: WeaponData, type_id: int, origin: Vector2, facing: Vector2, source_agent_id: int, delta: float, fire_time_left: float, inherited_velocity: Vector2 = Vector2.ZERO) -> float:
	var rate: float = maxf(weapon.spray_projectiles_per_second, 0.001)
	var interval: float = 1.0 / rate
	var next_fire_time: float = fire_time_left - delta
	var guard: int = 0
	while next_fire_time <= 0.0 and guard < 8:
		_fire_one_spray_projectile(weapon, type_id, origin, facing, source_agent_id, inherited_velocity)
		next_fire_time += interval
		guard += 1
	return next_fire_time

func _fire_one_spray_projectile(weapon: WeaponData, type_id: int, origin: Vector2, facing: Vector2, source_agent_id: int, inherited_velocity: Vector2 = Vector2.ZERO) -> void:
	if not _projectiles:
		return
	var base_angle: float = facing.angle()
	var half_angle: float = deg_to_rad(weapon.directional_area_angle * 0.5)
	var jitter: float = deg_to_rad(weapon.spray_projectile_spread_jitter_degrees)
	var angle: float = base_angle + randf_range(-half_angle, half_angle) + randf_range(-jitter, jitter)
	var projectile_direction: Vector2 = Vector2.from_angle(angle)
	if _projectiles.has_method("fire_with_velocity"):
		_projectiles.call("fire_with_velocity", type_id, origin, projectile_direction, inherited_velocity, source_agent_id, weapon.affected_smash_classes)
	else:
		_projectiles.call("fire", type_id, origin, projectile_direction, source_agent_id, weapon.affected_smash_classes)

func _stop_held_spray() -> void:
	_stop_spray_audio()
	_held_spray_weapon_id = ""
	_held_spray_facing = Vector2.RIGHT
	_held_spray_cost_time_left = 0.0
	_held_spray_fire_time_left = 0.0

func _setup_spray_audio() -> void:
	_spray_audio_player = AudioStreamPlayer.new()
	_spray_audio_player.name = "SprayAudio"
	_spray_audio_player.stream = SPRAY_SOUND
	add_child(_spray_audio_player)

func _start_spray_audio() -> void:
	if _spray_audio_player != null and not _spray_audio_player.playing:
		_spray_audio_player.play()

func _stop_spray_audio() -> void:
	if _spray_audio_player != null:
		_spray_audio_player.stop()

# --- Turret spray (multi-instance) -----------------------------------------
# Turrets reuse the "spray" WeaponData and emit the same native projectiles as
# the player, but they keep their own aim/cost/fire timers.

func create_turret_spray(cell: Vector2i) -> void:
	if _turret_sprays.has(cell):
		return
	_turret_sprays[cell] = {
		"cost_time_left": 0.0,
		"fire_time_left": 0.0,
		"facing": Vector2.RIGHT,
	}

func remove_turret_spray(cell: Vector2i) -> void:
	var inst: Dictionary = _turret_sprays.get(cell) as Dictionary
	if inst == null:
		return
	_turret_sprays.erase(cell)

## Drive one turret's spray for a frame: spends water and emits low-density
## spray projectiles aimed along `direction`.
func update_turret_spray(cell: Vector2i, weapon_id: String, origin: Vector2, direction: Vector2, delta: float) -> void:
	var inst: Dictionary = _turret_sprays.get(cell) as Dictionary
	if inst == null:
		return
	var weapon: WeaponData = _weapon_by_id(weapon_id)
	if weapon == null or not weapon.spray_projectiles_enabled or not _projectiles:
		return
	if direction.length_squared() <= 0.000001:
		stop_turret_spray(cell)
		return
	_ensure_static_projectile_colliders_ready()
	var type_id: int = int(_spray_type_ids.get(weapon.id, -1))
	if type_id < 0:
		stop_turret_spray(cell)
		return

	var facing: Vector2 = direction.normalized()
	var inst_facing: Vector2 = inst.get("facing", facing) as Vector2
	var collision_facing: Vector2 = facing
	var was_idle: bool = float(inst.get("cost_time_left", 0.0)) <= 0.0 and float(inst.get("fire_time_left", 0.0)) <= 0.0
	if was_idle or weapon.spray_aim_inertia <= 0.0:
		inst_facing = facing
	else:
		var response: float = 1.0 - exp(-maxf(delta, 0.0) / weapon.spray_aim_inertia)
		var collision_angle: float = lerp_angle(inst_facing.angle(), facing.angle(), response)
		inst_facing = Vector2.from_angle(collision_angle)
		collision_facing = inst_facing
	inst["facing"] = inst_facing

	var spawn_origin: Vector2 = origin + facing * weapon.throw_offset
	if was_idle:
		if not _spend_reserve(weapon.spray_reserve_id, weapon.spray_reserve_cost):
			return
		inst["cost_time_left"] = weapon.spray_reserve_cost_interval
		inst["fire_time_left"] = 0.0
	else:
		var cost_left: float = float(inst.get("cost_time_left", 0.0)) - delta
		while cost_left <= 0.0:
			if not _spend_reserve(weapon.spray_reserve_id, weapon.spray_reserve_cost):
				stop_turret_spray(cell)
				return
			cost_left += maxf(weapon.spray_reserve_cost_interval, 0.001)
		inst["cost_time_left"] = cost_left

	var fire_time_left: float = float(inst.get("fire_time_left", 0.0))
	inst["fire_time_left"] = _advance_spray_projectile_emission(weapon, type_id, spawn_origin, collision_facing, -1, delta, fire_time_left)

## End a turret's spray burst. Already-fired droplets keep simulating normally.
func stop_turret_spray(cell: Vector2i) -> void:
	var inst: Dictionary = _turret_sprays.get(cell) as Dictionary
	if inst == null:
		return
	inst["cost_time_left"] = 0.0
	inst["fire_time_left"] = 0.0

func _spend_reserve(reserve_id: StringName, amount: int) -> bool:
	if reserve_id == &"" or amount <= 0:
		return true
	if reserve_id != WATER_RESERVE_ID or not _progression or not _progression.has_method("spend"):
		return false
	return bool(_progression.call("spend", WATER_RESERVE_KEY, amount))

func _refill_water_reserve(delta: float) -> void:
	if not _progression or not _progression.has_method("get_value"):
		return
	if not _player_is_above_water_source():
		_water_refill_elapsed = 0.0
		return
	var current: int = int(_progression.call("get_value", WATER_RESERVE_KEY))
	var maximum: int = int(_progression.call("get_value", WATER_RESERVE_MAX_KEY))
	if current >= maximum:
		_water_refill_elapsed = 0.0
		return
	if _water_sources == null:
		return
	var interval_seconds: float = maxf(_water_sources.refill_interval_seconds, 0.001)
	var refill_amount: int = maxi(0, _water_sources.refill_amount)
	if refill_amount <= 0:
		return
	_water_refill_elapsed += delta
	while _water_refill_elapsed >= interval_seconds and current < maximum:
		_water_refill_elapsed -= interval_seconds
		var added: int = mini(refill_amount, maximum - current)
		_update_water_reserve(added)
		current += added

func _player_is_above_water_source() -> bool:
	if _water_sources == null:
		return false
	if not is_instance_valid(_player):
		_player = get_node_or_null("../Player") as Node2D
	if _player == null:
		return false
	return _water_sources.has_water_at_foot_position(_player.global_position)

func _update_water_reserve(delta_value: int) -> void:
	if not _progression or not _progression.has_method("update_value"):
		return
	var maximum: int = int(_progression.call("get_value", WATER_RESERVE_MAX_KEY))
	_progression.call("update_value", WATER_RESERVE_KEY, delta_value, 0, maximum)

func fire_gun_held(gun_id: String, origin: Vector2, direction: Vector2, source_agent_id: int, delta: float) -> void:
	var gun: GunData = _guns_by_id.get(gun_id) as GunData
	if not gun or not _projectiles:
		return
	var t: float = float(_gun_fire_timers.get(gun_id, 0.0))
	t -= delta
	if t <= 0.0:
		var type_id: int = int(_gun_type_ids.get(gun_id, -1))
		if type_id >= 0 and _spend_reserve(gun.reserve_id, gun.reserve_cost):
			var spawn_pos: Vector2 = origin
			if gun.throw_offset != 0.0 and direction.length_squared() > 0.000001:
				spawn_pos += direction.normalized() * gun.throw_offset
			_projectiles.call("fire", type_id, spawn_pos, direction, source_agent_id, gun.affected_smash_classes)
			if gun.id == "water":
				Sfx.play_sound(&"bubble1")
			t = max(0.0, gun.fire_delay_ms * 0.001)
	_gun_fire_timers[gun_id] = t

func fire_gun_once(gun_id: String, origin: Vector2, direction: Vector2, source_agent_id: int = -1) -> bool:
	var gun: GunData = _guns_by_id.get(gun_id) as GunData
	if gun == null or not _projectiles or direction.length_squared() <= 0.000001:
		return false
	var type_id: int = int(_gun_type_ids.get(gun_id, -1))
	if type_id < 0:
		return false
	var facing: Vector2 = direction.normalized()
	var spawn_position: Vector2 = origin + facing * gun.throw_offset
	var fired: bool = bool(_projectiles.call("fire", type_id, spawn_position, facing, source_agent_id, gun.affected_smash_classes))
	if fired and gun.id == "water":
		Sfx.play_sound(&"bubble1")
	return fired

func reset_gun_cooldown(gun_id: String) -> void:
	if _gun_fire_timers.has(gun_id):
		_gun_fire_timers[gun_id] = 0.0

class WeaponAOEDrawer:
	extends Node2D

	var _areas: Array[Dictionary] = []
	var _persistent_areas: Dictionary = {}
	# Draw above every agent. Agents set z_index from their world Y
	# (z_index = int(position.y)), so an absolute z_index well past the world
	# height keeps AOE visuals on top regardless of where they spawn.
	const AOE_Z_INDEX: int = 4096

	# Fallback appearance, used only if a weapon supplies no visual override.
	const DEFAULT_FILL: Color = Color(1.0, 0.0, 0.0, 0.18)
	const DEFAULT_STROKE: Color = Color(1.0, 0.0, 0.0, 0.85)
	const DEFAULT_STROKE_WIDTH: float = 2.0
	var _steering: Node

	func setup(steering: Node) -> void:
		_steering = steering
		z_as_relative = false
		z_index = AOE_Z_INDEX

	func show_weapon_area(origin: Vector2, direction: Vector2, radius: float, angle_degrees: float, duration: float, owner_id: int = -1, follow_offset: Vector2 = Vector2.ZERO, fill_color: Color = DEFAULT_FILL, stroke_color: Color = DEFAULT_STROKE, stroke_width: float = DEFAULT_STROKE_WIDTH) -> void:
		if duration <= 0.0:
			return
		_areas.append({
			"origin": origin,
			"owner_id": owner_id,
			"follow_offset": follow_offset,
			"direction": direction.normalized() if direction.length_squared() > 0.000001 else Vector2.RIGHT,
			"radius": radius,
			"angle": angle_degrees,
			"time_left": duration,
			"fill": fill_color,
			"stroke": stroke_color,
			"stroke_width": stroke_width,
		})
		queue_redraw()

	func set_persistent_weapon_area(key: String, origin: Vector2, direction: Vector2, radius: float, angle_degrees: float, owner_id: int = -1, follow_offset: Vector2 = Vector2.ZERO, fill_color: Color = DEFAULT_FILL, stroke_color: Color = DEFAULT_STROKE, stroke_width: float = DEFAULT_STROKE_WIDTH) -> void:
		_persistent_areas[key] = {
			"origin": origin,
			"owner_id": owner_id,
			"follow_offset": follow_offset,
			"direction": direction.normalized() if direction.length_squared() > 0.000001 else Vector2.RIGHT,
			"radius": radius,
			"angle": angle_degrees,
			"fill": fill_color,
			"stroke": stroke_color,
			"stroke_width": stroke_width,
		}
		queue_redraw()

	func clear_persistent_weapon_area(key: String) -> void:
		if _persistent_areas.erase(key):
			queue_redraw()

	func _process(delta: float) -> void:
		var changed: bool = false
		for i in range(_areas.size() - 1, -1, -1):
			_areas[i]["time_left"] = float(_areas[i]["time_left"]) - delta
			if float(_areas[i]["time_left"]) <= 0.0:
				_areas.remove_at(i)
				changed = true
		if changed or not _areas.is_empty() or not _persistent_areas.is_empty():
			queue_redraw()

	func _draw() -> void:
		for area: Dictionary in _areas:
			_draw_area(area)
		for area_variant: Variant in _persistent_areas.values():
			var area: Dictionary = area_variant as Dictionary
			_draw_area(area)

	func _draw_area(area: Dictionary) -> void:
		var origin: Vector2 = area["origin"] as Vector2
		# Follow the owning agent's live position so the cone tracks the player.
		# Falls back to the captured origin when there is no valid owner.
		var owner_id: int = int(area.get("owner_id", -1))
		if owner_id >= 0 and _steering:
			origin = _steering.get_agent_position(owner_id) + (area.get("follow_offset", Vector2.ZERO) as Vector2)
		var radius: float = float(area["radius"])
		var angle: float = float(area["angle"])
		var direction: Vector2 = area["direction"] as Vector2
		var fill: Color = area.get("fill", DEFAULT_FILL) as Color
		var stroke: Color = area.get("stroke", DEFAULT_STROKE) as Color
		var stroke_width: float = float(area.get("stroke_width", DEFAULT_STROKE_WIDTH))
		if angle >= 359.9:
			draw_circle(origin, radius, fill)
			draw_arc(origin, radius, 0.0, TAU, 64, stroke, stroke_width)
		else:
			_draw_cone(origin, direction, radius, angle, fill, stroke, stroke_width)

	func _draw_cone(origin: Vector2, direction: Vector2, radius: float, angle_degrees: float, fill: Color, stroke: Color, stroke_width: float) -> void:
		var points: PackedVector2Array = PackedVector2Array()
		points.append(origin)
		var base_angle: float = direction.angle()
		var half_angle: float = deg_to_rad(angle_degrees * 0.5)
		var steps: int = max(6, int(ceil(angle_degrees / 8.0)))
		for i in range(steps + 1):
			var t: float = float(i) / float(steps)
			var a: float = base_angle - half_angle + half_angle * 2.0 * t
			points.append(origin + Vector2(cos(a), sin(a)) * radius)
		draw_colored_polygon(points, fill)
		for i in range(points.size()):
			draw_line(points[i], points[(i + 1) % points.size()], stroke, stroke_width)

class SprayProjectileDrawer:
	extends Node2D

	const MAX_DROPLETS: int = 128
	const DRAW_Z_INDEX: int = 4096

	var _projectile_system: Node
	var _spray_type_ids: Dictionary = {}
	var _weapons_by_id: Dictionary = {}
	var _material: ShaderMaterial
	var _fallback_shader: Shader
	var _active_shader: Shader
	var _shader_points: Array = []
	var _shader_radii: PackedFloat32Array = PackedFloat32Array()
	var _draw_bounds: Rect2 = Rect2()
	var _has_points: bool = false

	func setup(projectile_system: Node, spray_type_ids: Dictionary, weapons_by_id: Dictionary, shader: Shader) -> void:
		_projectile_system = projectile_system
		_spray_type_ids = spray_type_ids
		_weapons_by_id = weapons_by_id
		z_as_relative = false
		z_index = DRAW_Z_INDEX
		_material = ShaderMaterial.new()
		_fallback_shader = shader
		_set_shader(shader)
		material = _material
		_shader_points.resize(MAX_DROPLETS)
		for index: int in range(MAX_DROPLETS):
			_shader_points[index] = Vector2.ZERO
		_shader_radii.resize(MAX_DROPLETS)
		for index: int in range(MAX_DROPLETS):
			_shader_radii[index] = 0.0
		_material.set_shader_parameter("droplet_count", 0)
		_material.set_shader_parameter("droplets", _shader_points)
		_material.set_shader_parameter("droplet_radii", _shader_radii)

	func _process(_delta: float) -> void:
		if not _projectile_system or _material == null:
			return
		var point_count: int = 0
		var min_pos: Vector2 = Vector2.ZERO
		var max_pos: Vector2 = Vector2.ZERO
		var active_weapon: WeaponData = null
		for weapon_id_variant: Variant in _spray_type_ids.keys():
			if point_count >= MAX_DROPLETS:
				break
			var weapon_id: String = str(weapon_id_variant)
			var type_id: int = int(_spray_type_ids[weapon_id])
			var weapon: WeaponData = _weapons_by_id.get(weapon_id) as WeaponData
			var projectile_states: Array = _get_spray_projectile_states(type_id)
			if projectile_states.is_empty():
				continue
			if active_weapon == null:
				active_weapon = weapon
			for state_variant: Variant in projectile_states:
				if point_count >= MAX_DROPLETS:
					break
				var state: Dictionary = state_variant as Dictionary
				var droplet_pos: Vector2 = state.get("position", Vector2.ZERO) as Vector2
				var age_progress: float = clampf(float(state.get("age_progress", 1.0)), 0.0, 1.0)
				_shader_points[point_count] = droplet_pos
				_shader_radii[point_count] = _get_spray_visual_radius(weapon, age_progress)
				if point_count == 0:
					min_pos = droplet_pos
					max_pos = droplet_pos
				else:
					min_pos.x = minf(min_pos.x, droplet_pos.x)
					min_pos.y = minf(min_pos.y, droplet_pos.y)
					max_pos.x = maxf(max_pos.x, droplet_pos.x)
					max_pos.y = maxf(max_pos.y, droplet_pos.y)
				point_count += 1

		_has_points = point_count > 0
		var shader: Shader = _fallback_shader
		if active_weapon != null and active_weapon.spray_visual_shader != null:
			shader = active_weapon.spray_visual_shader
		_set_shader(shader)
		_material.set_shader_parameter("droplet_count", point_count)
		_material.set_shader_parameter("droplets", _shader_points)
		_material.set_shader_parameter("droplet_radii", _shader_radii)
		if active_weapon != null:
			_material.set_shader_parameter("radius_px", active_weapon.spray_visual_radius)
			_material.set_shader_parameter("threshold", active_weapon.spray_visual_threshold)
			_material.set_shader_parameter("softness", active_weapon.spray_visual_softness)
		if _has_points:
			var padding: float = 52.0
			if active_weapon != null:
				padding = active_weapon.spray_visual_radius * 4.0
			_draw_bounds = Rect2(min_pos - Vector2(padding, padding), (max_pos - min_pos) + Vector2(padding * 2.0, padding * 2.0))
		queue_redraw()

	func _set_shader(shader: Shader) -> void:
		if shader == null or _active_shader == shader:
			return
		_active_shader = shader
		_material.shader = shader

	func _get_spray_projectile_states(type_id: int) -> Array:
		var states: Array = []
		if _projectile_system.has_method("get_active_projectile_states"):
			states = _projectile_system.call("get_active_projectile_states", type_id) as Array
		else:
			var positions: PackedVector2Array = _projectile_system.call("get_active_positions", type_id) as PackedVector2Array
			for projectile_position: Vector2 in positions:
				states.append({
					"position": projectile_position,
					"age_progress": 1.0,
				})
		return states

	func _get_spray_visual_radius(weapon: WeaponData, age_progress: float) -> float:
		if weapon == null:
			return 0.0
		var full_radius: float = maxf(weapon.spray_visual_radius, 0.0)
		if not weapon.spray_visual_projectiles_grow:
			return full_radius
		var min_radius: float = clampf(weapon.spray_visual_min_size, 0.0, full_radius)
		return lerpf(min_radius, full_radius, age_progress)

	func _draw() -> void:
		if not _has_points:
			return
		draw_rect(_draw_bounds, Color.WHITE, true)

class ProjectileDrawer:
	extends Node2D

	# Z-ordering strategy
	# ------------------------------------------------------------------
	# Agents set `z_index = int(world_position.y)` (z_as_relative left at its
	# default, i.e. absolute against siblings sharing the parent). To interleave
	# projectiles correctly with agents we must render each projectile at a
	# z_index derived from its GROUND Y as well.
	#
	# A single CanvasItem only has one z_index, so we render through a small pool
	# of "bucket" CanvasItems. Each bucket owns a fixed z_index band and batches
	# every projectile whose ground Y falls in that band into a single _draw().
	# Buckets are pooled and reused frame to frame; in steady state no nodes are
	# created and the draw loop performs no per-projectile allocation.
	#
	# BUCKET_HEIGHT_PX controls vertical sorting granularity vs. bucket count.
	# 8px keeps ordering tight while keeping the active bucket set small.
	const BUCKET_HEIGHT_PX: int = 8

	# When false, all projectiles are drawn in this single CanvasItem with no
	# per-Y sorting against agents (cheapest). When true, projectiles bucket by
	# ground Y into ordered child CanvasItems so they interleave with agents.
	var z_order_enabled: bool = false

	var _projectile_system: Node
	var _guns_by_id: Dictionary = {}
	var _gun_type_ids: Dictionary = {}

	# Per-type cached visual params (built once at setup; rebuilt only when guns
	# change). Each entry is a Dictionary so the draw loop performs no resource
	# lookups, no texture loads and no allocations.
	# tid -> {
	#   tex, half_size:Vector2, sprite_offset:Vector2,
	#   altitude:float, shadow_enabled:bool, shadow_color:Color,
	#   shadow_size:Vector2, shadow_half:Vector2, shadow_offset:Vector2,
	#   shadow_tex, shadow_tex_offset:Vector2
	# }
	var _visual_by_type: Dictionary = {}

	# Pool of bucket CanvasItems. band -> Bucket (active this frame).
	var _buckets_by_band: Dictionary = {}
	# Free list of reusable Bucket nodes detached from any band.
	var _free_buckets: Array = []

	# Flat fast-path scratch (z_order_enabled == false): reused, never reallocated.
	var _flat_tids: PackedInt32Array = PackedInt32Array()
	var _flat_grounds: PackedVector2Array = PackedVector2Array()

	class Bucket:
		extends Node2D
		# Parallel draw lists for this z band, refilled each frame. Using packed
		# arrays (cleared, not reallocated) means the gather/draw loops perform no
		# per-projectile heap allocation.
		var tids: PackedInt32Array = PackedInt32Array()
		var grounds: PackedVector2Array = PackedVector2Array()
		var drawer_ref: Node  # back-ref to drawer for cached params

		func clear_items() -> void:
			tids.clear()
			grounds.clear()

		func is_empty() -> bool:
			return tids.is_empty()

		func push(tid: int, ground: Vector2) -> void:
			tids.push_back(tid)
			grounds.push_back(ground)

		func _draw() -> void:
			var drawer: ProjectileDrawer = drawer_ref as ProjectileDrawer
			if not drawer:
				return
			ProjectileDrawer.paint_batch(self, drawer._visual_by_type, tids, grounds)

	# Shared batched paint for one CanvasItem: shadows first (floor), then sprites
	# lifted by altitude. Used by both the per-Y buckets and the flat fast path.
	static func paint_batch(ci: CanvasItem, visuals: Dictionary, tids: PackedInt32Array, grounds: PackedVector2Array) -> void:
		var n: int = tids.size()
		# Pass 1: shadows (always on the floor, drawn first so sprites sit on top).
		for i in range(n):
			var v: Dictionary = visuals[tids[i]]
			if not bool(v["shadow_enabled"]):
				continue
			var ground: Vector2 = grounds[i]
			var shadow_color: Color = v["shadow_color"]
			var shadow_tex: Texture2D = v["shadow_tex"] as Texture2D
			if shadow_tex:
				var stex_offset: Vector2 = v["shadow_tex_offset"]
				ci.draw_texture(shadow_tex, ground + stex_offset, shadow_color)
			else:
				var shadow_offset: Vector2 = v["shadow_offset"]
				var sh: Vector2 = v["shadow_half"]
				_paint_oval(ci, ground + shadow_offset, sh, shadow_color)
		# Pass 2: sprites, lifted by altitude. Ordering comes from the CanvasItem's
		# z band (ground Y), not this lifted position.
		for i in range(n):
			var v2: Dictionary = visuals[tids[i]]
			var tex: Texture2D = v2["tex"] as Texture2D
			if not tex:
				continue
			var sprite_offset: Vector2 = v2["sprite_offset"]
			var altitude: float = float(v2["altitude"])
			var half_size: Vector2 = v2["half_size"]
			var top_left: Vector2 = grounds[i] + sprite_offset
			top_left.y -= altitude
			ci.draw_texture_rect(tex, Rect2(top_left, half_size * 2.0), false)

	static func _paint_oval(ci: CanvasItem, center: Vector2, half: Vector2, color: Color) -> void:
		# Cheap procedural oval via a unit circle scaled by the shadow half-extents.
		var pts: PackedVector2Array = PackedVector2Array()
		var steps: int = 12
		pts.resize(steps)
		for i in range(steps):
			var a: float = TAU * float(i) / float(steps)
			pts[i] = center + Vector2(cos(a) * half.x, sin(a) * half.y)
		ci.draw_colored_polygon(pts, color)

	func setup(projectile_system: Node, guns_by_id: Dictionary, gun_type_ids: Dictionary) -> void:
		_projectile_system = projectile_system
		_guns_by_id = guns_by_id
		_gun_type_ids = gun_type_ids
		z_as_relative = false
		rebuild_visual_cache()

	# Rebuild cached visual/shadow params per projectile type. Call only when gun
	# definitions change (registration time), never per frame.
	func rebuild_visual_cache() -> void:
		_visual_by_type.clear()
		for gun_id in _gun_type_ids.keys():
			var gun: GunData = _guns_by_id[gun_id] as GunData
			if not gun:
				continue
			var tid: int = int(_gun_type_ids[gun_id])
			var half: float = gun.projectile_size * 0.5
			var shadow_half: Vector2 = gun.projectile_shadow_size * 0.5
			var shadow_tex: Texture2D = gun.projectile_shadow_texture
			var shadow_tex_offset: Vector2 = Vector2.ZERO
			if shadow_tex:
				shadow_tex_offset = gun.projectile_shadow_offset - shadow_tex.get_size() * 0.5
			_visual_by_type[tid] = {
				"tex": gun.projectile_sprite,
				"half_size": Vector2(half, half),
				"sprite_offset": Vector2(-half, -half),
				"altitude": gun.projectile_altitude_px,
				"shadow_enabled": gun.projectile_shadow_enabled,
				"shadow_color": gun.projectile_shadow_color,
				"shadow_size": gun.projectile_shadow_size,
				"shadow_half": shadow_half,
				"shadow_offset": gun.projectile_shadow_offset,
				"shadow_tex": shadow_tex,
				"shadow_tex_offset": shadow_tex_offset,
			}

	func _process(_delta: float) -> void:
		if not _projectile_system:
			return
		if not z_order_enabled:
			_process_flat()
			return
		_process_z_ordered()

	# Fast path: no per-Y sorting. Gather all active projectiles into the shared
	# scratch arrays and paint them in this single CanvasItem's _draw().
	func _process_flat() -> void:
		_flat_tids.clear()
		_flat_grounds.clear()
		for tid_key in _visual_by_type.keys():
			var tid: int = int(tid_key)
			var positions: PackedVector2Array = _projectile_system.call("get_active_positions", tid)
			for p in positions:
				_flat_tids.push_back(tid)
				_flat_grounds.push_back(p)
		queue_redraw()

	func _draw() -> void:
		# Only the flat fast path draws here; z-ordered mode draws in buckets.
		if z_order_enabled:
			return
		paint_batch(self, _visual_by_type, _flat_tids, _flat_grounds)

	func _process_z_ordered() -> void:
		# Clear last frame's item lists (kept, not freed, to avoid reallocation).
		for band_key in _buckets_by_band.keys():
			(_buckets_by_band[band_key] as Bucket).clear_items()

		# Bucket every active projectile by its ground-Y band.
		for tid_key in _visual_by_type.keys():
			var tid: int = int(tid_key)
			var positions: PackedVector2Array = _projectile_system.call("get_active_positions", tid)
			for p in positions:
				var band: int = int(floor(p.y / float(BUCKET_HEIGHT_PX)))
				var bucket: Bucket = _bucket_for_band(band)
				bucket.push(tid, p)

		# Recycle buckets that ended up empty this frame; redraw the rest.
		var empty_bands: Array = []
		for band_key in _buckets_by_band.keys():
			var b: Bucket = _buckets_by_band[band_key] as Bucket
			if b.is_empty():
				empty_bands.append(band_key)
			else:
				b.queue_redraw()
		for band_key in empty_bands:
			var freed: Bucket = _buckets_by_band[band_key] as Bucket
			freed.queue_redraw()  # repaint empty (clears stale visuals)
			_buckets_by_band.erase(band_key)
			_free_buckets.append(freed)

	func _bucket_for_band(band: int) -> Bucket:
		var existing = _buckets_by_band.get(band)
		if existing:
			return existing as Bucket
		var bucket: Bucket
		if _free_buckets.is_empty():
			bucket = Bucket.new()
			bucket.drawer_ref = self
			bucket.z_as_relative = false
			add_child(bucket)
		else:
			bucket = _free_buckets.pop_back() as Bucket
		# Center the band so a projectile at ground Y sorts against an agent whose
		# z_index = int(agent.y): use the band's center pixel as the z_index.
		bucket.z_index = band * BUCKET_HEIGHT_PX + (BUCKET_HEIGHT_PX >> 1)
		_buckets_by_band[band] = bucket
		return bucket
