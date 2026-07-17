extends RefCounted
class_name ClientTantrumController

# Owns per-agent hostile-client behavior. When no roses are obtainable anywhere,
# every current client without a rose turns hostile immediately.
#
# Tantrum is per agent: entering it changes only that client. Each hostile runs an
# explicit stage machine, and hostiles stay natively UNPAUSED throughout so local
# separation/overlap keeps working (an RTS-style front, not a wall of statues):
#   waiting_for_target -> no path/flow; queued for a budgeted target/slot attempt
#   moving             -> native steering follows an A* path to a RESERVED attack cell
#   attacking          -> path detached, still unpaused; staggered lunges apply damage
#
# Which client attacks where is decided by ClientTantrumAssaultPlanner (owned here):
# it hands out one logical attack slot per client, spread across nearby targets and
# capped per world attack cell. Targets/health/destruction stay in the generic
# PlayerPlaceableDurabilityService (walls, fences, counters, turrets, lamps,
# reservoirs, plants, ...). The reservoir has no special priority; nothing here
# creates a shared flow-field group or routes to a reservoir.

const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/cat.png")
const CLIENT_SPRITE_HFRAMES: int = 7
const CLIENT_SPRITE_FRAME_LAYOUT: StringName = &"client_directional_7_horizontal"
const CLIENT_FRAME_TANTRUM_SOUTH: int = 4

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

const STAGE_WAITING: StringName = &"waiting_for_target"
const STAGE_MOVING: StringName = &"moving"
const STAGE_ATTACKING: StringName = &"attacking"

const TANTRUM_CLIENT_HEALTH: int = 10
# Staggered cadence: each client gets a deterministic per-nav interval in this band
# plus a deterministic initial phase, so the assault reads as continuous instead of
# army-wide 3s bursts. DPS is kept ~= the old 5 dmg / (3.0 + 0.31) ~= 1.51/s:
#   3 dmg / (~1.65 avg cooldown + 0.31 animation) ~= 1.53/s.
const ATTACK_DAMAGE: int = 3
const ATTACK_INTERVAL_MIN_SECONDS: float = 1.45
const ATTACK_INTERVAL_MAX_SECONDS: float = 1.85
# 1.75 (not 1.5) so a diagonal reserved cell plus endpoint dispersion (~1.69 tiles)
# still counts as in-range; otherwise dispersed diagonal slots could never attack.
const ATTACK_RANGE_TILES: float = 1.75
const ATTACK_LUNGE_SECONDS: float = 0.09
const ATTACK_RETURN_SECONDS: float = 0.22
const ATTACK_OVERLAP_PIXELS: float = 8.0

# Small fixed A* budget so a big crowd redistributes over a few frames instead of
# freezing, without unbounded per-frame pathfinding.
const MAX_RETARGET_PATH_ATTEMPTS_PER_FRAME: int = 4

var _manager: BuildingManager
var _planner: ClientTantrumAssaultPlanner
var _hostile_clients: Dictionary = {}  # nav_id -> Dictionary
# Budgeted retarget queue: at most MAX_RETARGET_PATH_ATTEMPTS_PER_FRAME per frame.
var _pending: Array[int] = []
var _queued: Dictionary = {}  # nav_id -> true


func setup(manager: BuildingManager) -> void:
	_manager = manager
	_planner = ClientTantrumAssaultPlanner.new()
	_planner.setup(manager, manager.get_player_placeable_durability_service())


func is_active() -> bool:
	# "At least one tantrum client is active" — this must NOT imply all normal
	# client processing should stop.
	return has_hostiles()


func has_hostiles() -> bool:
	_prune_invalid_hostiles()
	return not _hostile_clients.is_empty()


func hostile_count() -> int:
	_prune_invalid_hostiles()
	return _hostile_clients.size()


func start_all_clients_without_rose() -> int:
	var candidates: Array[Node2D] = []
	for raw_node: Node in _manager.get_tree().get_nodes_in_group("clients"):
		var client: Node2D = raw_node as Node2D
		if client == null or not is_instance_valid(client):
			continue
		if bool(client.get_meta("client_has_rose", false)):
			continue
		var nav_id: int = int(client.get("nav_id"))
		if nav_id < 0 or _hostile_clients.has(nav_id):
			continue
		candidates.append(client)
	if candidates.is_empty():
		return 0
	_manager.get_player_placeable_durability_service().register_live_destructible_targets()
	var started: int = 0
	for client: Node2D in candidates:
		if start_for_client(client):
			started += 1
	return started


