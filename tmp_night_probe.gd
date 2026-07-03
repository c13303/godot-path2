extends SceneTree

const MAIN_SCENE: String = "res://mainRun.tscn"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("PROBE: loading ", MAIN_SCENE)
	var packed: PackedScene = load(MAIN_SCENE) as PackedScene
	if packed == null:
		push_error("PROBE: cannot load main scene")
		quit(1)
		return
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	current_scene = scene
	for i: int in range(180):
		await process_frame
		var bm: Node = scene.get_node_or_null("Map/BuildingManager")
		if bm != null and bool(bm.get("_startup_ready")):
			break
	var bm: Node = scene.get_node_or_null("Map/BuildingManager")
	if bm == null:
		push_error("PROBE: BuildingManager missing")
		quit(1)
		return
	_print_state("before_night", bm)
	var game_state: Node = root.get_node_or_null("GameState")
	if game_state == null:
		push_error("PROBE: GameState autoload missing")
		quit(1)
		return
	game_state.call("start_night")
	for i: int in range(600):
		await process_frame
		if i % 30 == 0:
			_print_state("frame_%03d" % i, bm)
		if bool(bm.get("_night_preparation_ready")) and _monster_count() > 0:
			_print_state("spawned", bm)
			quit(0)
			return
	_print_state("timeout", bm)
	quit(2)


func _print_state(label: String, bm: Node) -> void:
	print("PROBE:%s startup=%s night=%s prep=%s ready=%s playlist_enabled=%s playlist_invalid=%s legacy=%d/%d timers=%d spawners=%d gardens=%d monsters=%d last_fail=%s" % [
		label,
		str(bm.get("_startup_ready")),
		str((root.get_node("GameState") as Node).get("is_night")),
		str(bm.get("_night_preparing")),
		str(bm.get("_night_preparation_ready")),
		str(bm.get("_playlist_spawning_enabled")),
		str(bm.get("_playlist_spawning_invalid")),
		int(bm.get("_legacy_spawned_this_night")),
		int(bm.get("_legacy_spawn_limit_this_night")),
		(bm.get("_legacy_spawn_timers") as Dictionary).size(),
		(bm.get("_spawners") as Dictionary).size(),
		(bm.get("_gardens") as Dictionary).size(),
		_monster_count(),
		str(bm.get("_last_spawn_failure")),
	])


func _monster_count() -> int:
	return get_nodes_in_group(&"monsters").size()
