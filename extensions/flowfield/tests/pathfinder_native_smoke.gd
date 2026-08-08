extends SceneTree


func _initialize() -> void:
	var pathfinder: Node = ClassDB.instantiate(&"PathfinderNative") as Node
	if pathfinder == null:
		_fail("PathfinderNative is not registered")
		return

	for method_name: StringName in [
		&"set_walkable_tiles",
		&"set_blockers",
		&"find_path",
		&"walkable_count",
		&"blocker_count",
	]:
		if not pathfinder.has_method(method_name):
			_fail("PathfinderNative is missing %s" % method_name)
			return

	var walkable: PackedVector2Array = PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(2, 0),
		Vector2(0, 1), Vector2(1, 1), Vector2(2, 1),
		Vector2(0, 2), Vector2(1, 2), Vector2(2, 2),
	])
	pathfinder.call(&"set_walkable_tiles", walkable)
	pathfinder.call(&"set_blockers", PackedVector2Array())
	var path: PackedVector2Array = pathfinder.call(
		&"find_path", Vector2i(0, 0), Vector2i(2, 2)
	) as PackedVector2Array
	if path != PackedVector2Array([Vector2(0, 0), Vector2(1, 1), Vector2(2, 2)]):
		_fail("PathfinderNative returned an unexpected diagonal path: %s" % path)
		return
	if int(pathfinder.call(&"walkable_count")) != 9:
		_fail("PathfinderNative returned an unexpected walkable count")
		return

	pathfinder.free()
	print("PathfinderNative smoke test passed")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
