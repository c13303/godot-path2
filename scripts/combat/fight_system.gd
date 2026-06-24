extends Node
class_name FightSystem

const STATIC_COLLISION_TERRAIN: int = 1 << 0
const STATIC_COLLISION_REACTIVE_PLANT: int = 1 << 1
const STATIC_IMPACT_KIND: int = 0
const WATER_RESERVE_ID: StringName = &"water"
const WATER_RESERVE_KEY: StringName = &"water_reserve"
const WATER_RESERVE_MAX_KEY: StringName = &"water_reserve_max"
const WATER_REFILL_AMOUNT_KEY: StringName = &"water_refill_amount"
const WATER_REFILL_INTERVAL_MS_KEY: StringName = &"water_refill_interval_ms"

@export var visualize_AOE_weapons: bool = true
# When off, projectiles are drawn in a single batched layer with no per-Y z
# sorting against agents (cheaper). When on, projectiles bucket by ground Y so
# they interleave correctly with agents.
@export var z_order_projectiles: bool = false
@export var weapons: Array[WeaponData] = [
	preload("res://scripts/combat/weapons/bomb.tres"),
	preload("res://scripts/combat/weapons/sword.tres"),
	preload("res://scripts/combat/weapons/spray.tres"),
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
var _progression: Node
var _drawer
var _projectile_drawer
var _damage_number_drawer: DamageNumberDrawer
var _weapons_by_id: Dictionary = {}
var _guns_by_id: Dictionary = {}
var _gun_type_ids: Dictionary = {}
var _gun_by_type_id: Dictionary = {}  # type_id (int) -> GunData, for impact visuals
var _gun_fire_timers: Dictionary = {}
var _water_refill_elapsed: float = 0.0
var _continuous_aoe_id: int = -1
var _continuous_weapon_id: String = ""
var _continuous_cost_time_left: float = 0.0
var _continuous_sound_id: StringName = &""

func _ready() -> void:
	_steering = get_node_or_null("../CPP/SteeringSystemNative")
	_projectiles = get_node_or_null("../CPP/ProjectileSystemNative")
	_agent_manager = get_node_or_null("../CPP/AgentManagerNative")
	_building_manager = get_node_or_null("../Map/BuildingManager")
	_plant_manager = get_node_or_null("../Map/PlantManager")
	_plant_layer = get_node_or_null("../Map/MonTilemap/plantz") as TileMapLayer
	_wall_layer = get_node_or_null("../Map/MonTilemap/wallz") as TileMapLayer
	_floor_layer = get_node_or_null("../Map/MonTilemap/floor") as TileMapLayer
	_progression = get_node_or_null("../progression")
	if _steering and not _steering.has_method("take_damage_events"):
		push_error("FightSystem: native damage API is unavailable. Rebuild the GDExtension and restart Godot.")
	_drawer = WeaponAOEDrawer.new()
	_drawer.setup(_steering)
	add_child(_drawer)
	_damage_number_drawer = DamageNumberDrawer.new()
	add_child(_damage_number_drawer)
	_rebuild_weapon_index()
	_register_guns()
	_connect_static_collider_updates()
	_upload_static_projectile_colliders()
	if _projectiles:
		_projectile_drawer = ProjectileDrawer.new()
		_projectile_drawer.z_order_enabled = z_order_projectiles
		_projectile_drawer.setup(_projectiles, _guns_by_id, _gun_type_ids)
		add_child(_projectile_drawer)

func _process(_delta: float) -> void:
	_drain_projectile_impacts()
	_drain_damage_events()

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
		var gun: GunData = _gun_by_type_id.get(int(impact.get("type_id", -1))) as GunData
		if gun != null and gun.id == "water":
			Sfx.play_sound(&"splash")
		_handle_static_projectile_impact(impact, gun)
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

func _handle_static_projectile_impact(impact: Dictionary, gun: GunData) -> void:
	if not gun or gun.id != "water" or not _plant_manager or not _plant_layer:
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

func _connect_static_collider_updates() -> void:
	if not _plant_manager:
		return
	var refresh_callback: Callable = Callable(self, "_on_plant_collision_cells_changed")
	if _plant_manager.has_signal("plant_added") and not _plant_manager.is_connected("plant_added", refresh_callback):
		_plant_manager.connect("plant_added", refresh_callback)
	if _plant_manager.has_signal("plant_removed") and not _plant_manager.is_connected("plant_removed", refresh_callback):
		_plant_manager.connect("plant_removed", refresh_callback)

func _on_plant_collision_cells_changed(_cell: Vector2i) -> void:
	_upload_static_projectile_colliders()

# Public hook: re-upload walls after the build system adds/removes wall tiles.
func refresh_projectile_walls() -> void:
	_upload_static_projectile_colliders()

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
	return weapon != null and weapon.continuous

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

## Called once per player frame. A non-empty weapon id means the trigger is held
## for that weapon; an empty id stops channelled weapons and advances refill.
func process_held_weapon(weapon_id: String, origin: Vector2, direction: Vector2, source_agent_id: int, follow_offset: Vector2, delta: float) -> void:
	var gun: GunData = _guns_by_id.get(weapon_id) as GunData
	if gun != null:
		_stop_continuous_weapon()
		if gun.reserve_id == WATER_RESERVE_ID:
			_water_refill_elapsed = 0.0
		else:
			_refill_water_reserve(delta)
		fire_gun_held(weapon_id, origin, direction, source_agent_id, delta)
		return

	var weapon: WeaponData = _weapon_by_id(weapon_id)
	if weapon != null and weapon.continuous:
		if weapon.reserve_id == WATER_RESERVE_ID:
			_water_refill_elapsed = 0.0
		else:
			_refill_water_reserve(delta)
		_update_continuous_weapon(weapon, origin, direction, source_agent_id, follow_offset, delta)
		return

	_stop_continuous_weapon()
	_refill_water_reserve(delta)

func _update_continuous_weapon(weapon: WeaponData, origin: Vector2, direction: Vector2, source_agent_id: int, follow_offset: Vector2, delta: float) -> void:
	if not _steering or not _steering.has_method("start_continuous_aoe") or direction.length_squared() <= 0.000001:
		_stop_continuous_weapon()
		return
	if _continuous_weapon_id != "" and _continuous_weapon_id != weapon.id:
		_stop_continuous_weapon()

	var facing: Vector2 = direction.normalized()
	var aoe_follow_offset: Vector2 = follow_offset + facing * weapon.throw_offset
	var spawn_origin: Vector2 = origin + facing * weapon.throw_offset
	if _continuous_aoe_id < 0:
		if not _spend_reserve(weapon.reserve_id, weapon.reserve_cost):
			return
		var started_id: int = int(_steering.call(
			"start_continuous_aoe",
			spawn_origin,
			facing,
			weapon.radius,
			weapon.directional_area_angle,
			weapon.smash_force,
			weapon.friction,
			weapon.falloff,
			weapon.detach_flow,
			weapon.control_suppression,
			weapon.control_suppression_duration,
			source_agent_id,
			weapon.affected_smash_classes,
			aoe_follow_offset,
			weapon.damage,
			weapon.hit_frequency
		))
		if started_id < 0:
			_refund_reserve(weapon.reserve_id, weapon.reserve_cost)
			return
		_continuous_aoe_id = started_id
		_continuous_weapon_id = weapon.id
		_continuous_cost_time_left = weapon.reserve_cost_interval
		_continuous_sound_id = weapon.continuous_sound
		if _continuous_sound_id != &"":
			Sfx.play_sound(_continuous_sound_id)
	else:
		_continuous_cost_time_left -= delta
		while _continuous_cost_time_left <= 0.0:
			if not _spend_reserve(weapon.reserve_id, weapon.reserve_cost):
				_stop_continuous_weapon()
				return
			_continuous_cost_time_left += maxf(weapon.reserve_cost_interval, 0.001)
		var updated: bool = bool(_steering.call("update_continuous_aoe", _continuous_aoe_id, facing, aoe_follow_offset))
		if not updated:
			_stop_continuous_weapon()
			return

	if visualize_AOE_weapons and weapon.aoe_visual_enabled:
		_drawer.set_persistent_weapon_area(weapon.id, spawn_origin, facing, weapon.radius, weapon.directional_area_angle, source_agent_id, aoe_follow_offset, weapon.aoe_fill_color, weapon.aoe_stroke_color, weapon.aoe_stroke_width)
	if weapon.waters_reactive_plants:
		_water_plants_in_cone(spawn_origin, facing, weapon.radius, weapon.directional_area_angle)

func _stop_continuous_weapon() -> void:
	if _continuous_aoe_id >= 0 and _steering and _steering.has_method("stop_continuous_aoe"):
		_steering.call("stop_continuous_aoe", _continuous_aoe_id)
	if _continuous_weapon_id != "" and _drawer:
		_drawer.clear_persistent_weapon_area(_continuous_weapon_id)
	if _continuous_sound_id != &"" and Sfx.has_method("stop_sound"):
		Sfx.stop_sound(_continuous_sound_id)
	_continuous_aoe_id = -1
	_continuous_weapon_id = ""
	_continuous_cost_time_left = 0.0
	_continuous_sound_id = &""

func _spend_reserve(reserve_id: StringName, amount: int) -> bool:
	if reserve_id == &"" or amount <= 0:
		return true
	if reserve_id != WATER_RESERVE_ID or not _progression or not _progression.has_method("spend"):
		return false
	return bool(_progression.call("spend", WATER_RESERVE_KEY, amount))

func _refund_reserve(reserve_id: StringName, amount: int) -> void:
	if reserve_id != WATER_RESERVE_ID or amount <= 0:
		return
	_update_water_reserve(amount)

func _refill_water_reserve(delta: float) -> void:
	if not _progression or not _progression.has_method("get_value"):
		return
	var current: int = int(_progression.call("get_value", WATER_RESERVE_KEY))
	var maximum: int = int(_progression.call("get_value", WATER_RESERVE_MAX_KEY))
	if current >= maximum:
		_water_refill_elapsed = 0.0
		return
	var interval_ms: int = maxi(1, int(_progression.call("get_value", WATER_REFILL_INTERVAL_MS_KEY)))
	var interval_seconds: float = float(interval_ms) * 0.001
	var refill_amount: int = maxi(0, int(_progression.call("get_value", WATER_REFILL_AMOUNT_KEY)))
	if refill_amount <= 0:
		return
	_water_refill_elapsed += delta
	while _water_refill_elapsed >= interval_seconds and current < maximum:
		_water_refill_elapsed -= interval_seconds
		var added: int = mini(refill_amount, maximum - current)
		_update_water_reserve(added)
		current += added

func _update_water_reserve(delta_value: int) -> void:
	if not _progression or not _progression.has_method("update_value"):
		return
	var maximum: int = int(_progression.call("get_value", WATER_RESERVE_MAX_KEY))
	_progression.call("update_value", WATER_RESERVE_KEY, delta_value, 0, maximum)

func _water_plants_in_cone(origin: Vector2, direction: Vector2, radius: float, angle_degrees: float) -> void:
	if not _plant_manager or not _plant_layer or not _plant_manager.has_method("is_rose_cell") or not _plant_manager.has_method("wet_rose"):
		return
	var tile_size: Vector2i = _plant_layer.tile_set.tile_size if _plant_layer.tile_set else Vector2i(32, 32)
	var cell_radius: int = int(ceil(radius / maxf(1.0, float(mini(tile_size.x, tile_size.y))))) + 1
	var origin_cell: Vector2i = _plant_layer.local_to_map(_plant_layer.to_local(origin))
	var min_dot: float = cos(deg_to_rad(angle_degrees * 0.5))
	for y: int in range(origin_cell.y - cell_radius, origin_cell.y + cell_radius + 1):
		for x: int in range(origin_cell.x - cell_radius, origin_cell.x + cell_radius + 1):
			var cell: Vector2i = Vector2i(x, y)
			if not bool(_plant_manager.call("is_rose_cell", cell)):
				continue
			var cell_world: Vector2 = _plant_layer.to_global(_plant_layer.map_to_local(cell))
			var offset: Vector2 = cell_world - origin
			if offset.length_squared() > radius * radius:
				continue
			if angle_degrees < 359.9 and offset.length_squared() > 0.000001 and offset.normalized().dot(direction) < min_dot:
				continue
			_plant_manager.call("wet_rose", cell)

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
	const DEFAULT_FILL := Color(1.0, 0.0, 0.0, 0.18)
	const DEFAULT_STROKE := Color(1.0, 0.0, 0.0, 0.85)
	const DEFAULT_STROKE_WIDTH := 2.0
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
