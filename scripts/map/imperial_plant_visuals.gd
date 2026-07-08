extends Node2D
class_name ImperialPlantVisuals

const IMPERIAL_DRY_TEXTURE: Texture2D = preload("res://assets/sprites/legval/imperial_dry.png")
const IMPERIAL_WET_TEXTURE: Texture2D = preload("res://assets/sprites/legval/imperial_wet.png")
const FRAME_COUNT: int = 6
const VISUAL_OFFSET_FROM_SORT_POINT: Vector2 = Vector2(0.0, -18.0)
const POP_DURATION: float = 0.32
const POP_JUMP_PIXELS: float = 8.0
const POP_START_SCALE: Vector2 = Vector2(0.45, 1.30)
const POP_OVERSHOOT_SCALE: Vector2 = Vector2(1.22, 0.84)
const POP_TWIST_DEGREES: float = 10.0

@export var plant_manager_path: NodePath
@export var plantz_path: NodePath

var _plant_manager: Node
var _plantz: TileMapLayer
var _sprites_by_cell: Dictionary = {}
var _stages_by_cell: Dictionary = {}
var _pop_tweens_by_cell: Dictionary = {}


func _ready() -> void:
	if not _resolve_dependencies():
		call_deferred("_finish_ready")
		return
	_finish_ready()


func _finish_ready() -> void:
	if not _resolve_dependencies():
		push_warning("ImperialPlantVisuals: missing PlantManager=%s or plantz=%s; disabling imperial visuals." % [
			str(plant_manager_path),
			str(plantz_path),
		])
		set_process(false)
		return
	_connect_plant_manager()
	_rebuild_from_manager()


func _resolve_dependencies() -> bool:
	if _plant_manager == null:
		_plant_manager = get_node_or_null(plant_manager_path)
	if _plant_manager == null and get_parent() != null:
		_plant_manager = get_parent().get_node_or_null("PlantManager")
	if _plantz == null:
		_plantz = get_node_or_null(plantz_path) as TileMapLayer
	if _plantz == null and get_parent() != null:
		_plantz = get_parent().get_node_or_null("MonTilemap/plantz") as TileMapLayer
	return _plant_manager != null and _plantz != null


func _connect_plant_manager() -> void:
	if _plant_manager.has_signal("plant_visual_changed"):
		var visual_changed_callback: Callable = Callable(self, "_on_plant_visual_changed")
		if not _plant_manager.is_connected("plant_visual_changed", visual_changed_callback):
			_plant_manager.connect("plant_visual_changed", visual_changed_callback)
	if _plant_manager.has_signal("plant_added"):
		var plant_added_callback: Callable = Callable(self, "_on_plant_added")
		if not _plant_manager.is_connected("plant_added", plant_added_callback):
			_plant_manager.connect("plant_added", plant_added_callback)
	if _plant_manager.has_signal("plant_removed"):
		var plant_removed_callback: Callable = Callable(self, "_on_plant_removed")
		if not _plant_manager.is_connected("plant_removed", plant_removed_callback):
			_plant_manager.connect("plant_removed", plant_removed_callback)


func _rebuild_from_manager() -> void:
	for raw_sprite: Variant in _sprites_by_cell.values():
		var sprite: Sprite2D = raw_sprite as Sprite2D
		if is_instance_valid(sprite):
			sprite.queue_free()
	_sprites_by_cell.clear()
	_stages_by_cell.clear()
	_clear_pop_tweens()
	if _plant_manager == null or not _plant_manager.has_method("get_imperial_plant_visual_states"):
		return
	var raw_states: Variant = _plant_manager.call("get_imperial_plant_visual_states")
	if not (raw_states is Array):
		return
	for raw_state: Variant in raw_states as Array:
		if raw_state is Dictionary:
			var state: Dictionary = raw_state as Dictionary
			var cell: Vector2i = state.get("cell", Vector2i.ZERO) as Vector2i
			_apply_visual(cell, int(state.get("stage", 0)), bool(state.get("watered", false)))


func _on_plant_visual_changed(cell: Vector2i, plant_kind: String, stage: int, watered: bool) -> void:
	if plant_kind != "imperial":
		_remove_visual(cell)
		return
	_apply_visual(cell, stage, watered)


func _on_plant_added(cell: Vector2i) -> void:
	_sync_cell_from_manager(cell)


