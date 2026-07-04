extends Node2D
class_name GardenHoseFluid

const WATER_PACKET_COLOR: Color = Color(0.25, 0.65, 1.0, 0.9)

@export var hose_path: NodePath
@export var packet_pool_size: int = 160
@export var packet_radius: float = 4.0
@export var packet_speed_pixels_per_second: float = 260.0
@export var min_travel_seconds: float = 0.35
@export var max_travel_seconds: float = 1.6
@export var visual_packets_per_shot: int = 5
@export var visual_packet_spacing_seconds: float = 0.055

var _hose: GardenHose
var _packet_nodes: Array[FluidPacketNode] = []
var _active_packets: Array[Dictionary] = []

func _ready() -> void:
	_resolve_hose()
	_create_packet_pool()
	set_process(true)

func _process(delta: float) -> void:
	if _hose == null or not is_instance_valid(_hose):
		_resolve_hose()
	_update_packets(delta)

func request_water_shot(_origin: Vector2, direction: Vector2, source_agent_id: int, fight_system: Node) -> bool:
	if fight_system == null or direction.length_squared() <= 0.000001:
		return false
	var packet_node: FluidPacketNode = _next_available_packet_node()
	if packet_node == null:
		return false

	var travel_seconds: float = _travel_seconds()
	_queue_forward_visual_packets(packet_node, travel_seconds, {
		"shot_direction": direction.normalized(),
		"source_agent_id": source_agent_id,
		"fight_system": fight_system,
	})
	return true

func request_spray_projectile(type_id: int, direction: Vector2, inherited_velocity: Vector2, source_agent_id: int, fight_system: Node) -> bool:
	if fight_system == null or type_id < 0 or direction.length_squared() <= 0.000001:
		return false
	var packet_node: FluidPacketNode = _next_available_packet_node()
	if packet_node == null:
		return false

	var travel_seconds: float = _travel_seconds()
	_queue_forward_visual_packets(packet_node, travel_seconds, {
		"spray_type_id": type_id,
		"shot_direction": direction.normalized(),
		"inherited_velocity": inherited_velocity,
		"source_agent_id": source_agent_id,
		"fight_system": fight_system,
	})
	return true

func request_refill(amount: int, fight_system: Node) -> bool:
	if fight_system == null or amount <= 0:
		return false
	var packet_node: FluidPacketNode = _next_available_packet_node()
	if packet_node == null:
		return false

	var travel_seconds: float = _travel_seconds()
	_queue_refill_visual_packets(packet_node, travel_seconds, {
		"refill_amount": amount,
		"fight_system": fight_system,
	})
	return true

func request_refill_visual() -> bool:
	var packet_node: FluidPacketNode = _next_available_packet_node()
	if packet_node == null:
		return false

	_queue_refill_visual_packets(packet_node, _travel_seconds(), {})
	return true

func _resolve_hose() -> void:
	if not hose_path.is_empty():
		_hose = get_node_or_null(hose_path) as GardenHose
	if _hose == null:
		var parent: Node = get_parent()
		if parent != null:
			_hose = parent.get_node_or_null("GardenHose") as GardenHose

func _create_packet_pool() -> void:
	var count: int = maxi(0, packet_pool_size)
	for index: int in range(count):
		var packet_node: FluidPacketNode = FluidPacketNode.new()
		packet_node.name = "FluidPacket%02d" % index
		packet_node.radius = packet_radius
		packet_node.color = WATER_PACKET_COLOR
		packet_node.visible = false
		add_child(packet_node)
		_packet_nodes.append(packet_node)

func _queue_forward_visual_packets(first_packet_node: FluidPacketNode, travel_seconds: float, data: Dictionary) -> void:
	var count: int = maxi(1, visual_packets_per_shot)
	var speed: float = 1.0 / maxf(travel_seconds, 0.001)
	for index: int in range(count):
		var packet_node: FluidPacketNode = first_packet_node if index == 0 else _next_available_packet_node()
		if packet_node == null:
			return
		var packet: Dictionary = data.duplicate()
		packet["node"] = packet_node
		packet["progress"] = -speed * visual_packet_spacing_seconds * float(index)
		packet["direction"] = 1.0
		packet["speed"] = speed
		packet["triggers_payload"] = index == count - 1
		packet_node.visible = true
		_active_packets.append(packet)