# ---------------------------------------------------------------------------
# Per-client transition.
# ---------------------------------------------------------------------------
func start_for_client(client: Node2D) -> bool:
	if client == null or not is_instance_valid(client):
		return false
	var nav_id: int = int(client.get("nav_id"))
	if nav_id < 0 or _hostile_clients.has(nav_id):
		return false
	if bool(client.get_meta("client_has_rose", false)):
		return false
	# Detach this agent's native path/flow and clear only its nav records. It stays
	# unpaused: with no path/flow the native addon applies only local separation.
	_manager.detach_agent_path(nav_id)
	_manager.detach_agent_flow(nav_id)
	_manager.clear_agent_navigation_records(nav_id)
	_set_native_paused(nav_id, false)
	if not client.is_in_group("monsters"):
		client.add_to_group("monsters")
	if client.has_method("stop_eating"):
		client.call("stop_eating")
	if client is FlowAgent:
		(client as FlowAgent).set_agent_kind(&"client")
	else:
		client.set_meta("agent_kind", &"client")
	client.set_meta("hostile_client", true)
	client.set("max_health", TANTRUM_CLIENT_HEALTH)
	client.set("health", TANTRUM_CLIENT_HEALTH)
	var sprite: Sprite2D = _client_sprite(client)
	var base_offset: Vector2 = Vector2.ZERO
	if sprite != null:
		sprite.texture = CLIENT_TEXTURE
		sprite.hframes = CLIENT_SPRITE_HFRAMES
		sprite.frame = CLIENT_FRAME_TANTRUM_SOUTH
		sprite.flip_h = false
		base_offset = sprite.offset
	if client is FlowAgent:
		(client as FlowAgent).set_client_sprite_frame_layout(CLIENT_SPRITE_FRAME_LAYOUT)
	else:
		client.set_meta("client_sprite_frame_layout", CLIENT_SPRITE_FRAME_LAYOUT)
	# Angry state makes the client damageable (character._is_currently_damageable).
	if client.has_method("start_angry"):
		client.call("start_angry")
	if client.has_method("queue_redraw"):
		client.queue_redraw()
	var interval: float = _attack_interval_for(nav_id)
	_hostile_clients[nav_id] = {
		"node": client,
		"stage": STAGE_WAITING,
		"target_key": "",
		"attack_cell": INVALID_CELL,
		"attack_timer": _initial_phase_for(nav_id, interval),
		"attack_interval": interval,
		"attacking_visual": false,
		"attack_tween": null,
		"sprite_offset": base_offset,
		"rejected_slot_ids": {},
		"idle_target_revision": -1,
		"idle_availability_revision": -1,
	}
	_enqueue(nav_id)
	_refresh_alert()
	return true


# ---------------------------------------------------------------------------
# Frame processing.
# ---------------------------------------------------------------------------
func process(delta: float) -> void:
	if _hostile_clients.is_empty():
		return
	if _prune_invalid_hostiles():
		_refresh_alert()
		if _hostile_clients.is_empty():
			return
	# Rebuild the planner's slot cache once per frame iff the target set changed.
	_planner.sync()
	for raw_nav_id: Variant in _hostile_clients.keys():
		var nav_id: int = int(raw_nav_id)
		if not _hostile_clients.has(nav_id):
			continue
		var data: Dictionary = _hostile_clients[nav_id] as Dictionary
		match StringName(str(data.get("stage", STAGE_WAITING))):
			STAGE_WAITING:
				_process_waiting(nav_id, data)
			STAGE_MOVING:
				_process_moving(nav_id, data)
			STAGE_ATTACKING:
				_process_attacking(nav_id, data, delta)
	_process_retarget_budget()


