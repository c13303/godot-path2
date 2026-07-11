extends RefCounted
class_name ClientTantrumController

# Owns per-agent hostile-client behavior. When no roses are obtainable anywhere,
# every current client without a rose turns hostile immediately.
#
# Tantrum is per agent: entering it changes only that client. Each hostile runs an
# explicit stage machine:
#   waiting_for_target -> paused; queued for a budgeted target/path attempt
#   moving             -> native steering follows an assigned A* path to an attack cell
#   attacking          -> native-hard-paused; 1 dmg every 3s with a visual lunge
#
# Targets come from the generic PlayerPlaceableDurabilityService (walls, fences,
# counters, turrets, lamps, reservoirs, plants, ...). The reservoir has no special
# priority. Nothing here creates a shared flow-field group or routes to a reservoir.

const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/cat.png")
const CLIENT_SPRITE_HFRAMES: int = 7
const CLIENT_SPRITE_FRAME_LAYOUT: StringName = &"client_directional_7_horizontal"
const CLIENT_FRAME_TANTRUM_SOUTH: int = 4

const INVALID_CELL: Vector2i = Vector2i(2147483647, 2147483647)

const STAGE_WAITING: StringName = &"waiting_for_target"
const STAGE_MOVING: StringName = &"moving"
const STAGE_ATTACKING: StringName = &"attacking"

const TANTRUM_CLIENT_HEALTH: int = 100
const ATTACK_INTERVAL_SECONDS: float = 3.0
const ATTACK_DAMAGE: int = 1
const ATTACK_RANGE_TILES: float = 1.5
const ATTACK_LUNGE_SECONDS: float = 0.09
const ATTACK_RETURN_SECONDS: float = 0.12
const LUNGE_PIXELS: float = 10.0

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

var _manager: BuildingManager
var _hostile_clients: Dictionary = {}  # nav_id -> Dictionary
# Budgeted retarget queue: at most one expensive path attempt is processed per frame.
var _pending: Array[int] = []
var _queued: Dictionary = {}  # nav_id -> true


