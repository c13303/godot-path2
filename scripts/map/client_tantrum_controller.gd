extends RefCounted
class_name ClientTantrumController

const CLIENT_TEXTURE: Texture2D = preload("res://assets/sprites/legval/client.png")
const IDLE_GROUP: int = 0
const ATTACK_INTERVAL_SECONDS: float = 3.0
const ATTACK_DAMAGE: int = 1
const ATTACK_LUNGE_SECONDS: float = 0.09
const ATTACK_RETURN_SECONDS: float = 0.12

var _manager: BuildingManager
var _active: bool = false
var _group: int = -1
var _hostile_clients: Dictionary = {}  # nav_id -> Dictionary


func setup(manager: BuildingManager) -> void:
	_manager = manager


func is_active() -> bool:
	return _active


func has_hostiles() -> bool:
	return not _hostile_clients.is_empty()


func hostile_count() -> int:
	return _hostile_clients.size()


func clear_hostile(nav_id: int) -> void:
	_hostile_clients.erase(nav_id)
	_finish_if_no_hostiles()


func nearest_live_reservoir(from_world: Vector2, use_distance: bool) -> Node2D:
	var best: Node2D = null
	var best_distance: float = INF
	for reservoir_node: Node in _manager.get_tree().get_nodes_in_group("reservoirs"):
		var reservoir: Node2D = reservoir_node as Node2D
		if reservoir == null or not is_instance_valid(reservoir) or reservoir_is_destroyed(reservoir):
			continue
		var distance: float = from_world.distance_squared_to(reservoir.global_position) if use_distance else 0.0
		if best == null or distance < best_distance:
			best = reservoir
			best_distance = distance
	return best


func reservoir_is_destroyed(reservoir: Node) -> bool:
	return reservoir != null and reservoir.has_method("is_destroyed") and bool(reservoir.call("is_destroyed"))


func begin() -> void:
	if _active:
		return
	var target_reservoir: Node2D = nearest_live_reservoir(Vector2.ZERO, false)
	if target_reservoir == null:
		push_warning("BuildingManager: client tantrum cannot start because no reservoir exists.")
		return
	var agent_manager: Node = _agent_manager()
	if agent_manager == null or not agent_manager.has_method("create_group") or not agent_manager.has_method("assign_agent"):
		push_warning("BuildingManager: client tantrum cannot start because AgentManagerNative is missing group APIs.")
		return
	_active = true
	_manager.clear_client_sale_spawns()
	_manager.clear_client_counter_agents()
	GameState.set_client_phase(true)
	_group = int(agent_manager.call("create_group"))
	if _group <= IDLE_GROUP:
		push_warning("BuildingManager: client tantrum cannot allocate a flow group.")
		_active = false
		return
	_rebuild_flow(target_reservoir.global_position)
	var hostile_count: int = 0
	for raw_node: Node in _manager.get_tree().get_nodes_in_group("clients"):
		var client: Node2D = raw_node as Node2D
		if client == null or not is_instance_valid(client):
			continue
		if bool(client.get_meta("client_has_rose", false)):
			continue
		if _make_hostile(client, target_reservoir):
			hostile_count += 1
	if hostile_count <= 0:
		end()
		return
	_show_alert()


func end() -> void:
	_active = false
	_hostile_clients.clear()
	_hide_alert()
	var agent_manager: Node = _agent_manager()
	if _group > IDLE_GROUP and agent_manager != null and agent_manager.has_method("dissolve_group"):
		agent_manager.call("dissolve_group", _group)
	_group = -1


func process(delta: float) -> void:
	if not _active:
		return
	var nav_ids: Array = _hostile_clients.keys()
	var removed_hostile: bool = false
	for raw_nav_id: Variant in nav_ids:
		var nav_id: int = int(raw_nav_id)
		if not _hostile_clients.has(nav_id):
			continue
		var data: Dictionary = _hostile_clients[nav_id] as Dictionary
		var raw_client: Variant = data.get("node", null)
		if not is_instance_valid(raw_client):
			_hostile_clients.erase(nav_id)
			removed_hostile = true
			continue
		var client: Node2D = raw_client as Node2D
		if client == null:
			_hostile_clients.erase(nav_id)
			removed_hostile = true
			continue
		var target: Node2D = data.get("target", null) as Node2D
		if target == null or not is_instance_valid(target) or reservoir_is_destroyed(target):
			target = nearest_live_reservoir(client.global_position, true)
			if target == null:
				continue
			data["target"] = target
			_rebuild_flow(target.global_position)
			var agent_manager: Node = _agent_manager()
			if _group > IDLE_GROUP and agent_manager != null and agent_manager.has_method("assign_agent"):
				agent_manager.call("assign_agent", client, _group)
		if bool(data.get("attacking", false)):
			_hostile_clients[nav_id] = data
			continue
		if not _can_hit_reservoir(client, target):
			_hostile_clients[nav_id] = data
			continue
		var attack_timer: float = maxf(0.0, float(data.get("attack_timer", 0.0)) - delta)
		if attack_timer <= 0.0:
			data["attack_timer"] = ATTACK_INTERVAL_SECONDS
			data["attacking"] = true
			_hostile_clients[nav_id] = data
			_start_attack(nav_id, client, target)
		else:
			data["attack_timer"] = attack_timer
			_hostile_clients[nav_id] = data
	if removed_hostile:
		_finish_if_no_hostiles()


