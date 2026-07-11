extends Node2D
class_name ImperialPlantVisuals

const IMPERIAL_DRY_TEXTURE: Texture2D = preload("res://assets/sprites/legval/imperial_dry.png")
const IMPERIAL_WET_TEXTURE: Texture2D = preload("res://assets/sprites/legval/imperial_wet.png")
const IMPERIAL_ROSE_TEXTURE: Texture2D = preload("res://assets/sprites/legval/rose.png")
const FRAME_COUNT: int = 6
const IMPERIAL_ROSE_FRAME_COUNT: int = 3
const IMPERIAL_ROSE_FRAME: int = 2
const VISUAL_OFFSET_FROM_SORT_POINT: Vector2 = Vector2(0.0, -18.0)
const POP_DURATION: float = 0.32
const POP_JUMP_PIXELS: float = 8.0
const POP_START_SCALE: Vector2 = Vector2(0.45, 1.30)
const POP_OVERSHOOT_SCALE: Vector2 = Vector2(1.22, 0.84)
const POP_TWIST_DEGREES: float = 10.0
const CONTACT_SWAY_DEGREES: float = 5.0
const CONTACT_SWAY_SPEED: float = 1.1
const CONTACT_BREATHE_AMOUNT: float = 0.05
const CONTACT_BREATHE_SPEED: float = 1.4
const CONTACT_BOB_PIXELS: float = 1.0

@export var plant_manager_path: NodePath
@export var plantz_path: NodePath

var _plant_manager: Node
var _plantz: TileMapLayer
var _sprites_by_cell: Dictionary = {}
var _stages_by_cell: Dictionary = {}
var _pop_tweens_by_cell: Dictionary = {}
var _contact_until_by_cell: Dictionary = {}
var _contact_phases_by_cell: Dictionary = {}
var _time: float = 0.0


func _ready() -> void:
	if 	not _resolve_dependencies():
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
	_connect_contact_source()
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


func _connect_contact_source() -> void:
	var source: Node = get_parent().get_node_or_null("BuildingManager") if get_parent() != null else null
	if source == null or not source.has_signal("plant_contact_dance_requested"):
		return
	var callback: Callable = Callable(self, "_on_plant_contact_dance_requested")
	if not source.is_connected("plant_contact_dance_requested", callback):
		source.connect("plant_contact_dance_requested", callback)


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


func _on_plant_contact_dance_requested(layer_name: StringName, cell: Vector2i, item_id: String, duration: float) -> void:
	if layer_name != &"plantz" or item_id != "imperial_seed":
		return
	if not _sprites_by_cell.has(cell):
		return
	_contact_until_by_cell[cell] = maxf(float(_contact_until_by_cell.get(cell, 0.0)), _time + maxf(0.0, duration))
	if not _contact_phases_by_cell.has(cell):
		_contact_phases_by_cell[cell] = {
			"sway_phase": randf() * TAU,
			"breathe_phase": randf() * TAU,
		}


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
	if stage >= FRAME_COUNT - 1:
		sprite.texture = IMPERIAL_ROSE_TEXTURE
		sprite.hframes = IMPERIAL_ROSE_FRAME_COUNT
		sprite.frame = IMPERIAL_ROSE_FRAME
	else:
		sprite.texture = IMPERIAL_WET_TEXTURE if watered else IMPERIAL_DRY_TEXTURE
		sprite.hframes = FRAME_COUNT
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
	_contact_until_by_cell.erase(cell)
	_contact_phases_by_cell.erase(cell)
	var sprite: Sprite2D = _sprites_by_cell.get(cell, null) as Sprite2D
	_sprites_by_cell.erase(cell)
	if is_instance_valid(sprite):
		sprite.queue_free()


func _process(delta: float) -> void:
	_time += delta
	if _contact_until_by_cell.is_empty():
		return
	var expired: Array[Vector2i] = []
	for raw_cell: Variant in _contact_until_by_cell.keys():
		var cell: Vector2i = raw_cell as Vector2i
		var sprite: Sprite2D = _sprites_by_cell.get(cell, null) as Sprite2D
		if sprite == null or not is_instance_valid(sprite):
			expired.append(cell)
			continue
		if _pop_tweens_by_cell.has(cell):
			continue
		var base_position: Vector2 = _plantz.to_global(_plantz.map_to_local(cell))
		if _time >= float(_contact_until_by_cell.get(cell, 0.0)):
			sprite.scale = Vector2.ONE
			sprite.rotation = 0.0
			sprite.global_position = base_position
			expired.append(cell)
			continue
		var phases: Dictionary = _contact_phases_by_cell.get(cell, {}) as Dictionary
		var sway_phase: float = float(phases.get("sway_phase", 0.0))
		var breathe_phase: float = float(phases.get("breathe_phase", 0.0))
		var sway: float = deg_to_rad(CONTACT_SWAY_DEGREES) * sin(_time * CONTACT_SWAY_SPEED * TAU + sway_phase)
		var sy: float = 1.0 + CONTACT_BREATHE_AMOUNT * sin(_time * CONTACT_BREATHE_SPEED * TAU + breathe_phase)
		var sx: float = 1.0 / sy
		var bob: float = -CONTACT_BOB_PIXELS * absf(sin(_time * CONTACT_BREATHE_SPEED * TAU * 0.5 + sway_phase))
		sprite.rotation = sway
		sprite.scale = Vector2(sx, sy)
		sprite.global_position = base_position + Vector2(0.0, bob)
	for cell: Vector2i in expired:
		_contact_until_by_cell.erase(cell)
		_contact_phases_by_cell.erase(cell)


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