func _process_waiting(nav_id: int, data: Dictionary) -> void:
	# Parked clients store why they parked; unparked WAITING clients (e.g. a return
	# queued after being pushed out of range) carry -1 and are handled by the budget.
	var target_rev: int = int(data.get("idle_target_revision", -1))
	var avail_rev: int = int(data.get("idle_availability_revision", -1))
	if target_rev < 0 and avail_rev < 0:
		return
	var durability: PlayerPlaceableDurabilityService = _manager.get_player_placeable_durability_service()
	if target_rev >= 0 and durability.target_revision() != target_rev:
		# Target structure changed: topology/targets may differ, so clear rejects.
		data["rejected_slot_ids"] = {}
		data["idle_target_revision"] = -1
		data["idle_availability_revision"] = -1
		_hostile_clients[nav_id] = data
		_enqueue(nav_id)
		return
	if avail_rev >= 0 and _planner.availability_revision() != avail_rev:
		# A previously occupied slot freed: retry, but preserve rejects (topology same).
		data["idle_target_revision"] = -1
		data["idle_availability_revision"] = -1
		_hostile_clients[nav_id] = data
		_enqueue(nav_id)


func _process_moving(nav_id: int, data: Dictionary) -> void:
	var client: Node2D = data.get("node", null) as Node2D
	if client == null:
		return
	var durability: PlayerPlaceableDurabilityService = _manager.get_player_placeable_durability_service()
	var key: String = str(data.get("target_key", ""))
	if not durability.is_target_valid(key):
		_begin_retarget(nav_id, true)
		return
	var target_cell: Vector2i = _target_cell(durability, key)
	if _in_attack_range(client, target_cell):
		_enter_attacking(nav_id)
		return
	# Arrived at the reserved cell but still out of range: that slot is unusable.
	if _manager.agent_path_arrived(nav_id):
		_reject_reserved_slot(nav_id, data)


func _process_attacking(nav_id: int, data: Dictionary, delta: float) -> void:
	if bool(data.get("attacking_visual", false)):
		return  # a lunge tween is playing; never interrupt it (knockback rule)
	var client: Node2D = data.get("node", null) as Node2D
	if client == null:
		return
	var durability: PlayerPlaceableDurabilityService = _manager.get_player_placeable_durability_service()
	var key: String = str(data.get("target_key", ""))
	if not durability.is_target_valid(key):
		_begin_retarget(nav_id, true)
		return
	var target_cell: Vector2i = _target_cell(durability, key)
	if not _in_attack_range(client, target_cell):
		# Separation pushed this attacker out of range. Keep the reservation and queue
		# a budgeted return to the reserved attack cell.
		data["stage"] = STAGE_WAITING
		_hostile_clients[nav_id] = data
		_enqueue(nav_id)
		return
	var timer: float = float(data.get("attack_timer", 0.0)) - delta
	if timer <= 0.0:
		data["attack_timer"] = float(data.get("attack_interval", ATTACK_INTERVAL_MAX_SECONDS))
		data["attacking_visual"] = true
		_hostile_clients[nav_id] = data
		_start_attack(nav_id, client, key)
	else:
		data["attack_timer"] = timer
		_hostile_clients[nav_id] = data


# ---------------------------------------------------------------------------
# Budgeted target / slot assignment.
# ---------------------------------------------------------------------------
func _process_retarget_budget() -> void:
	var attempts: int = 0
	while not _pending.is_empty() and attempts < MAX_RETARGET_PATH_ATTEMPTS_PER_FRAME:
		var nav_id: int = int(_pending.pop_front())
		_queued.erase(nav_id)
		if not _hostile_clients.has(nav_id):
			continue
		var data: Dictionary = _hostile_clients[nav_id] as Dictionary
		if StringName(str(data.get("stage", ""))) != STAGE_WAITING:
			continue
		if int(data.get("idle_target_revision", -1)) >= 0 or int(data.get("idle_availability_revision", -1)) >= 0:
			continue  # parked; will be re-enqueued when it wakes
		_attempt_assignment(nav_id, data)
		attempts += 1