func _on_plant_removed(cell: Vector2i) -> void:
	_remove_visual(cell)


func _sync_cell_from_manager(cell: Vector2i) -> void:
	if _plant_manager == null or not _plant_manager.has_method("get_plant_visual_state"):
		return
	var raw_state: Variant = _plant_manager.call("get_plant_visual_state", cell)
	if not (raw_state is Dictionary):
		return
	var state: Dictionary = raw_state as Dictionary
	var plant_kind: String = str(state.get("plant_kind", ""))
	if plant_kind != "imperial":
		_remove_visual(cell)
		return
	_apply_visual(cell, int(state.get("stage", 0)), bool(state.get("watered", false)))


func _apply_visual(cell: Vector2i, stage: int, watered: bool) -> void:
	var previous_stage: int = int(_stages_by_cell.get(cell, stage))
	var should_pop: bool = _stages_by_cell.has(cell) and stage > previous_stage
	_stages_by_cell[cell] = stage
	var sprite: Sprite2D = _sprites_by_cell.get(cell, null) as Sprite2D
	if sprite == null or not is_instance_valid(sprite):
		sprite = Sprite2D.new()
		sprite.name = "Imperial_%d_%d" % [cell.x, cell.y]
		sprite.hframes = FRAME_COUNT
		sprite.vframes = 1
		sprite.centered = true
		sprite.offset = VISUAL_OFFSET_FROM_SORT_POINT
		sprite.z_as_relative = false
		add_child(sprite)
		_sprites_by_cell[cell] = sprite
	else:
		sprite.offset = VISUAL_OFFSET_FROM_SORT_POINT
	sprite.texture = IMPERIAL_WET_TEXTURE if watered else IMPERIAL_DRY_TEXTURE
	sprite.frame = clampi(stage, 0, FRAME_COUNT - 1)
	var world_center: Vector2 = _plantz.to_global(_plantz.map_to_local(cell))
	sprite.global_position = world_center
	sprite.z_index = int(world_center.y)
	if should_pop:
		_play_pop(cell, sprite, world_center)


func _play_pop(cell: Vector2i, sprite: Sprite2D, base_position: Vector2) -> void:
	_kill_pop_tween(cell)
	sprite.scale = POP_START_SCALE
	sprite.rotation = deg_to_rad(-POP_TWIST_DEGREES)
	sprite.global_position = base_position
	var tween: Tween = create_tween()
	_pop_tweens_by_cell[cell] = tween
	tween.set_parallel(true)
	tween.tween_property(sprite, "scale", POP_OVERSHOOT_SCALE, POP_DURATION * 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, "rotation", deg_to_rad(POP_TWIST_DEGREES), POP_DURATION * 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, "global_position", base_position + Vector2(0.0, -POP_JUMP_PIXELS), POP_DURATION * 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.chain().set_parallel(true)
	tween.tween_property(sprite, "scale", Vector2.ONE, POP_DURATION * 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(sprite, "rotation", 0.0, POP_DURATION * 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(sprite, "global_position", base_position, POP_DURATION * 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.finished.connect(Callable(self, "_on_pop_finished").bind(cell, sprite, base_position))


func _on_pop_finished(cell: Vector2i, sprite: Sprite2D, base_position: Vector2) -> void:
	_pop_tweens_by_cell.erase(cell)
	if not is_instance_valid(sprite):
		return
	sprite.scale = Vector2.ONE
	sprite.rotation = 0.0
	sprite.global_position = base_position


func _remove_visual(cell: Vector2i) -> void:
	_kill_pop_tween(cell)
	_stages_by_cell.erase(cell)
	var sprite: Sprite2D = _sprites_by_cell.get(cell, null) as Sprite2D
	_sprites_by_cell.erase(cell)
	if is_instance_valid(sprite):
		sprite.queue_free()


func _kill_pop_tween(cell: Vector2i) -> void:
	var tween: Tween = _pop_tweens_by_cell.get(cell, null) as Tween
	_pop_tweens_by_cell.erase(cell)
	if tween != null and tween.is_valid():
		tween.kill()


func _clear_pop_tweens() -> void:
	for raw_tween: Variant in _pop_tweens_by_cell.values():
		var tween: Tween = raw_tween as Tween
		if tween != null and tween.is_valid():
			tween.kill()
	_pop_tweens_by_cell.clear()
