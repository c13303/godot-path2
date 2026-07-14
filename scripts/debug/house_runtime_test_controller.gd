extends Node
class_name HouseRuntimeTestController

# =============================================================================
# TEMPORARY HOUSE PASS 1 TEST
# Remove after runtime house placement is integrated into the real build system.
# =============================================================================
#
# Listens for a plain `K` press and builds one runtime house at the test_flyhouse marker
# cell via HouseManager.create_house(). No build menu, no currency, no item catalog, no
# preview, no removal. Intentionally isolated so it can be deleted wholesale: the only wiring
# is a clearly marked temporary block in BuildingManager (_setup_house_runtime_test_controller).

const TEST_HOUSE_TEXTURE_PATH: String = "res://assets/sprites/house/house1.png"
const TEST_HOUSE_ID: StringName = &"house_runtime_test"
const FLYHOUSE_MARKER_NODE_PATH: String = "spawners/test_flyhouse"

var _house_manager: HouseManager = null
var _floor: TileMapLayer = null
var _built: bool = false


func setup(house_manager: HouseManager, floor_layer: TileMapLayer) -> void:
	_house_manager = house_manager
	_floor = floor_layer
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	var key_event: InputEventKey = event as InputEventKey
	if key_event == null or key_event.echo or not key_event.pressed:
		return
	if key_event.keycode != KEY_K:
		return
	_try_build_test_house()


func _try_build_test_house() -> void:
	if _built:
		print("[HouseRuntimeTest] Runtime test house already built; K ignored.")
		return
	if _house_manager == null or _floor == null:
		return
	var marker: Node2D = _resolve_marker()
	if marker == null:
		push_warning("[HouseRuntimeTest] test_flyhouse marker not found; cannot place runtime house.")
		return
	var entrance: Vector2i = _floor.local_to_map(_floor.to_local(marker.global_position))
	var texture: Texture2D = load(TEST_HOUSE_TEXTURE_PATH) as Texture2D
	if texture == null:
		push_warning("[HouseRuntimeTest] could not load %s." % TEST_HOUSE_TEXTURE_PATH)
		return
	if _house_manager.create_house(TEST_HOUSE_ID, texture, entrance):
		_built = true
		print("[HouseRuntimeTest] Runtime house built at entrance %s." % str(entrance))
	else:
		print("[HouseRuntimeTest] Runtime house build rejected at entrance %s." % str(entrance))


func _resolve_marker() -> Node2D:
	var host: Node = _floor.get_parent() if _floor != null else null
	if host == null:
		return null
	return host.get_node_or_null(NodePath(FLYHOUSE_MARKER_NODE_PATH)) as Node2D