func _make_hostile(client: Node2D, target_reservoir: Node2D) -> bool:
	var nav_id: int = int(client.get("nav_id"))
	if nav_id < 0:
		return false
	if bool(client.get_meta("client_has_rose", false)):
		return false
	var agent_manager: Node = _agent_manager()
	if agent_manager != null and agent_manager.has_method("detach_agent_path"):
		agent_manager.call("detach_agent_path", nav_id)
	if agent_manager != null and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	_manager.clear_agent_navigation_records(nav_id)
	if not client.is_in_group("monsters"):
		client.add_to_group("monsters")
	if client.has_method("stop_eating"):
		client.call("stop_eating")
	client.set_meta("agent_kind", &"client")
	client.set_meta("hostile_client", true)
	client.set("max_health", 100)
	client.set("health", 100)
	if client.has_method("queue_redraw"):
		client.queue_redraw()
	var sprite: Sprite2D = client.get_node_or_null("MonsterSprite2D") as Sprite2D
	if sprite != null:
		sprite.texture = CLIENT_TEXTURE
		sprite.hframes = 5
		sprite.frame = 4
	if client.has_method("start_angry"):
		client.call("start_angry")
	_hostile_clients[nav_id] = {
		"node": client,
		"target": target_reservoir,
		"attack_timer": randf_range(0.0, ATTACK_INTERVAL_SECONDS),
		"attacking": false,
	}
	if _group > IDLE_GROUP and agent_manager != null:
		agent_manager.call("assign_agent", client, _group)
	return true


func _start_attack(nav_id: int, client: Node2D, target: Node2D) -> void:
	var agent_manager: Node = _agent_manager()
	if agent_manager != null and agent_manager.has_method("detach_agent_flow"):
		agent_manager.call("detach_agent_flow", nav_id)
	if client.has_method("set_paused"):
		client.call("set_paused", true)
	var start_position: Vector2 = client.global_position
	var direction: Vector2 = target.global_position - start_position
	var lunge_position: Vector2 = start_position
	if direction.length_squared() > 0.0001:
		lunge_position = start_position + direction.normalized() * minf(10.0, direction.length())
	var tween: Tween = _manager.create_tween()
	tween.tween_property(client, "global_position", lunge_position, ATTACK_LUNGE_SECONDS)
	tween.tween_callback(Callable(self, "_deal_hit").bind(nav_id, target))
	tween.tween_property(client, "global_position", start_position, ATTACK_RETURN_SECONDS)
	tween.tween_callback(Callable(self, "_finish_attack").bind(nav_id, client))


func _deal_hit(nav_id: int, target: Variant) -> void:
	if not _hostile_clients.has(nav_id):
		return
	if target != null and is_instance_valid(target) and target.has_method("take_damage"):
		var hit_position: Vector2 = (target as Node2D).global_position if target is Node2D else Vector2.ZERO
		_manager.show_damage_number(hit_position, ATTACK_DAMAGE)
		target.call("take_damage", ATTACK_DAMAGE)


func _finish_attack(nav_id: int, client: Variant) -> void:
	if client != null and is_instance_valid(client) and client.has_method("set_paused"):
		client.call("set_paused", false)
	if not _hostile_clients.has(nav_id):
		return
	var data: Dictionary = _hostile_clients[nav_id] as Dictionary
	data["attacking"] = false
	_hostile_clients[nav_id] = data
	var agent_manager: Node = _agent_manager()
	if client != null and is_instance_valid(client) and _group > IDLE_GROUP and agent_manager != null and agent_manager.has_method("assign_agent"):
		agent_manager.call("assign_agent", client, _group)


func _can_hit_reservoir(client: Node2D, target: Node2D) -> bool:
	if client == null or target == null:
		return false
	var tile_size: Vector2 = _manager.tile_size()
	var attack_distance: float = maxf(tile_size.x, tile_size.y) * 1.5
	return client.global_position.distance_to(target.global_position) <= attack_distance


func _rebuild_flow(goal_world: Vector2) -> void:
	var flow: Node = _flow()
	if flow == null or _group <= IDLE_GROUP:
		return
	if flow.has_method("assign_flow_to_group"):
		flow.call("assign_flow_to_group", _group, goal_world, false)
	elif flow.has_method("request_flow_to_group"):
		flow.call("request_flow_to_group", _group, goal_world, false)


func _show_alert() -> void:
	var scene: Node = _manager.get_tree().current_scene
	if scene == null:
		return
	var tutorial: Node = scene.get_node_or_null("GameUI/top anchor/tutorial")
	if tutorial != null and tutorial.has_method("show_alert"):
		tutorial.call("show_alert", "tutorial.tantrum", hostile_count())


func _hide_alert() -> void:
	var scene: Node = _manager.get_tree().current_scene
	if scene == null:
		return
	var tutorial: Node = scene.get_node_or_null("GameUI/top anchor/tutorial")
	if tutorial != null and tutorial.has_method("clear_alert"):
		tutorial.call("clear_alert", "tutorial.tantrum")


func _finish_if_no_hostiles() -> void:
	if not _active:
		return
	if has_hostiles():
		_show_alert()
		return
	end()


func _agent_manager() -> Node:
	return _manager.get_agent_manager() if _manager != null else null


func _flow() -> Node:
	return _manager.get_flow() if _manager != null else null