func _queue_refill_visual_packets(first_packet_node: FluidPacketNode, travel_seconds: float, data: Dictionary) -> void:
	var count: int = maxi(1, visual_packets_per_shot)
	var speed: float = 1.0 / maxf(travel_seconds, 0.001)
	for index: int in range(count):
		var packet_node: FluidPacketNode = first_packet_node if index == 0 else _next_available_packet_node()
		if packet_node == null:
			return
		var packet: Dictionary = data.duplicate()
		packet["node"] = packet_node
		packet["progress"] = 1.0 + speed * visual_packet_spacing_seconds * float(index)
		packet["direction"] = -1.0
		packet["speed"] = speed
		packet["triggers_payload"] = data.has("refill_amount") and index == count - 1
		packet_node.visible = true
		_active_packets.append(packet)

func _update_packets(delta: float) -> void:
	for index: int in range(_active_packets.size() - 1, -1, -1):
		var packet: Dictionary = _active_packets[index]
		var progress: float = float(packet.get("progress", 0.0))
		var direction: float = float(packet.get("direction", 1.0))
		var speed: float = float(packet.get("speed", 1.0))
		progress += direction * speed * delta
		packet["progress"] = progress

		var packet_node: FluidPacketNode = packet.get("node") as FluidPacketNode
		if packet_node != null and is_instance_valid(packet_node):
			packet_node.global_position = _sample_packet_position(clampf(progress, 0.0, 1.0))

		if progress >= 1.0:
			if bool(packet.get("triggers_payload", true)):
				_finish_forward_packet(packet)
			_deactivate_packet(index)
		elif progress <= 0.0 and direction < 0.0:
			if bool(packet.get("triggers_payload", true)):
				_finish_refill_packet(packet)
			_deactivate_packet(index)
		else:
			_active_packets[index] = packet

func _sample_packet_position(progress: float) -> Vector2:
	if _hose != null and is_instance_valid(_hose):
		return _hose.sample_world_position(progress)
	return global_position

func _travel_seconds() -> float:
	var hose_length: float = 0.0
	if _hose != null and is_instance_valid(_hose):
		hose_length = _hose.get_hose_length()
	var seconds: float = hose_length / maxf(1.0, packet_speed_pixels_per_second)
	return clampf(seconds, min_travel_seconds, max_travel_seconds)

func _finish_forward_packet(packet: Dictionary) -> void:
	var fight_system: Node = packet.get("fight_system") as Node
	if fight_system == null or not is_instance_valid(fight_system):
		return
	var spawn_position: Vector2 = _sample_packet_position(1.0)
	var direction: Vector2 = packet.get("shot_direction", Vector2.RIGHT) as Vector2
	var source_agent_id: int = int(packet.get("source_agent_id", -1))
	if packet.has("spray_type_id"):
		if not fight_system.has_method("fire_spray_projectile_direct"):
			return
		var type_id: int = int(packet.get("spray_type_id", -1))
		var inherited_velocity: Vector2 = packet.get("inherited_velocity", Vector2.ZERO) as Vector2
		fight_system.call("fire_spray_projectile_direct", type_id, spawn_position, direction, inherited_velocity, source_agent_id)
		return
	if not fight_system.has_method("fire_gun_projectile_direct"):
		return
	fight_system.call("fire_gun_projectile_direct", "water", spawn_position, direction, source_agent_id)

func _finish_refill_packet(packet: Dictionary) -> void:
	var fight_system: Node = packet.get("fight_system") as Node
	if fight_system == null or not is_instance_valid(fight_system):
		return
	if not fight_system.has_method("apply_hose_refill"):
		return
	var amount: int = int(packet.get("refill_amount", 0))
	fight_system.call("apply_hose_refill", amount)

func _deactivate_packet(index: int) -> void:
	var packet: Dictionary = _active_packets[index]
	var packet_node: FluidPacketNode = packet.get("node") as FluidPacketNode
	if packet_node != null and is_instance_valid(packet_node):
		packet_node.visible = false
	_active_packets.remove_at(index)

func _next_available_packet_node() -> FluidPacketNode:
	for packet_node: FluidPacketNode in _packet_nodes:
		if not packet_node.visible:
			return packet_node
	return null

class FluidPacketNode:
	extends Node2D

	var radius: float = 4.0
	var color: Color = Color(0.25, 0.65, 1.0, 0.9)

	func _draw() -> void:
		draw_circle(Vector2.ZERO, radius, color)
		draw_circle(Vector2(-radius * 0.25, -radius * 0.25), radius * 0.45, Color(1.0, 1.0, 1.0, 0.35))