func _attempt_assignment(nav_id: int, data: Dictionary) -> void:
	var client: Node2D = data.get("node", null) as Node2D
	if client == null:
		return
	var durability: PlayerPlaceableDurabilityService = _manager.get_player_placeable_durability_service()
	var assignment: Dictionary
	if _planner.has_valid_reservation(nav_id):
		# Return to the slot this client already holds (pushed out / interrupted).
		assignment = _planner.reservation(nav_id)
	else:
		assignment = _reserve_fresh(nav_id, data, durability)
		if assignment.is_empty():
			return  # parked or nothing available; _reserve_fresh recorded idle state
	var target_key: String = str(assignment.get("target_key", ""))
	if target_key == "" or not durability.is_target_valid(target_key):
		# Reserved target vanished between frames: drop it and re-select fresh.
		_begin_retarget(nav_id, true)
		return
	var attack_cell: Vector2i = assignment.get("attack_cell", INVALID_CELL) as Vector2i
	data["target_key"] = target_key
	data["attack_cell"] = attack_cell
	data["idle_target_revision"] = -1
	data["idle_availability_revision"] = -1
	_hostile_clients[nav_id] = data
	var target_cell: Vector2i = _target_cell(durability, target_key)
	if _in_attack_range(client, target_cell):
		_enter_attacking(nav_id)
		return
	var path_world: PackedVector2Array = _compute_path_to_cell(client, attack_cell)
	if path_world.is_empty():
		_reject_reserved_slot(nav_id, data)
		return
	_manager.detach_agent_flow(nav_id)
	_manager.assign_agent_path(nav_id, path_world)
	_set_native_paused(nav_id, false)
	data["stage"] = STAGE_MOVING
	_hostile_clients[nav_id] = data


# Reserves the best available slot for a client with no current reservation. Returns
# {} and parks the client (recording idle revisions) when nothing is available.
func _reserve_fresh(nav_id: int, data: Dictionary, durability: PlayerPlaceableDurabilityService) -> Dictionary:
	var client: Node2D = data.get("node", null) as Node2D
	if client == null:
		return {}
	var rejected: Dictionary = data.get("rejected_slot_ids", {}) as Dictionary
	var assignment: Dictionary = _planner.reserve_best_assignment(nav_id, client.global_position, rejected)
	if assignment.is_empty() and not durability.has_targets():
		# Old saves / level-authored reservoirs may have never registered provenance.
		durability.register_live_destructible_targets()
		assignment = _planner.reserve_best_assignment(nav_id, client.global_position, rejected)
	if assignment.is_empty():
		# Park until the target structure or planner availability changes, so we do
		# not rescan every frame.
		if not durability.has_targets() and not GameState.is_reservoir_destroyed:
			push_warning("ClientTantrumController: hostile has no target and the reservoir is not destroyed (level invariant).")
		data["idle_target_revision"] = durability.target_revision()
		data["idle_availability_revision"] = _planner.availability_revision()
		_hostile_clients[nav_id] = data
	return assignment


func _compute_path_to_cell(client: Node2D, attack_cell: Vector2i) -> PackedVector2Array:
	if attack_cell == INVALID_CELL:
		return PackedVector2Array()
	var floorz: TileMapLayer = _manager.floorz
	if floorz == null:
		return PackedVector2Array()
	var client_cell: Vector2i = floorz.local_to_map(floorz.to_local(client.global_position))
	var path_service: BuildingPathService = _manager.get_building_path_service()
	var path_cells: PackedVector2Array = path_service.find_path_on_walkable_map(client_cell, attack_cell)
	if path_cells.is_empty():
		return PackedVector2Array()
	# Endpoint dispersion ON so two clients sharing a tile settle at distinct spots.
	return path_service.path_cells_to_world(path_cells, int(client.get("nav_id")), true)


func _enter_attacking(nav_id: int) -> void:
	if not _hostile_clients.has(nav_id):
		return
	var data: Dictionary = _hostile_clients[nav_id] as Dictionary
	# Detach the completed A* path but keep the agent natively UNPAUSED, so local
	# separation/overlap still applies while it attacks. Reservation is retained.
	_manager.detach_agent_path(nav_id)
	data["stage"] = STAGE_ATTACKING
	_hostile_clients[nav_id] = data


# ---------------------------------------------------------------------------
# Attack visuals.
# ---------------------------------------------------------------------------
func _start_attack(nav_id: int, client: Node2D, key: String) -> void:
	var sprite: Sprite2D = _client_sprite(client)
	if sprite == null:
		_deal_hit(nav_id, key)
		_finish_attack(nav_id)
		return
	var data: Dictionary = _hostile_clients[nav_id] as Dictionary
	var base_offset: Vector2 = data.get("sprite_offset", Vector2.ZERO) as Vector2
	var target_world: Vector2 = _manager.get_player_placeable_durability_service().target_world_position(key)
	var direction: Vector2 = target_world - client.global_position
	var lunge_offset: Vector2 = base_offset
	if direction.length_squared() > 0.0001:
		var tile_size: Vector2 = _manager.tile_size()
		var stop_short_distance: float = maxf(tile_size.x, tile_size.y) * 0.5
		var lunge_distance: float = maxf(0.0, direction.length() - stop_short_distance + ATTACK_OVERLAP_PIXELS)
		lunge_offset = base_offset + direction.normalized() * lunge_distance
	# Visual only: native steering owns the body position; we never move it directly.
	var tween: Tween = _manager.create_tween()
	data["attack_tween"] = tween
	_hostile_clients[nav_id] = data
	tween.tween_property(sprite, "offset", lunge_offset, ATTACK_LUNGE_SECONDS)
	tween.tween_callback(Callable(self, "_deal_hit").bind(nav_id, key))
	tween.tween_property(sprite, "offset", base_offset, ATTACK_RETURN_SECONDS)
	tween.tween_callback(Callable(self, "_finish_attack").bind(nav_id))


