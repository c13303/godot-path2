extends SceneTree

## Frames allowed for the async baseline-collision flow to be rebuilt and, if the old
## goal became unreachable, for the synchronous rescan to install a new one.
const BASELINE_RECOVERY_FRAMES: int = 120


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	if change_scene_to_file("res://mainRun.tscn") != OK:
		_fail("main scene could not be loaded")
		return
	for _index: int in range(8):
		await process_frame
		await physics_frame

	var scene: Node = current_scene
	var player: Node2D = scene.get_node_or_null("Player") as Node2D
	var controller: Node = scene.get_node_or_null("Player/PlayerController")
	var runtime: Node = scene.get_node_or_null("CPP/CrowdRuntime")
	var navigation_runtime: Node = scene.get_node_or_null("CPP/NavigationRuntime")
	var floor_layer: TileMapLayer = scene.get_node_or_null("Map/MonTilemap/floor") as TileMapLayer
	var wall_layer: TileMapLayer = scene.get_node_or_null("Map/MonTilemap/wallz") as TileMapLayer
	if player == null or controller == null or runtime == null or navigation_runtime == null \
			or floor_layer == null or wall_layer == null:
		_fail("main-scene collision dependencies are missing")
		return
	controller.set_process(false)
	var original_baseline_goal: Vector2i = navigation_runtime.get("_baseline_goal_cell") as Vector2i
	navigation_runtime.call(&"set_cell_blocked", original_baseline_goal, true)
	# Blocking the goal only queues an async flow request; NavigationRuntime polls its
	# status each frame and falls back to a synchronous rescan when it comes back
	# unreachable. Reading the goal cell on the next line can never see that.
	var replacement_baseline_goal: Vector2i = original_baseline_goal
	for _index: int in range(BASELINE_RECOVERY_FRAMES):
		await process_frame
		replacement_baseline_goal = navigation_runtime.get("_baseline_goal_cell") as Vector2i
		if replacement_baseline_goal != original_baseline_goal:
			break
	if replacement_baseline_goal == original_baseline_goal:
		_fail("collision baseline did not recover after its goal cell was blocked")
		return
	navigation_runtime.call(&"set_cell_blocked", original_baseline_goal, false)

	var nav_handle: int = int(player.get("nav_id"))
	var radius: float = 14.4
	var collision_offset: Vector2 = Vector2(0.0, -radius)
	var fixture: Dictionary = _find_wall_approach(floor_layer, wall_layer)
	if fixture.is_empty():
		_fail("no isolated authored wall approach was found")
		return
	var wall_cell: Vector2i = fixture["wall_cell"] as Vector2i
	var start_cell: Vector2i = fixture["start_cell"] as Vector2i
	var direction_i: Vector2i = fixture["direction"] as Vector2i
	var direction: Vector2 = Vector2(direction_i)
	var start_center: Vector2 = floor_layer.to_global(floor_layer.map_to_local(start_cell))
	var start_body: Vector2 = start_center - collision_offset
	runtime.call(&"set_agent_position", nav_handle, start_body, true)
	runtime.call(&"set_agent_input", nav_handle, direction)

	var settled_positions: PackedVector2Array = PackedVector2Array()
	for index: int in range(45):
		await physics_frame
		if index >= 35:
			settled_positions.append(player.global_position)

	var wall_center: Vector2 = wall_layer.to_global(wall_layer.map_to_local(wall_cell))
	var final_center: Vector2 = player.global_position + collision_offset
	var half_cell: float = float(floor_layer.tile_set.tile_size.x) * 0.5
	var signed_distance: float = (final_center - wall_center).dot(direction)
	if signed_distance > -(half_cell + radius) + 0.1:
		_fail("player footprint crossed the authored wall boundary: distance=%.3f" % signed_distance)
		return
	var settled_span: float = 0.0
	for position: Vector2 in settled_positions:
		settled_span = maxf(settled_span, position.distance_to(settled_positions[0]))
	if settled_span > 0.05:
		_fail("player position oscillated while held against a wall: span=%.4f" % settled_span)
		return

	var slide_fixture: Dictionary = _find_wall_slide_approach(floor_layer, wall_layer)
	if slide_fixture.is_empty():
		_fail("no authored wall-slide fixture was found")
		return
	wall_cell = slide_fixture["wall_cell"] as Vector2i
	start_cell = slide_fixture["start_cell"] as Vector2i
	direction_i = slide_fixture["direction"] as Vector2i
	var tangent_i: Vector2i = slide_fixture["tangent"] as Vector2i
	direction = Vector2(direction_i)
	var tangent: Vector2 = Vector2(tangent_i)
	start_center = floor_layer.to_global(floor_layer.map_to_local(start_cell))
	runtime.call(&"set_agent_position", nav_handle, start_center - collision_offset, true)
	runtime.call(&"set_agent_input", nav_handle, (direction + tangent).normalized())
	for _index: int in range(12):
		await physics_frame
	wall_center = wall_layer.to_global(wall_layer.map_to_local(wall_cell))
	final_center = player.global_position + collision_offset
	signed_distance = (final_center - wall_center).dot(direction)
	var tangential_progress: float = (final_center - start_center).dot(tangent)
	if signed_distance > -(half_cell + radius) + 0.1:
		_fail("player footprint crossed a wall while sliding: distance=%.3f" % signed_distance)
		return
	if tangential_progress < 6.0:
		_fail("player did not preserve wall-tangent movement: progress=%.3f" % tangential_progress)
		return

	var dynamic_fixture: Dictionary = _find_open_approach(floor_layer, wall_layer)
	if dynamic_fixture.is_empty():
		_fail("no open-cell dynamic blocker fixture was found")
		return
	var blocked_cell: Vector2i = dynamic_fixture["blocked_cell"] as Vector2i
	start_cell = dynamic_fixture["start_cell"] as Vector2i
	direction_i = dynamic_fixture["direction"] as Vector2i
	direction = Vector2(direction_i)
	navigation_runtime.call(&"set_cell_blocked", blocked_cell, true)
	# Uploading a blocker only queues a flow rebuild, and the crowd collides against
	# the installed flow. Drive the player only once that rebuild has settled,
	# otherwise this measures the race rather than the collision response.
	await _await_baseline_flow_settled(navigation_runtime)
	start_center = floor_layer.to_global(floor_layer.map_to_local(start_cell))
	runtime.call(&"set_agent_position", nav_handle, start_center - collision_offset, true)
	runtime.call(&"set_agent_input", nav_handle, direction)
	for _index: int in range(45):
		await physics_frame
	wall_center = floor_layer.to_global(floor_layer.map_to_local(blocked_cell))
	final_center = player.global_position + collision_offset
	signed_distance = (final_center - wall_center).dot(direction)
	if signed_distance > -(half_cell + radius) + 0.1:
		_fail("player crossed a runtime blocker: distance=%.3f" % signed_distance)
		return
	navigation_runtime.call(&"set_cell_blocked", blocked_cell, false)

	print("game_player_collision_smoke: PASS")
	current_scene.queue_free()
	await process_frame
	quit(0)


