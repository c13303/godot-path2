extends Node
class_name FightSystem

@export var visualize_AOE_weapons: bool = true
# When off, projectiles are drawn in a single batched layer with no per-Y z
# sorting against agents (cheaper). When on, projectiles bucket by ground Y so
# they interleave correctly with agents.
@export var z_order_projectiles: bool = false
@export var weapons: Array[WeaponData] = [
	preload("res://scripts/combat/weapons/bomb.tres"),
	preload("res://scripts/combat/weapons/sword.tres"),
]
@export var guns: Array[GunData] = [
	preload("res://scripts/combat/weapons/water.tres"),
]

var _steering: Node
var _projectiles: Node
var _drawer
var _projectile_drawer
var _weapons_by_id: Dictionary = {}
var _guns_by_id: Dictionary = {}
var _gun_type_ids: Dictionary = {}
var _gun_by_type_id: Dictionary = {}  # type_id (int) -> GunData, for impact visuals
var _gun_fire_timers: Dictionary = {}

func _ready() -> void:
	_steering = get_node_or_null("../CPP/SteeringSystemNative")
	_projectiles = get_node_or_null("../CPP/ProjectileSystemNative")
	_drawer = WeaponAOEDrawer.new()
	_drawer.setup(_steering)
	add_child(_drawer)
	_rebuild_weapon_index()
	_register_guns()
	_upload_projectile_walls()
	if _projectiles:
		_projectile_drawer = ProjectileDrawer.new()
		_projectile_drawer.z_order_enabled = z_order_projectiles
		_projectile_drawer.setup(_projectiles, _guns_by_id, _gun_type_ids)
		add_child(_projectile_drawer)

func _process(_delta: float) -> void:
	_drain_projectile_impacts()

# Drain this frame's projectile AoE impacts (wall/expiry/agent) from the native
# system and render each as a fading ring via the shared WeaponAOEDrawer. The
# native buffer holds events for exactly one update, so this must run every frame.
func _drain_projectile_impacts() -> void:
	if not _projectiles or not _projectiles.has_method("get_impacts"):
		return
	var impacts: Array = _projectiles.call("get_impacts")
	if impacts.is_empty():
		return
	for impact in impacts:
		var gun: GunData = _gun_by_type_id.get(int(impact.get("type_id", -1))) as GunData
		if not gun or not gun.impact_visual_enabled:
			continue
		var pos: Vector2 = impact.get("pos", Vector2.ZERO)
		var dir: Vector2 = impact.get("dir", Vector2.RIGHT)
		var radius: float = float(impact.get("radius", 0.0))
		if radius <= 0.0 or gun.impact_display_duration <= 0.0:
			continue
		# The native impact is the GROUND point (shadow). The projectile sprite was
		# drawn lifted by altitude, so lift the ring the same amount to center it on
		# where the projectile visually was. impact_visual_offset is extra fine-tuning.
		var visual_pos: Vector2 = pos - Vector2(0.0, gun.projectile_altitude_px) + gun.impact_visual_offset
		# Impacts are world-anchored circles (owner_id = -1, angle = 360).
		_drawer.show_weapon_area(visual_pos, dir, radius, 360.0, gun.impact_display_duration, -1, Vector2.ZERO, gun.impact_fill_color, gun.impact_stroke_color, gun.impact_stroke_width)

# Upload the static wall mask to the projectile system so projectiles are
# stopped by walls. Call again (refresh_projectile_walls) when walls change.
func _upload_projectile_walls() -> void:
	if not _projectiles or not _projectiles.has_method("set_wall_layer"):
		return
	var wall_layer: TileMapLayer = get_node_or_null("../Map/MonTilemap/wallz") as TileMapLayer
	var floor_layer: TileMapLayer = get_node_or_null("../Map/MonTilemap/floor") as TileMapLayer
	if not wall_layer:
		return
	_projectiles.call("set_wall_layer", wall_layer, floor_layer)

# Public hook: re-upload walls after the build system adds/removes wall tiles.
func refresh_projectile_walls() -> void:
	_upload_projectile_walls()

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
		aoe_follow_offset
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
			"stopped_by_walls": gun.stopped_by_walls,
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

func fire_gun_held(gun_id: String, origin: Vector2, direction: Vector2, source_agent_id: int, delta: float) -> void:
	var gun: GunData = _guns_by_id.get(gun_id) as GunData
	if not gun or not _projectiles:
		return
	var t: float = float(_gun_fire_timers.get(gun_id, 0.0))
	t -= delta
	if t <= 0.0:
		var type_id: int = int(_gun_type_ids.get(gun_id, -1))
		if type_id >= 0:
			var spawn_pos: Vector2 = origin
			if gun.throw_offset != 0.0 and direction.length_squared() > 0.000001:
				spawn_pos += direction.normalized() * gun.throw_offset
			_projectiles.call("fire", type_id, spawn_pos, direction, source_agent_id, gun.affected_smash_classes)
		t = max(0.0, gun.fire_delay_ms * 0.001)
	_gun_fire_timers[gun_id] = t

func reset_gun_cooldown(gun_id: String) -> void:
	if _gun_fire_timers.has(gun_id):
		_gun_fire_timers[gun_id] = 0.0

class WeaponAOEDrawer:
	extends Node2D

	var _areas: Array[Dictionary] = []
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

	func _process(delta: float) -> void:
		var changed := false
		for i in range(_areas.size() - 1, -1, -1):
			_areas[i]["time_left"] = float(_areas[i]["time_left"]) - delta
			if float(_areas[i]["time_left"]) <= 0.0:
				_areas.remove_at(i)
				changed = true
		if changed or not _areas.is_empty():
			queue_redraw()

	func _draw() -> void:
		for area in _areas:
			var origin: Vector2 = area["origin"]
			# Follow the owning agent's live position so the cone tracks the player.
			# Falls back to the captured origin when there is no valid owner.
			var owner_id: int = int(area.get("owner_id", -1))
			if owner_id >= 0 and _steering:
				origin = _steering.get_agent_position(owner_id) + (area.get("follow_offset", Vector2.ZERO) as Vector2)
			var radius: float = float(area["radius"])
			var angle: float = float(area["angle"])
			var direction: Vector2 = area["direction"]
			var fill: Color = area.get("fill", DEFAULT_FILL)
			var stroke: Color = area.get("stroke", DEFAULT_STROKE)
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
		bucket.z_index = band * BUCKET_HEIGHT_PX + (BUCKET_HEIGHT_PX / 2)
		_buckets_by_band[band] = bucket
		return bucket