func _deal_hit(nav_id: int, key: String) -> void:
	if not _hostile_clients.has(nav_id):
		return
	var durability: PlayerPlaceableDurabilityService = _manager.get_player_placeable_durability_service()
	if not durability.is_target_valid(key):
		return
	_manager.show_damage_number(durability.target_world_position(key), ATTACK_DAMAGE)
	durability.apply_damage(key, ATTACK_DAMAGE)


func _finish_attack(nav_id: int) -> void:
	if not _hostile_clients.has(nav_id):
		return
	var data: Dictionary = _hostile_clients[nav_id] as Dictionary
	data["attacking_visual"] = false
	data["attack_tween"] = null
	_hostile_clients[nav_id] = data


# ---------------------------------------------------------------------------
# Retarget / cleanup / lifecycle.
# ---------------------------------------------------------------------------
func _enter_waiting(nav_id: int, reset_rejected: bool) -> void:
	if not _hostile_clients.has(nav_id):
		return
	var data: Dictionary = _hostile_clients[nav_id] as Dictionary
	data["stage"] = STAGE_WAITING
	data["target_key"] = ""
	data["attack_cell"] = INVALID_CELL
	data["idle_target_revision"] = -1
	data["idle_availability_revision"] = -1
	if reset_rejected:
		data["rejected_slot_ids"] = {}
	_hostile_clients[nav_id] = data
	# Stay unpaused while waiting so native local avoidance keeps working.
	_set_native_paused(nav_id, false)
	_enqueue(nav_id)


# Full retarget: release the reservation, detach path/visual, wait for a new slot.
func _begin_retarget(nav_id: int, reset_rejected: bool) -> void:
	if not _hostile_clients.has(nav_id):
		return
	_planner.release(nav_id)
	var data: Dictionary = _hostile_clients[nav_id] as Dictionary
	_manager.detach_agent_path(nav_id)
	_clear_attack_visual(data)
	_hostile_clients[nav_id] = data
	_enter_waiting(nav_id, reset_rejected)


# Reject the exact slot this client holds (path failed / arrived out of range) and
# wait for a different slot. Rejected slots persist until the target structure changes.
func _reject_reserved_slot(nav_id: int, data: Dictionary) -> void:
	var slot_id: String = str(_planner.reservation(nav_id).get("slot_id", ""))
	_planner.release(nav_id)
	_manager.detach_agent_path(nav_id)
	if slot_id != "":
		var rejected: Dictionary = data.get("rejected_slot_ids", {}) as Dictionary
		rejected[slot_id] = true
		data["rejected_slot_ids"] = rejected
		_hostile_clients[nav_id] = data
	_enter_waiting(nav_id, false)


func clear_hostile(nav_id: int) -> void:
	if not _hostile_clients.has(nav_id):
		return
	var data: Dictionary = _hostile_clients[nav_id] as Dictionary
	_clear_attack_visual(data)
	_planner.release(nav_id)
	# Unpause the native agent before it is unregistered.
	_set_native_paused(nav_id, false)
	_hostile_clients.erase(nav_id)
	_dequeue(nav_id)
	_refresh_alert()


func end() -> void:
	for raw_nav_id: Variant in _hostile_clients.keys():
		var nav_id: int = int(raw_nav_id)
		var data: Dictionary = _hostile_clients[nav_id] as Dictionary
		_clear_attack_visual(data)
		_set_native_paused(nav_id, false)
	_hostile_clients.clear()
	_pending.clear()
	_queued.clear()
	_planner.clear()
	_hide_alert()