func setup(manager: BuildingManager) -> void:
	_manager = manager


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
	_manager.get_player_placeable_durability_service().register_live_destructible_targets()
	var started: int = 0
	for raw_node: Node in _manager.get_tree().get_nodes_in_group("clients"):
		var client: Node2D = raw_node as Node2D
		if client == null or not is_instance_valid(client):
			continue
		if bool(client.get_meta("client_has_rose", false)):
			continue
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
	# Detach this agent's native path/flow and clear only its nav records.
	_manager.detach_agent_path(nav_id)
	_manager.detach_agent_flow(nav_id)
	_manager.clear_agent_navigation_records(nav_id)
	# Pause while target/path selection is queued. Native owns movement, so
	# FlowAgent.set_paused alone would not stop it.
	_set_native_paused(nav_id, true)
	if not client.is_in_group("monsters"):
		client.add_to_group("monsters")
	if client.has_method("stop_eating"):
		client.call("stop_eating")
	client.set_meta("agent_kind", &"client")
	client.set_meta("hostile_client", true)
	client.set("max_health", TANTRUM_CLIENT_HEALTH)
	client.set("health", TANTRUM_CLIENT_HEALTH)
	client.set_meta("client_sprite_frame_layout", CLIENT_SPRITE_FRAME_LAYOUT)
	var sprite: Sprite2D = _client_sprite(client)
	var base_offset: Vector2 = Vector2.ZERO
	if sprite != null:
		sprite.texture = CLIENT_TEXTURE
		sprite.hframes = CLIENT_SPRITE_HFRAMES
		sprite.frame = CLIENT_FRAME_TANTRUM_SOUTH
		sprite.flip_h = false
		base_offset = sprite.offset
	# Angry state makes the client damageable (character._is_damage_immune_agent).
	if client.has_method("start_angry"):
		client.call("start_angry")
	if client.has_method("queue_redraw"):
		client.queue_redraw()
	_hostile_clients[nav_id] = {
		"node": client,
		"stage": STAGE_WAITING,
		"target_key": "",
		"attack_timer": 0.0,
		"attacking_visual": false,
		"attack_tween": null,
		"sprite_offset": base_offset,
		"rejected_keys": {},
		"idle_revision": -1,
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
	# Parked because every target was unreachable: only retry when the world changed.
	var idle_revision: int = int(data.get("idle_revision", -1))
	if idle_revision >= 0 and _manager.get_player_placeable_durability_service().revision() != idle_revision:
		data["idle_revision"] = -1
		data["rejected_keys"] = {}
		_hostile_clients[nav_id] = data
		_enqueue(nav_id)


func _process_moving(nav_id: int, data: Dictionary) -> void:
	var client: Node2D = data.get("node", null) as Node2D
	if client == null:
		return
	var durability: PlayerPlaceableDurabilityService = _manager.get_player_placeable_durability_service()
	var key: String = str(data.get("target_key", ""))
	if not durability.is_target_valid(key):
		_begin_retarget(nav_id)
		return
	var record: Dictionary = durability.target_record(key)
	var target_cell: Vector2i = record.get("cell", INVALID_CELL) as Vector2i
	if _in_attack_range(client, target_cell):
		if bool(record.get("instant_destroy", false)):
			durability.apply_damage(key, ATTACK_DAMAGE)
			_begin_retarget(nav_id)
			return
		_set_native_paused(nav_id, true)
		data["stage"] = STAGE_ATTACKING
		data["attack_timer"] = 0.0
		_hostile_clients[nav_id] = data
		return
	# Path exhausted without arriving in range: the target became unreachable.
	if _manager.agent_path_arrived(nav_id):
		_begin_retarget(nav_id)


func _process_attacking(nav_id: int, data: Dictionary, delta: float) -> void:
	if bool(data.get("attacking_visual", false)):
		return
	var client: Node2D = data.get("node", null) as Node2D
	if client == null:
		return
	var durability: PlayerPlaceableDurabilityService = _manager.get_player_placeable_durability_service()
	var key: String = str(data.get("target_key", ""))
	if not durability.is_target_valid(key):
		_begin_retarget(nav_id)
		return
	var timer: float = float(data.get("attack_timer", 0.0)) - delta
	if timer <= 0.0:
		data["attack_timer"] = ATTACK_INTERVAL_SECONDS
		data["attacking_visual"] = true
		_hostile_clients[nav_id] = data
		_start_attack(nav_id, client, key)
	else:
		data["attack_timer"] = timer
		_hostile_clients[nav_id] = data


# ---------------------------------------------------------------------------
# Budgeted target / path assignment.
# ---------------------------------------------------------------------------
func _process_retarget_budget() -> void:
	while not _pending.is_empty():
		var nav_id: int = int(_pending.pop_front())
		_queued.erase(nav_id)
		if not _hostile_clients.has(nav_id):
			continue
		var data: Dictionary = _hostile_clients[nav_id] as Dictionary
		if StringName(str(data.get("stage", ""))) != STAGE_WAITING:
			continue
		if int(data.get("idle_revision", -1)) >= 0:
			continue
		_attempt_target_assignment(nav_id, data)
		return  # one expensive attempt per frame


func _attempt_target_assignment(nav_id: int, data: Dictionary) -> void:
	var client: Node2D = data.get("node", null) as Node2D
	if client == null:
		return
	var durability: PlayerPlaceableDurabilityService = _manager.get_player_placeable_durability_service()
	var rejected: Dictionary = data.get("rejected_keys", {}) as Dictionary
	var key: String = durability.nearest_target_key(client.global_position, rejected)
	if key == "" and not durability.has_targets():
		durability.register_live_destructible_targets()
		key = durability.nearest_target_key(client.global_position, rejected)
	if key == "":
		# Nothing selectable this attempt. Park until the world (target/topology)
		# revision changes so we do not retry every frame.
		if not durability.has_targets() and not GameState.is_reservoir_destroyed:
			push_warning("ClientTantrumController: hostile has no target and the reservoir is not destroyed (level invariant).")
		data["idle_revision"] = durability.revision()
		_hostile_clients[nav_id] = data
		return
	var record: Dictionary = durability.target_record(key)
	var target_cell: Vector2i = record.get("cell", INVALID_CELL) as Vector2i
	var instant_destroy: bool = bool(record.get("instant_destroy", false))
	# Already within reach: skip pathing entirely.
	if _in_attack_range(client, target_cell):
		data["rejected_keys"] = {}
		data["idle_revision"] = -1
		data["target_key"] = key
		if instant_destroy:
			durability.apply_damage(key, ATTACK_DAMAGE)
			_hostile_clients[nav_id] = data
			_begin_retarget(nav_id)
		else:
			_set_native_paused(nav_id, true)
			data["stage"] = STAGE_ATTACKING
			data["attack_timer"] = 0.0
			_hostile_clients[nav_id] = data
		return
	var path_world: PackedVector2Array = _compute_attack_path(client, target_cell, instant_destroy)
	if path_world.is_empty():
		# No attack cell or no path: reject this target for this selection and try the
		# next closest on a later budgeted tick (no unbounded A* burst this frame).
		rejected[key] = true
		data["rejected_keys"] = rejected
		_hostile_clients[nav_id] = data
		_enqueue(nav_id)
		return
	_manager.detach_agent_flow(nav_id)
	_manager.assign_agent_path(nav_id, path_world)
	_set_native_paused(nav_id, false)
	data["stage"] = STAGE_MOVING
	data["target_key"] = key
	data["rejected_keys"] = {}
	data["idle_revision"] = -1
	_hostile_clients[nav_id] = data


func _compute_attack_path(client: Node2D, target_cell: Vector2i, instant_destroy: bool) -> PackedVector2Array:
	var floorz: TileMapLayer = _manager.floorz
	if floorz == null:
		return PackedVector2Array()
	var client_cell: Vector2i = floorz.local_to_map(floorz.to_local(client.global_position))
	var endpoint_cell: Vector2i = target_cell
	if not instant_destroy:
		endpoint_cell = _best_attack_cell(client, target_cell)
		if endpoint_cell == INVALID_CELL:
			return PackedVector2Array()
	var path_service: BuildingPathService = _manager.get_building_path_service()
	var path_cells: PackedVector2Array = path_service.find_path_on_walkable_map(client_cell, endpoint_cell)
	if path_cells.is_empty():
		return PackedVector2Array()
	return path_service.path_cells_to_world(path_cells, int(client.get("nav_id")), false)


# Cheapest valid adjacent attack cell (walkable 8-neighbor), chosen by squared
# distance from the client with a deterministic tie-break. A diagonal is acceptable
# because attack range is 1.5 tiles.
func _best_attack_cell(client: Node2D, target_cell: Vector2i) -> Vector2i:
	var best_cell: Vector2i = INVALID_CELL
	var best_distance: float = INF
	for offset: Vector2i in NEIGHBOR_OFFSETS:
		var candidate: Vector2i = target_cell + offset
		if not _manager.is_walkable_cell(candidate):
			continue
		var distance: float = client.global_position.distance_squared_to(_manager.cell_center(candidate))
		if best_cell == INVALID_CELL or distance < best_distance or (distance == best_distance and _cell_precedes(candidate, best_cell)):
			best_distance = distance
			best_cell = candidate
	return best_cell


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
		lunge_offset = base_offset + direction.normalized() * LUNGE_PIXELS
	# Visual only: native steering owns the body position (which is hard-paused).
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
	data["idle_revision"] = -1
	if reset_rejected:
		data["rejected_keys"] = {}
	_hostile_clients[nav_id] = data
	_set_native_paused(nav_id, true)
	_enqueue(nav_id)


func _begin_retarget(nav_id: int) -> void:
	if not _hostile_clients.has(nav_id):
		return
	var data: Dictionary = _hostile_clients[nav_id] as Dictionary
	_manager.detach_agent_path(nav_id)
	_clear_attack_visual(data)
	_hostile_clients[nav_id] = data
	_enter_waiting(nav_id, true)


func clear_hostile(nav_id: int) -> void:
	if not _hostile_clients.has(nav_id):
		return
	var data: Dictionary = _hostile_clients[nav_id] as Dictionary
	_clear_attack_visual(data)
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


func _in_attack_range(client: Node2D, target_cell: Vector2i) -> bool:
	if target_cell == INVALID_CELL:
		return false
	var tile_size: Vector2 = _manager.tile_size()
	var reach: float = maxf(tile_size.x, tile_size.y) * ATTACK_RANGE_TILES
	return client.global_position.distance_to(_manager.cell_center(target_cell)) <= reach


func _set_native_paused(nav_id: int, paused: bool) -> void:
	var agent_manager: Node = _manager.get_agent_manager()
	if agent_manager != null and agent_manager.has_method("set_agent_paused"):
		agent_manager.call("set_agent_paused", nav_id, paused)


func _client_sprite(client: Node2D) -> Sprite2D:
	if client == null:
		return null
	return client.get_node_or_null("MonsterSprite2D") as Sprite2D


func _cell_precedes(a: Vector2i, b: Vector2i) -> bool:
	if b == INVALID_CELL:
		return true
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


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