func _find_wall_approach(floor_layer: TileMapLayer, wall_layer: TileMapLayer) -> Dictionary:
	var directions: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]
	for wall_cell: Vector2i in wall_layer.get_used_cells():
		for direction: Vector2i in directions:
			var start_cell: Vector2i = wall_cell - direction
			var behind_cell: Vector2i = start_cell - direction
			if floor_layer.get_cell_source_id(start_cell) == -1 \
					or floor_layer.get_cell_source_id(behind_cell) == -1:
				continue
			if wall_layer.get_cell_source_id(start_cell) != -1 \
					or wall_layer.get_cell_source_id(behind_cell) != -1:
				continue
			return {
				"wall_cell": wall_cell,
				"start_cell": start_cell,
				"direction": direction,
			}
	return {}


func _find_open_approach(floor_layer: TileMapLayer, wall_layer: TileMapLayer) -> Dictionary:
	var directions: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]
	var used_cells: Array[Vector2i] = floor_layer.get_used_cells()
	for index: int in range(50, used_cells.size()):
		var blocked_cell: Vector2i = used_cells[index]
		if wall_layer.get_cell_source_id(blocked_cell) != -1:
			continue
		for direction: Vector2i in directions:
			var start_cell: Vector2i = blocked_cell - direction
			var behind_cell: Vector2i = start_cell - direction
			if floor_layer.get_cell_source_id(start_cell) == -1 \
					or floor_layer.get_cell_source_id(behind_cell) == -1:
				continue
			if wall_layer.get_cell_source_id(start_cell) != -1 \
					or wall_layer.get_cell_source_id(behind_cell) != -1:
				continue
			return {
				"blocked_cell": blocked_cell,
				"start_cell": start_cell,
				"direction": direction,
			}
	return {}


func _find_wall_slide_approach(
	floor_layer: TileMapLayer, wall_layer: TileMapLayer
) -> Dictionary:
	var directions: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]
	for wall_cell: Vector2i in wall_layer.get_used_cells():
		for direction: Vector2i in directions:
			var start_cell: Vector2i = wall_cell - direction
			if floor_layer.get_cell_source_id(start_cell) == -1 \
					or wall_layer.get_cell_source_id(start_cell) != -1:
				continue
			var tangents: Array[Vector2i] = [
				Vector2i(-direction.y, direction.x),
				Vector2i(direction.y, -direction.x),
			]
			for tangent: Vector2i in tangents:
				var first_slide_cell: Vector2i = start_cell + tangent
				var second_slide_cell: Vector2i = first_slide_cell + tangent
				if floor_layer.get_cell_source_id(first_slide_cell) == -1 \
						or floor_layer.get_cell_source_id(second_slide_cell) == -1:
					continue
				if wall_layer.get_cell_source_id(first_slide_cell) != -1 \
						or wall_layer.get_cell_source_id(second_slide_cell) != -1:
					continue
				return {
					"wall_cell": wall_cell,
					"start_cell": start_cell,
					"direction": direction,
					"tangent": tangent,
				}
	return {}


## Waits for NavigationRuntime's pending baseline-collision flow request to resolve,
## so callers can tell "the rebuild has happened" apart from "collision works".
func _await_baseline_flow_settled(navigation_runtime: Node) -> void:
	for _index: int in range(BASELINE_RECOVERY_FRAMES):
		await process_frame
		await physics_frame
		if int(navigation_runtime.get("_baseline_pending_flow_handle")) == 0:
			return


func _fail(message: String) -> void:
	push_error("game_player_collision_smoke: FAIL: %s" % message)
	quit(1)