func _clear_attack_visual(data: Dictionary) -> void:
	var raw_tween: Variant = data.get("attack_tween", null)
	if raw_tween is Tween and (raw_tween as Tween).is_valid():
		(raw_tween as Tween).kill()
	data["attack_tween"] = null
	data["attacking_visual"] = false
	var client: Node2D = data.get("node", null) as Node2D
	if client != null and is_instance_valid(client):
		var sprite: Sprite2D = _client_sprite(client)
		if sprite != null:
			sprite.offset = data.get("sprite_offset", Vector2.ZERO) as Vector2


func _prune_invalid_hostiles() -> bool:
	var removed: bool = false
	for raw_nav_id: Variant in _hostile_clients.keys():
		var nav_id: int = int(raw_nav_id)
		if not _is_live_hostile_client(nav_id, _hostile_clients[nav_id] as Dictionary):
			_planner.release(nav_id)
			_hostile_clients.erase(nav_id)
			_dequeue(nav_id)
			removed = true
	return removed


func _is_live_hostile_client(nav_id: int, data: Dictionary) -> bool:
	var raw_client: Variant = data.get("node", null)
	if not is_instance_valid(raw_client):
		return false
	var client: Node2D = raw_client as Node2D
	if client == null or client.is_queued_for_deletion() or not client.is_inside_tree():
		return false
	if int(client.get("nav_id")) != nav_id:
		return false
	if not client.is_in_group("clients"):
		return false
	if not bool(client.get_meta("hostile_client", false)):
		return false
	return int(client.get("health")) > 0


# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------
func _enqueue(nav_id: int) -> void:
	if _queued.has(nav_id):
		return
	_queued[nav_id] = true
	_pending.append(nav_id)


func _dequeue(nav_id: int) -> void:
	if _queued.erase(nav_id):
		var index: int = _pending.find(nav_id)
		if index >= 0:
			_pending.remove_at(index)


func _target_cell(durability: PlayerPlaceableDurabilityService, key: String) -> Vector2i:
	return durability.target_record(key).get("cell", INVALID_CELL) as Vector2i


func _in_attack_range(client: Node2D, target_cell: Vector2i) -> bool:
	if target_cell == INVALID_CELL:
		return false
	var tile_size: Vector2 = _manager.tile_size()
	var reach: float = maxf(tile_size.x, tile_size.y) * ATTACK_RANGE_TILES
	return client.global_position.distance_to(_manager.cell_center(target_cell)) <= reach


# Deterministic per-nav interval, stable for a run. No global RNG.
func _attack_interval_for(nav_id: int) -> float:
	var unit: float = _deterministic_unit(nav_id, 0)
	return ATTACK_INTERVAL_MIN_SECONDS + unit * (ATTACK_INTERVAL_MAX_SECONDS - ATTACK_INTERVAL_MIN_SECONDS)


# Deterministic initial phase in [0, interval), so attackers do not all fire at t=0.
func _initial_phase_for(nav_id: int, interval: float) -> float:
	return _deterministic_unit(nav_id, 1) * interval


# Cheap deterministic hash -> unit float in [0, 1). Salt separates the two draws.
func _deterministic_unit(nav_id: int, salt: int) -> float:
	var h: int = (nav_id * 73856093) ^ ((salt + 1) * 19349663)
	h = h & 0x7fffffff
	return float(h % 100000) / 100000.0


func _set_native_paused(nav_id: int, paused: bool) -> void:
	var agent_manager: Node = _manager.get_agent_manager()
	if agent_manager != null and agent_manager.has_method("set_agent_paused"):
		agent_manager.call("set_agent_paused", nav_id, paused)


func _client_sprite(client: Node2D) -> Sprite2D:
	if client == null:
		return null
	return client.get_node_or_null("MonsterSprite2D") as Sprite2D


func _refresh_alert() -> void:
	var count: int = _hostile_clients.size()
	if count <= 0:
		_hide_alert()
		return
	var tutorial: Node = _tutorial_node()
	if tutorial != null and tutorial.has_method("show_alert"):
		tutorial.call("show_alert", "tutorial.tantrum", count, true)


func _hide_alert() -> void:
	var tutorial: Node = _tutorial_node()
	if tutorial != null and tutorial.has_method("clear_alert"):
		tutorial.call("clear_alert", "tutorial.tantrum")


func _tutorial_node() -> Node:
	var scene: Node = _manager.get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GameUI/top anchor/tutorial")
