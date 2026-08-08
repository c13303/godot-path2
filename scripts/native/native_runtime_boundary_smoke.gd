extends SceneTree

const MAX_FLOW_FRAMES: int = 240
const AgentRegistryScript: Script = preload("res://scripts/native/agent_handle_registry.gd")
const FlowCoordinatorScript: Script = preload("res://scripts/native/navigation_flow_coordinator.gd")
const GridUploadScript: Script = preload("res://scripts/native/navigation_grid_upload_service.gd")
const SimulationConfigScript: Script = preload("res://scripts/native/native_simulation_config.gd")


func _initialize() -> void:
	var navigation: Node = ClassDB.instantiate(&"NavigationWorld2D") as Node
	var crowd: Node = ClassDB.instantiate(&"CrowdWorld2D") as Node
	var registry: Node = AgentRegistryScript.new() as Node
	var coordinator: Node = FlowCoordinatorScript.new() as Node
	var floor_layer: TileMapLayer = TileMapLayer.new()
	var tile_set: TileSet = TileSet.new()
	tile_set.tile_size = Vector2i(10, 10)
	floor_layer.tile_set = tile_set
	root.add_child(navigation)
	root.add_child(crowd)
	root.add_child(floor_layer)
	root.add_child(registry)
	root.add_child(coordinator)

	var walkable: PackedVector2Array = PackedVector2Array()
	for x: int in range(8):
		walkable.append(Vector2(x, 0))
	if not bool(navigation.call(
		&"configure_grid", Rect2i(0, 0, 8, 1), 10.0,
		Vector2.ZERO, walkable, PackedVector2Array()
	)):
		_fail("navigation fixture configuration failed")
		return
	var configuration: Resource = SimulationConfigScript.new() as Resource
	var grid_upload: RefCounted = GridUploadScript.new() as RefCounted
	if grid_upload == null:
		_fail("grid-upload service did not instantiate")
		return
	if not _verify_grid_upload(grid_upload):
		return
	configuration.tile_size = 10.0
	configuration.agent_diameter_tile_ratio = 0.4
	if not configuration.apply_to_navigation(navigation) \
			or not configuration.apply_to_crowd(crowd):
		_fail("instance configuration application failed")
		return
	if not registry.setup(crowd, false) or not coordinator.setup(
		navigation, crowd, floor_layer
	):
		_fail("host runtime boundary setup failed")
		return

	var cohort_handle: int = registry.create_cohort()
	var actor: Node2D = Node2D.new()
	actor.position = Vector2(5.0, 5.0)
	root.add_child(actor)
	var agent_handle: int = registry.register_agent(
		actor, configuration.default_agent_profile(), cohort_handle
	)
	if cohort_handle == 0 or agent_handle == 0 or registry.find_node(agent_handle) != actor:
		_fail("agent/cohort registration failed")
		return
	if coordinator.request_flow(cohort_handle, Vector2(75.0, 5.0), -1) == 0:
		_fail("cohort flow request failed")
		return

	for _index: int in range(MAX_FLOW_FRAMES):
		await process_frame
		if coordinator.is_flow_ready(cohort_handle):
			break
	if not coordinator.is_flow_ready(cohort_handle):
		_fail("cohort flow did not become ready")
		return
	var before: Vector2 = crowd.call(&"get_agent_position", agent_handle) as Vector2
	for _index: int in range(20):
		crowd.call(&"step", 0.05)
	var after: Vector2 = crowd.call(&"get_agent_position", agent_handle) as Vector2
	if after.x <= before.x:
		_fail("cohort flow did not drive the registered agent")
		return
	if not registry.unregister_agent(agent_handle) or registry.find_node(agent_handle) != null:
		_fail("agent unregister did not clear both owners")
		return
	coordinator.release_cohort_flow(cohort_handle)
	if not registry.remove_cohort(cohort_handle):
		_fail("cohort removal failed")
		return
	print("Native runtime boundary smoke test passed")
	quit(0)


func _verify_grid_upload(grid_upload: RefCounted) -> bool:
	var uploaded_navigation: Node = ClassDB.instantiate(&"NavigationWorld2D") as Node
	var floor_layer: TileMapLayer = TileMapLayer.new()
	var wall_layer: TileMapLayer = TileMapLayer.new()
	var tile_set: TileSet = _single_tile_set()
	floor_layer.tile_set = tile_set
	wall_layer.tile_set = tile_set
	root.add_child(uploaded_navigation)
	root.add_child(floor_layer)
	root.add_child(wall_layer)
	for y: int in range(2):
		for x: int in range(3):
			floor_layer.set_cell(Vector2i(x, y), 0, Vector2i.ZERO)
	wall_layer.set_cell(Vector2i(1, 0), 0, Vector2i.ZERO)
	if not bool(grid_upload.call(
		&"configure_world", uploaded_navigation, floor_layer, wall_layer, null,
		Rect2i(0, 0, 3, 2), 2.0, 0.0, 0.5, 1
	)):
		_fail("TileMap grid upload failed")
		return false
	var detour: PackedVector2Array = uploaded_navigation.call(
		&"find_path_cells", Vector2i(0, 0), Vector2i(2, 0)
	) as PackedVector2Array
	if detour.is_empty():
		_fail("uploaded physical wall did not retain an alternate route")
		return false
	if not bool(grid_upload.call(
		&"set_dynamic_blocker", uploaded_navigation, Vector2i(1, 1), true
	)):
		_fail("dynamic blocker upload failed")
		return false
	var blocked: PackedVector2Array = uploaded_navigation.call(
		&"find_path_cells", Vector2i(0, 0), Vector2i(2, 0)
	) as PackedVector2Array
	if not blocked.is_empty():
		_fail("dynamic blocker channel did not close the only route")
		return false
	return true


func _single_tile_set() -> TileSet:
	var image: Image = Image.create(10, 10, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = Vector2i(10, 10)
	source.create_tile(Vector2i.ZERO)
	var tile_set: TileSet = TileSet.new()
	tile_set.tile_size = Vector2i(10, 10)
	tile_set.add_source(source, 0)
	return tile_set


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
