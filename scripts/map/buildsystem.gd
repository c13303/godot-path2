extends Node

signal build_preview_changed(is_active: bool)

const REMOVE_HOLD_SECONDS: float = 0.2
const REMOVE_PROGRESS_WIDTH: float = 6.0
const REMOVE_PROGRESS_HEIGHT_RATIO: float = 0.8
const PREVIEW_NORMAL_COLOR: Color = Color(0.30, 0.62, 1.0, 0.70)
const PREVIEW_FORBIDDEN_RANGE_COLOR: Color = Color(1.0, 0.18, 0.18, 0.5)
const PREVIEW_Z_INDEX: int = 4095
const BUILD_FX_SCENE: PackedScene = preload("res://scenes/particles/buildFX.tscn")
const BUILD_FX_Z_INDEX: int = -62
const GRASS_GREEN_FLOOR_ATLAS: Vector2i = Vector2i(11, 6)
const PLAYER_BUILDABLE_WALL_ATLAS: Vector2i = Vector2i(11, 1)
const DEFAULT_TERRAIN_SPEED_MULTIPLIER: float = 1.0
# Green outline drawn around the whole drag rectangle (rose bulk build + bulk unbuild).
const DRAG_SELECT_FILL_COLOR: Color = Color(0.20, 1.0, 0.35, 0.10)
const DRAG_SELECT_BORDER_COLOR: Color = Color(0.30, 1.0, 0.45)
const TILE_TRANSFORM_FLIP_H: int = 4096
const TILE_TRANSFORM_FLIP_V: int = 8192
const TILE_TRANSFORM_TRANSPOSE: int = 16384
const DIRECTION_RIGHT: Vector2i = Vector2i(1, 0)
const DIRECTION_DOWN: Vector2i = Vector2i(0, 1)
const DIRECTION_LEFT: Vector2i = Vector2i(-1, 0)
const DIRECTION_UP: Vector2i = Vector2i(0, -1)
const ALERT_NEEDS_GRASS_KEY: String = "alert.needs_grass"

@export var floorz: TileMapLayer
@export var watersources: TileMapLayer
@export var wallz: TileMapLayer
@export var plantz: TileMapLayer
@export var traversable_buildings: TileMapLayer
@export var blocking_buildings: TileMapLayer
@export var previewbuild: TileMapLayer
@export var plant_manager: Node
@export var building_object_manager: Node
@export var reservoir_system: Node
@export var game_ui: CanvasLayer
@export var notif: Node
@export var occupied_groups: Array[String] = ["main_chars", "monsters", "player"]
@export var build_fx_pool_size: int = 60

var _atlas_source_id: int = -1
# Cached FlowFieldNative used to keep the player's hard wall collision in sync when a
# wall/building is built or removed during the day (see _refresh_cell_collision).
var _flow_field: Object = null

var _hover_active: bool = false
var _hover_cell: Vector2i
var _hover_item_id: String = ""
var _hover_atlas_coords: Vector2i = Vector2i(-1, -1)
var _preview_cells: Array[Vector2i] = []
# Generic click-drag chunk build. _drag_build_item_id records which item the
# active drag is placing so affordability, validation, runtime objects, and sound
# are resolved per item.
var _drag_build_active: bool = false
var _drag_build_item_id: String = ""
var _drag_build_start_cell: Vector2i = Vector2i.ZERO
var _drag_build_end_cell: Vector2i = Vector2i.ZERO
var _drag_build_preview_limit: int = 0
var _plant_layer_flush_queued: bool = false
var _remove_active: bool = false
var _remove_elapsed: float = 0.0
var _remove_queue: Array[Dictionary] = []
var _remove_progress_by_cell: Dictionary = {}  # Vector2i -> ProgressBar
var _remove_drag_active: bool = false
var _remove_drag_start_cell: Vector2i = Vector2i.ZERO
var _remove_drag_end_cell: Vector2i = Vector2i.ZERO
var _pad_cursor_active: bool = false
var _pad_cursor_offset: Vector2i = Vector2i.ZERO
var _build_direction: Vector2i = DIRECTION_RIGHT
var _build_fx_pool: Array[Node2D] = []
var _build_fx_pool_cursor: int = 0
# Green outline panel that frames the active drag rectangle (built lazily).
var _drag_selection_rect: Panel = null

func _ready() -> void:
	_resolve_level_layers()
	_resolve_atlas_source_id()
	_configure_preview_layer()
	_sync_terrain_speed_cells()
	_preload_build_fx_pool()
	set_process(true)
	set_process_input(true)
	GameState.mode_changed.connect(_on_game_mode_changed)

# floor/watersources/wallz belong to the loaded level (see LevelLoader) and are
# injected into MonTilemap before any _ready runs, so they are resolved by path
# here instead of through scene-wired exports.
func _resolve_level_layers() -> void:
	if floorz == null:
		floorz = get_node_or_null("../MonTilemap/floor") as TileMapLayer
	if watersources == null:
		watersources = get_node_or_null("../MonTilemap/watersources") as TileMapLayer
	if wallz == null:
		wallz = get_node_or_null("../MonTilemap/wallz") as TileMapLayer

func _configure_preview_layer() -> void:
	if previewbuild == null:
		return
	previewbuild.z_index = PREVIEW_Z_INDEX
	previewbuild.modulate = PREVIEW_NORMAL_COLOR

func _on_game_mode_changed(is_night: bool) -> void:
	if not is_night:
		return
	# Removal is forbidden at night. Cancel immediately rather than waiting for
	# the next process tick to clear a hold that began during the day.
	_cancel_removal()
	_cancel_drag_build()

func _process(delta: float) -> void:
	_process_removal(delta)
	if _remove_drag_active:
		_clear_hover()
		return

	var placeable_def: Dictionary = _selected_placeable_def()
	if _drag_build_active:
		if _placement_disabled() or _is_inventory_open() or str(placeable_def.get("id", "")) != _drag_build_item_id:
			_cancel_drag_build()
			return
		var drag_cell: Vector2i = _hovered_cell()
		var available: int = _affordable_quantity(_drag_build_item_id)
		if drag_cell != _drag_build_end_cell or available != _drag_build_preview_limit:
			_drag_build_end_cell = drag_cell
			_draw_drag_build_preview(placeable_def, available)
		return
	if _placement_disabled() or placeable_def.is_empty() or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		_clear_hover()
		return

	var cell: Vector2i = _hovered_cell()
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	var item_id: String = str(placeable_def.get("id", ""))
	if atlas_coords == Vector2i(-1, -1) or not _can_afford(item_id):
		_clear_hover()
		return

	if _hover_active and cell == _hover_cell and atlas_coords == _hover_atlas_coords and item_id == _hover_item_id:
		_refresh_preview_visual_state(placeable_def)
		return

	_clear_hover()
	_hover_cell = cell
	_hover_atlas_coords = atlas_coords
	_hover_active = true
	_draw_preview(cell, atlas_coords, item_id, placeable_def)

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event: InputEventKey = event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == KEY_R:
			if rotate_selected_build_direction():
				get_viewport().set_input_as_handled()
				return

	# Mouse wheel rotates the buildable during placement (keyboard+mouse controls).
	# Only consumes the event when a rotatable buildable is selected, so the wheel is
	# free otherwise. Wheel up / down rotate in opposite directions.
	if event is InputEventMouseButton:
		var wheel_event: InputEventMouseButton = event as InputEventMouseButton
		if wheel_event.pressed and not wheel_event.ctrl_pressed:
			if wheel_event.button_index == MOUSE_BUTTON_WHEEL_UP:
				if rotate_selected_build_direction(false):
					get_viewport().set_input_as_handled()
					return
			elif wheel_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				if rotate_selected_build_direction(true):
					get_viewport().set_input_as_handled()
					return

	if event is InputEventMouseButton:
		var remove_event: InputEventMouseButton = event as InputEventMouseButton
		if remove_event.button_index == MOUSE_BUTTON_RIGHT:
			var removal_input_active: bool = _toolbuild_selected() or _remove_drag_active or _remove_active
			if remove_event.pressed and _toolbuild_selected():
				_start_remove_drag()
			elif not remove_event.pressed and _remove_drag_active:
				_finish_remove_drag()
			if removal_input_active:
				get_viewport().set_input_as_handled()
				return

	if event is InputEventMouseMotion and _remove_drag_active:
		var current_cell: Vector2i = _hovered_cell()
		if current_cell != _remove_drag_end_cell:
			_remove_drag_end_cell = current_cell
			_preview_remove_drag()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		var drag_mouse_event: InputEventMouseButton = event as InputEventMouseButton
		if drag_mouse_event.button_index == MOUSE_BUTTON_LEFT and not drag_mouse_event.pressed and _drag_build_active:
			_finish_drag_build()
			get_viewport().set_input_as_handled()
			return

	var placeable_def: Dictionary = _selected_placeable_def()
	if _placement_disabled() or placeable_def.is_empty() or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		return

	if event is InputEventMouseButton and event.pressed:
		var mouse_event: InputEventMouseButton = event
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if _is_drag_buildable(placeable_def):
				_start_drag_build(placeable_def)
			else:
				_apply_placeable(placeable_def)
			get_viewport().set_input_as_handled()

func _toolbuild_selected() -> bool:
	return game_ui and game_ui.has_method("is_toolbuild_selected") and bool(game_ui.call("is_toolbuild_selected"))

func _start_remove_drag() -> void:
	if GameState.is_night or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		return
	if _placement_disabled() or not _toolbuild_selected():
		return
	# A new drag stacks onto any in-progress removal instead of cancelling it, so
	# only clear leftover preview bars here (committed queue bars are preserved).
	_clear_preview_remove_progress_bars()
	_remove_drag_active = true
	_remove_drag_start_cell = _hovered_cell()
	_remove_drag_end_cell = _remove_drag_start_cell
	_preview_remove_drag()

func _preview_remove_drag() -> void:
	_clear_preview_remove_progress_bars()
	_show_drag_selection_rect(_remove_drag_start_cell, _remove_drag_end_cell)
	var committed: Dictionary = _committed_cell_set()
	var removals: Array[Dictionary] = _remove_rectangle_cells(_remove_drag_start_cell, _remove_drag_end_cell)
	for removal: Dictionary in removals:
		var cell: Vector2i = removal.get("cell", Vector2i.ZERO) as Vector2i
		# Cells already queued keep their committed bar; don't preview over them.
		if committed.has(cell):
			continue
		_create_remove_progress(cell, 0.0)

func _finish_remove_drag() -> void:
	if not _remove_drag_active:
		return
	_remove_drag_active = false
	_hide_drag_selection_rect()
	var was_active: bool = _remove_active
	var new_removals: Array[Dictionary] = _remove_rectangle_cells(_remove_drag_start_cell, _hovered_cell())
	_clear_preview_remove_progress_bars()
	# Stack the new selection behind whatever is already being removed instead of
	# replacing it: append to the queue so removals run one after another (a waiting
	# line), each keeping its own progress bar.
	var committed: Dictionary = _committed_cell_set()
	for removal: Dictionary in new_removals:
		var cell: Vector2i = removal.get("cell", Vector2i.ZERO) as Vector2i
		if committed.has(cell):
			continue
		committed[cell] = true
		_remove_queue.append(removal)
		_create_remove_progress(cell, 0.0)
	if _remove_queue.is_empty():
		_cancel_removal()
		return
	_remove_active = true
	# Preserve the in-progress head's elapsed time when stacking; only reset for a
	# brand-new removal run.
	if not was_active:
		_remove_elapsed = 0.0
	_clear_hover()

func _process_removal(delta: float) -> void:
	if not _remove_active:
		return
	if GameState.is_night or _is_inventory_open() or not _toolbuild_selected():
		_cancel_removal()
		return
	if _remove_queue.is_empty():
		_cancel_removal()
		return
	var active_removal: Dictionary = _remove_queue[0] as Dictionary
	var active_cell: Vector2i = active_removal.get("cell", Vector2i.ZERO) as Vector2i
	var active_item_id: String = str(active_removal.get("item_id", ""))
	var current_removal: Dictionary = _removable_at_cell(active_cell)
	if current_removal.is_empty() or str(current_removal.get("item_id", "")) != active_item_id:
		_cancel_removal()
		return
	_remove_elapsed = minf(_remove_elapsed + delta, REMOVE_HOLD_SECONDS)
	var active_progress: ProgressBar = _remove_progress_by_cell.get(active_cell, null) as ProgressBar
	if active_progress != null:
		active_progress.value = (_remove_elapsed / REMOVE_HOLD_SECONDS) * 100.0
	if _remove_elapsed >= REMOVE_HOLD_SECONDS:
		_finish_removal()

func _finish_removal() -> void:
	if not _remove_active or GameState.is_night:
		_cancel_removal()
		return
	if _remove_queue.is_empty():
		_cancel_removal()
		return
	var removal: Dictionary = _remove_queue.pop_front() as Dictionary
	var removed_cell: Vector2i = removal.get("cell", Vector2i.ZERO) as Vector2i
	var removed_item_id: String = str(removal.get("item_id", ""))
	var removed_layer: TileMapLayer = removal.get("layer") as TileMapLayer
	var current_removal: Dictionary = _removable_at_cell(removed_cell)
	if current_removal.is_empty() or str(current_removal.get("item_id", "")) != removed_item_id:
		_cancel_removal()
		return

	_free_remove_progress_for_cell(removed_cell)
	var refund_world_position: Vector2 = previewbuild.to_global(previewbuild.map_to_local(removed_cell))
	_remove_tile(removed_layer, removed_cell)
	# Refund the building's full price back to its currency, flying the seeds/gems
	# to the HUD like a harvest (priceless items refund nothing).
	if game_ui and game_ui.has_method("refund_build"):
		game_ui.call("refund_build", removed_item_id, refund_world_position, 1)
	_remove_elapsed = 0.0
	if _remove_queue.is_empty():
		_cancel_removal()


func pad_place_selected_at_cursor() -> void:
	if _placement_disabled() or _is_inventory_open():
		return
	var placeable_def: Dictionary = _selected_placeable_def()
	if placeable_def.is_empty():
		return
	_cancel_removal()
	if _drag_build_active:
		_finish_drag_build()
		return
	if _is_drag_buildable(placeable_def) and not _pad_skips_preview(placeable_def):
		_start_drag_build(placeable_def)
	else:
		_apply_placeable(placeable_def)


func pad_cancel_build_preview() -> bool:
	if not _drag_build_active:
		return false
	_cancel_drag_build()
	return true


func _pad_skips_preview(placeable_def: Dictionary) -> bool:
	return bool(placeable_def.get("pad_skip_preview", false))


func pad_is_build_preview_active() -> bool:
	return _drag_build_active


func pad_is_cursor_active() -> bool:
	return _pad_cursor_active


func pad_get_cursor_cell() -> Vector2i:
	return _hovered_cell()


func pad_set_cursor_active(active: bool) -> void:
	_pad_cursor_active = active
	if not active:
		return
	_pad_cursor_offset = _mouse_hovered_cell() - _player_cell()


## Snaps the pad build cursor to exactly one tile to the right of the player and activates
## it. Called when the toolbuild is (re-)equipped in pad mode so the cursor starts next to
## the player instead of wherever the hidden mouse last sat.
func pad_place_cursor_right_of_player() -> void:
	_pad_cursor_offset = Vector2i(1, 0)
	_pad_cursor_active = true


func pad_move_cursor(direction: Vector2i) -> void:
	if direction == Vector2i.ZERO:
		return
	if not _pad_cursor_active:
		_pad_cursor_offset = _mouse_hovered_cell() - _player_cell()
		_pad_cursor_active = true
	_pad_cursor_offset += direction


func pad_unbuild_at_cursor() -> void:
	if _placement_disabled() or _is_inventory_open():
		return
	_cancel_drag_build()
	_cancel_removal()
	var cell: Vector2i = _hovered_cell()
	var removal: Dictionary = _removable_at_cell(cell)
	if removal.is_empty():
		return
	var removed_item_id: String = str(removal.get("item_id", ""))
	var removed_layer: TileMapLayer = removal.get("layer") as TileMapLayer
	if removed_layer == null:
		return
	var refund_world_position: Vector2 = previewbuild.to_global(previewbuild.map_to_local(cell))
	_remove_tile(removed_layer, cell)
	if game_ui and game_ui.has_method("refund_build"):
		game_ui.call("refund_build", removed_item_id, refund_world_position, 1)
	_clear_hover()


func pad_rotate_selected_at_cursor() -> bool:
	return rotate_selected_build_direction()


func rotate_selected_build_direction(reverse: bool = false) -> bool:
	var placeable_def: Dictionary = _selected_placeable_def()
	if placeable_def.is_empty() or not _is_directional_placeable(placeable_def):
		return false
	_build_direction = _prev_build_direction(_build_direction) if reverse else _next_build_direction(_build_direction)
	_clear_hover()
	return true

func _remove_tile(layer: TileMapLayer, cell: Vector2i) -> void:
	if layer == plantz:
		if plant_manager and plant_manager.has_method("remove_plant"):
			plant_manager.call("remove_plant", cell, true)
		if plantz.get_cell_source_id(cell) >= 0:
			plantz.erase_cell(cell)
			_flush_plant_layer_visuals()
		return
	if layer == traversable_buildings or layer == blocking_buildings:
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, true)
		if layer.get_cell_source_id(cell) >= 0:
			layer.erase_cell(cell)
			layer.update_internals()
		_refresh_cell_collision(cell)
		_refresh_cell_terrain_speed(cell)
		return
	layer.erase_cell(cell)
	layer.update_internals()
	_refresh_cell_collision(cell)
	_refresh_cell_terrain_speed(cell)

func _removable_at_cell(cell: Vector2i) -> Dictionary:
	var layers: Array[TileMapLayer] = [blocking_buildings, traversable_buildings, plantz, wallz]
	for layer: TileMapLayer in layers:
		if not layer or layer.get_cell_source_id(cell) < 0:
			continue
		var atlas_coords: Vector2i = layer.get_cell_atlas_coords(cell)
		var item_id: String = ItemCatalog.get_placeable_id_for_tile(str(layer.name), atlas_coords)
		if building_object_manager and building_object_manager.has_method("get_building") and (layer == blocking_buildings or layer == traversable_buildings):
			var building: Dictionary = building_object_manager.call("get_building", cell) as Dictionary
			item_id = str(building.get("item_id", item_id))
		if item_id != "" and _can_unbuild_tile(layer, item_id, atlas_coords):
			return {"item_id": item_id, "layer": layer, "cell": cell}
	return {}

func _can_unbuild_tile(layer: TileMapLayer, item_id: String, atlas_coords: Vector2i) -> bool:
	if layer == wallz:
		return item_id == "wall" and atlas_coords == PLAYER_BUILDABLE_WALL_ATLAS
	return true

func _remove_rectangle_cells(start_cell: Vector2i, end_cell: Vector2i) -> Array[Dictionary]:
	var removals: Array[Dictionary] = []
	var seen_cells: Dictionary = {}
	var x_step: int = 1 if end_cell.x >= start_cell.x else -1
	var y_step: int = 1 if end_cell.y >= start_cell.y else -1
	var y: int = start_cell.y
	while true:
		var x: int = start_cell.x
		while true:
			var cell: Vector2i = Vector2i(x, y)
			if not seen_cells.has(cell):
				var removal: Dictionary = _removable_at_cell(cell)
				if not removal.is_empty():
					removals.append(removal)
					seen_cells[cell] = true
			if x == end_cell.x:
				break
			x += x_step
		if y == end_cell.y:
			break
		y += y_step
	return removals

func _create_remove_progress(cell: Vector2i, value: float) -> void:
	if not previewbuild or not previewbuild.tile_set:
		return
	var tile_size: Vector2i = previewbuild.tile_set.tile_size
	var progress_height: float = float(tile_size.y) * REMOVE_PROGRESS_HEIGHT_RATIO
	var remove_progress: ProgressBar = ProgressBar.new()
	remove_progress.name = "BuildingRemovalProgress"
	remove_progress.min_value = 0.0
	remove_progress.max_value = 100.0
	remove_progress.value = value
	remove_progress.show_percentage = false
	remove_progress.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP
	remove_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	remove_progress.z_index = 100
	remove_progress.size = Vector2(REMOVE_PROGRESS_WIDTH, progress_height)
	var cell_center: Vector2 = previewbuild.map_to_local(cell)
	remove_progress.position = cell_center - Vector2(REMOVE_PROGRESS_WIDTH * 0.5, progress_height * 0.5)

	var background: StyleBoxFlat = StyleBoxFlat.new()
	background.bg_color = Color(0.05, 0.05, 0.05, 0.8)
	background.border_width_left = 1
	background.border_width_top = 1
	background.border_width_right = 1
	background.border_width_bottom = 1
	background.border_color = Color(0.9, 0.9, 0.9, 0.9)
	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = Color(0.85, 0.75, 0.25, 1.0)
	remove_progress.add_theme_stylebox_override("background", background)
	remove_progress.add_theme_stylebox_override("fill", fill)
	previewbuild.add_child(remove_progress)
	_remove_progress_by_cell[cell] = remove_progress

func _cancel_removal() -> void:
	_remove_active = false
	_remove_drag_active = false
	_remove_elapsed = 0.0
	_remove_queue.clear()
	_hide_drag_selection_rect()
	_clear_remove_progress_bars()

func _clear_remove_progress_bars() -> void:
	for raw_progress: Variant in _remove_progress_by_cell.values():
		var progress: ProgressBar = raw_progress as ProgressBar
		if progress != null and is_instance_valid(progress):
			progress.queue_free()
	_remove_progress_by_cell.clear()

# Cells committed to the active removal queue (drives dedup + bar preservation when
# a fresh drag stacks onto an in-progress removal).
func _committed_cell_set() -> Dictionary:
	var cells: Dictionary = {}
	for removal: Dictionary in _remove_queue:
		cells[removal.get("cell", Vector2i.ZERO) as Vector2i] = true
	return cells

# Free only transient drag-preview bars, keeping the bars for cells already
# committed to the active removal queue.
func _clear_preview_remove_progress_bars() -> void:
	var committed: Dictionary = _committed_cell_set()
	for cell: Variant in _remove_progress_by_cell.keys():
		if committed.has(cell):
			continue
		var progress: ProgressBar = _remove_progress_by_cell[cell] as ProgressBar
		if progress != null and is_instance_valid(progress):
			progress.queue_free()
		_remove_progress_by_cell.erase(cell)

func _free_remove_progress_for_cell(cell: Vector2i) -> void:
	var progress: ProgressBar = _remove_progress_by_cell.get(cell, null) as ProgressBar
	if progress != null and is_instance_valid(progress):
		progress.queue_free()
	_remove_progress_by_cell.erase(cell)

func _resolve_atlas_source_id() -> void:
	var ref: TileMapLayer = previewbuild if previewbuild else wallz
	if not ref or not ref.tile_set:
		return

	var ts: TileSet = ref.tile_set
	for i in range(ts.get_source_count()):
		var sid: int = ts.get_source_id(i)
		if ts.get_source(sid) is TileSetAtlasSource:
			_atlas_source_id = sid
			return

# The flow field only recomputes the wall collision mask at the start of night, so a
# wall built or removed during the day would leave the player walking through new walls
# or stuck on removed ones. After any change to a collision layer (wallz / blocking
# buildings), re-derive that single cell's blocked state and push it to the flow field.
# This updates just the wall index, not the (costly) flow/distance/bottleneck fields.
func _refresh_cell_collision(cell: Vector2i) -> void:
	var ff: Object = _resolve_flow_field()
	if ff == null or not ff.has_method("set_cell_blocked"):
		return
	var blocked: bool = false
	if wallz and wallz.get_cell_source_id(cell) >= 0:
		blocked = true
	elif blocking_buildings and blocking_buildings.get_cell_source_id(cell) >= 0:
		blocked = true
	ff.call("set_cell_blocked", cell, blocked)

func _sync_terrain_speed_cells() -> void:
	var ff: Object = _resolve_flow_field()
	if ff == null:
		return
	if ff.has_method("clear_cell_speed_multipliers"):
		ff.call("clear_cell_speed_multipliers")
	if traversable_buildings == null or not ff.has_method("set_cell_speed_multiplier"):
		return
	for raw_cell: Variant in traversable_buildings.get_used_cells():
		var cell: Vector2i = raw_cell as Vector2i
		_refresh_cell_terrain_speed(cell)

func _refresh_cell_terrain_speed(cell: Vector2i) -> void:
	var ff: Object = _resolve_flow_field()
	if ff == null or not ff.has_method("set_cell_speed_multiplier"):
		return
	var speed_multiplier: float = DEFAULT_TERRAIN_SPEED_MULTIPLIER
	if traversable_buildings != null and traversable_buildings.get_cell_source_id(cell) >= 0:
		var atlas_coords: Vector2i = traversable_buildings.get_cell_atlas_coords(cell)
		var item_id: String = ItemCatalog.get_placeable_id_for_tile(str(traversable_buildings.name), atlas_coords)
		if item_id != "":
			var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
			speed_multiplier = clampf(float(item_def.get("speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER)), 0.01, 1.0)
	ff.call("set_cell_speed_multiplier", cell, speed_multiplier)

func _resolve_flow_field() -> Object:
	if _flow_field and is_instance_valid(_flow_field):
		return _flow_field
	var scene: Node = get_tree().get_current_scene()
	if scene:
		_flow_field = scene.get_node_or_null("CPP/FlowFieldNative")
	return _flow_field

func _draw_preview(cell: Vector2i, atlas_coords: Vector2i, item_id: String, placeable_def: Dictionary) -> void:
	if _atlas_source_id < 0:
		return

	previewbuild.set_cell(
		cell,
		_atlas_source_id,
		atlas_coords,
		_alternative_from_placeable(placeable_def)
	)
	_preview_cells.append(cell)
	_hover_item_id = item_id
	_refresh_preview_visual_state(placeable_def)
	previewbuild.update_internals()

# Placeables build as a click-drag rectangle chunk by default, placed up to the
# affordable/limited count while skipping occupied or invalid cells. Specific
# future placeables can opt out with `"drag_buildable": false`.
func _is_drag_buildable(placeable_def: Dictionary) -> bool:
	return bool(placeable_def.get("drag_buildable", true))

# Placement sound for a finished chunk build. This preserves the old per-item
# behavior: roses play the plant sound, other buildings stay silent unless they
# define a build sound later.
func _drag_build_sound(item_id: String) -> StringName:
	return &"plant" if item_id == "rose" else &""

func _start_drag_build(placeable_def: Dictionary) -> void:
	var item_id: String = str(placeable_def.get("id", ""))
	if _affordable_quantity(item_id) <= 0:
		return
	_set_drag_build_active(true)
	_drag_build_item_id = item_id
	_drag_build_start_cell = _hovered_cell()
	_drag_build_end_cell = _drag_build_start_cell
	_draw_drag_build_preview(placeable_def, _affordable_quantity(item_id))

func _draw_drag_build_preview(placeable_def: Dictionary, available: int) -> void:
	_clear_hover()
	_drag_build_preview_limit = available
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	if atlas_coords == Vector2i(-1, -1) or available <= 0:
		return
	var target_layer: TileMapLayer = _target_tile_layer(str(placeable_def.get("target_layer", "wallz")))
	if not target_layer:
		return
	var valid_cells: Array[Vector2i] = _drag_build_rectangle_cells(
		_drag_build_start_cell,
		_drag_build_end_cell,
		target_layer,
		placeable_def,
		available
	)
	for cell: Vector2i in valid_cells:
		previewbuild.set_cell(cell, _atlas_source_id, atlas_coords, _alternative_from_placeable(placeable_def))
	previewbuild.modulate = PREVIEW_NORMAL_COLOR
	_preview_cells = valid_cells
	_hover_active = not _preview_cells.is_empty()
	_hover_item_id = str(placeable_def.get("id", "")) if _hover_active else ""
	_hover_atlas_coords = atlas_coords
	_show_drag_selection_rect(_drag_build_start_cell, _drag_build_end_cell)
	previewbuild.update_internals()

func _drag_build_rectangle_cells(
	start_cell: Vector2i,
	end_cell: Vector2i,
	target_layer: TileMapLayer,
	placeable_def: Dictionary,
	limit: int
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if limit <= 0:
		return cells
	var x_step: int = 1 if end_cell.x >= start_cell.x else -1
	var y_step: int = 1 if end_cell.y >= start_cell.y else -1
	var y: int = start_cell.y
	while true:
		var x: int = start_cell.x
		while true:
			var cell: Vector2i = Vector2i(x, y)
			if (
				_is_valid_placeable_cell(cell, target_layer, placeable_def)
				and not _drag_build_candidate_blocked_by_batch(cell, target_layer, placeable_def, cells)
			):
				cells.append(cell)
				if cells.size() >= limit:
					return cells
			if x == end_cell.x:
				break
			x += x_step
		if y == end_cell.y:
			break
		y += y_step
	return cells

func _drag_build_candidate_blocked_by_batch(
	cell: Vector2i,
	target_layer: TileMapLayer,
	placeable_def: Dictionary,
	accepted_cells: Array[Vector2i]
) -> bool:
	if accepted_cells.is_empty():
		return false
	if str(placeable_def.get("category", "")) != "turret":
		return false
	var candidate_turret_data: TurretData = _turret_data_from_placeable(placeable_def)
	if candidate_turret_data == null:
		return false
	if candidate_turret_data.build_in_range:
		return false
	var build_range: float = candidate_turret_data.build_range
	if build_range <= 0.0:
		return false
	var candidate_world_position: Vector2 = target_layer.to_global(target_layer.map_to_local(cell))
	var range_squared: float = build_range * build_range
	for accepted_cell: Vector2i in accepted_cells:
		var accepted_world_position: Vector2 = target_layer.to_global(target_layer.map_to_local(accepted_cell))
		if candidate_world_position.distance_squared_to(accepted_world_position) <= range_squared:
			return true
	return false

func _finish_drag_build() -> void:
	var placeable_def: Dictionary = _selected_placeable_def()
	var item_id: String = _drag_build_item_id
	if _placement_disabled() or str(placeable_def.get("id", "")) != item_id:
		_cancel_drag_build()
		return
	var target_layer: TileMapLayer = _target_tile_layer(str(placeable_def.get("target_layer", "wallz")))
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	var available: int = _affordable_quantity(item_id)
	var cells: Array[Vector2i] = []
	_drag_build_end_cell = _hovered_cell()
	if target_layer and atlas_coords != Vector2i(-1, -1):
		cells = _drag_build_rectangle_cells(_drag_build_start_cell, _drag_build_end_cell, target_layer, placeable_def, available)
	_clear_hover()
	_hide_drag_selection_rect()
	_set_drag_build_active(false)
	_drag_build_item_id = ""
	if cells.is_empty():
		if _placement_attempt_needs_grass_alert(_drag_build_start_cell, _drag_build_end_cell, placeable_def):
			_show_tutorial_alert(ALERT_NEEDS_GRASS_KEY)
		return
	# Pay for exactly the cells we are about to place; bail if the spend fails.
	if not game_ui or not game_ui.has_method("try_purchase_build"):
		return
	if not bool(game_ui.call("try_purchase_build", item_id, cells.size())):
		return
	for cell: Vector2i in cells:
		target_layer.set_cell(cell, _atlas_source_id, atlas_coords, _alternative_from_placeable(placeable_def))
		if _target_layer_affects_collision(target_layer):
			_refresh_cell_collision(cell)
		_refresh_cell_terrain_speed(cell)
		_after_placeable_placed(cell, placeable_def, false)
		_play_build_fx_at_cell(cell, target_layer)
	target_layer.update_internals()
	if target_layer == plantz:
		_flush_plant_layer_visuals()
	var sound: StringName = _drag_build_sound(item_id)
	if sound != &"":
		Sfx.play_sound(sound)

func _cancel_drag_build() -> void:
	_set_drag_build_active(false)
	_drag_build_item_id = ""
	_hide_drag_selection_rect()
	_clear_hover()

func _set_drag_build_active(active: bool) -> void:
	if _drag_build_active == active:
		return
	_drag_build_active = active
	build_preview_changed.emit(_drag_build_active)

# How many of item_id the player can currently afford. Replaces the old inventory
# count: buildings are paid for directly from currency, so affordability is the cap.
func _affordable_quantity(item_id: String) -> int:
	if not game_ui or not game_ui.has_method("get_build_affordable_quantity"):
		return 0
	return int(game_ui.call("get_build_affordable_quantity", item_id))

func _can_afford(item_id: String) -> bool:
	return game_ui and game_ui.has_method("can_afford_build") and bool(game_ui.call("can_afford_build", item_id, 1))

func _apply_placeable(placeable_def: Dictionary) -> void:
	if _atlas_source_id < 0:
		return
	var atlas_coords: Vector2i = _atlas_coords_from_placeable(placeable_def)
	if atlas_coords == Vector2i(-1, -1):
		return

	var target_layer: TileMapLayer = _target_tile_layer(str(placeable_def.get("target_layer", "wallz")))
	if not target_layer:
		return

	_hover_cell = _hovered_cell()
	if not _is_valid_placeable_cell(_hover_cell, target_layer, placeable_def):
		if _requires_grass_green_floor(placeable_def) and not _is_grass_green_floor_cell(_hover_cell):
			_show_tutorial_alert(ALERT_NEEDS_GRASS_KEY)
			return
		_notify("invalid construction")
		return

	var item_id: String = str(placeable_def.get("id", ""))
	if not _can_afford(item_id):
		_notify("can't afford")
		return
	if not game_ui or not game_ui.has_method("try_purchase_build"):
		return
	if not bool(game_ui.call("try_purchase_build", item_id, 1)):
		_notify("can't afford")
		return

	_clear_other_build_layer(target_layer, _hover_cell)
	target_layer.set_cell(
		_hover_cell,
		_atlas_source_id,
		atlas_coords,
		_alternative_from_placeable(placeable_def)
	)
	target_layer.update_internals()
	if _target_layer_affects_collision(target_layer):
		_refresh_cell_collision(_hover_cell)
	_refresh_cell_terrain_speed(_hover_cell)
	_after_placeable_placed(_hover_cell, placeable_def)
	_play_build_fx_at_cell(_hover_cell, target_layer)

func _target_tile_layer(layer_name: String) -> TileMapLayer:
	if layer_name == "plantz":
		return plantz
	if layer_name == "traversable_buildings":
		return traversable_buildings
	if layer_name == "blocking_buildings":
		return blocking_buildings
	# Backward compatibility: old "buildings" target maps to traversable_buildings.
	if layer_name == "buildings":
		return traversable_buildings
	return wallz

func _target_layer_affects_collision(target_layer: TileMapLayer) -> bool:
	return target_layer == wallz or target_layer == blocking_buildings

func _clear_other_build_layer(target_layer: TileMapLayer, cell: Vector2i) -> void:
	if target_layer != wallz and wallz:
		wallz.erase_cell(cell)
		wallz.update_internals()
	if target_layer != plantz and plantz:
		plantz.erase_cell(cell)
		_flush_plant_layer_visuals()
		if plant_manager and plant_manager.has_method("remove_plant"):
			plant_manager.call("remove_plant", cell, false)
	if target_layer != traversable_buildings and traversable_buildings:
		traversable_buildings.erase_cell(cell)
		traversable_buildings.update_internals()
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, false)
		_refresh_cell_terrain_speed(cell)
	if target_layer != blocking_buildings and blocking_buildings:
		blocking_buildings.erase_cell(cell)
		blocking_buildings.update_internals()
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, false)

# True only when `cell` is a real floor tile with no blocking wall on it. Used by
# placeables (e.g. turret1) that may only be built on free walkable ground. This is
# a placement-time guard; it does not affect navigation/flowfields.
func _is_free_walkable_cell(cell: Vector2i) -> bool:
	if floorz and floorz.get_cell_source_id(cell) < 0:
		return false
	if wallz and wallz.get_cell_source_id(cell) >= 0:
		return false
	return true

func _is_placeable_occupied(cell: Vector2i, target_layer: TileMapLayer, placeable_def: Dictionary) -> bool:
	if bool(placeable_def.get("occupies_cell", true)) and target_layer.get_cell_source_id(cell) >= 0:
		return true
	if wallz and wallz != target_layer and wallz.get_cell_source_id(cell) >= 0:
		return true
	if plantz and plantz != target_layer and plantz.get_cell_source_id(cell) >= 0:
		return true
	if traversable_buildings and traversable_buildings != target_layer and traversable_buildings.get_cell_source_id(cell) >= 0:
		return true
	if blocking_buildings and blocking_buildings != target_layer and blocking_buildings.get_cell_source_id(cell) >= 0:
		return true
	return _is_occupied_by_group_node(cell, placeable_def)

func _is_valid_placeable_cell(cell: Vector2i, target_layer: TileMapLayer, placeable_def: Dictionary) -> bool:
	if _is_water_source_cell(cell):
		return false
	if _requires_grass_green_floor(placeable_def) and not _is_grass_green_floor_cell(cell):
		return false
	if bool(placeable_def.get("requires_walkable_floor", false)) and not _is_free_walkable_cell(cell):
		return false
	if not _turret_range_blocker_for_cell(cell, placeable_def).is_empty():
		return false
	return not _is_placeable_occupied(cell, target_layer, placeable_def)

func _requires_grass_green_floor(placeable_def: Dictionary) -> bool:
	var item_id: String = str(placeable_def.get("id", ""))
	return item_id == "rose" or item_id == "turret1" or bool(placeable_def.get("requires_grass_green_floor", false))

func _is_grass_green_floor_cell(cell: Vector2i) -> bool:
	if floorz == null or floorz.get_cell_source_id(cell) < 0:
		return false
	return floorz.get_cell_atlas_coords(cell) == GRASS_GREEN_FLOOR_ATLAS

func _placement_attempt_needs_grass_alert(start_cell: Vector2i, end_cell: Vector2i, placeable_def: Dictionary) -> bool:
	if not _requires_grass_green_floor(placeable_def):
		return false
	var x_step: int = 1 if end_cell.x >= start_cell.x else -1
	var y_step: int = 1 if end_cell.y >= start_cell.y else -1
	var y: int = start_cell.y
	while true:
		var x: int = start_cell.x
		while true:
			var cell: Vector2i = Vector2i(x, y)
			if not _is_grass_green_floor_cell(cell):
				return true
			if x == end_cell.x:
				break
			x += x_step
		if y == end_cell.y:
			break
		y += y_step
	return false

func _show_tutorial_alert(key: String) -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var tutorial: Node = scene.get_node_or_null("GameUI/top anchor/tutorial")
	if tutorial != null and tutorial.has_method("show_alert"):
		tutorial.call("show_alert", key)

func _is_water_source_cell(cell: Vector2i) -> bool:
	return watersources != null and watersources.get_cell_source_id(cell) >= 0

func _turret_range_blocker_for_cell(cell: Vector2i, placeable_def: Dictionary) -> Dictionary:
	if str(placeable_def.get("category", "")) != "turret":
		return {}
	var candidate_turret_data: TurretData = _turret_data_from_placeable(placeable_def)
	if candidate_turret_data == null:
		return {}
	if candidate_turret_data.build_in_range:
		return {}
	if blocking_buildings == null:
		return {}
	var candidate_world_position: Vector2 = blocking_buildings.to_global(blocking_buildings.map_to_local(cell))
	var best_blocker: Dictionary = {}
	var best_distance_squared: float = INF
	for raw_turret_cell: Variant in blocking_buildings.get_used_cells():
		var turret_cell: Vector2i = raw_turret_cell as Vector2i
		var turret_item_id: String = _turret_item_id_at_cell(turret_cell)
		if turret_item_id == "":
			continue
		var turret_data: TurretData = ItemCatalog.get_turret_data(turret_item_id)
		if turret_data == null or turret_data.build_in_range:
			continue
		var build_range: float = turret_data.build_range
		if build_range <= 0.0:
			continue
		var range_squared: float = build_range * build_range
		var turret_world_position: Vector2 = blocking_buildings.to_global(blocking_buildings.map_to_local(turret_cell))
		var distance_squared: float = candidate_world_position.distance_squared_to(turret_world_position)
		if distance_squared <= range_squared and distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			best_blocker = {
				"cell": turret_cell,
				"range": build_range,
			}
	return best_blocker

func _turret_data_from_placeable(placeable_def: Dictionary) -> TurretData:
	var item_id: String = str(placeable_def.get("id", ""))
	if item_id == "":
		return null
	return ItemCatalog.get_turret_data(item_id)

func _refresh_preview_visual_state(placeable_def: Dictionary) -> void:
	var blocked: bool = not _turret_range_blocker_for_cell(_hover_cell, placeable_def).is_empty()
	previewbuild.modulate = PREVIEW_FORBIDDEN_RANGE_COLOR if blocked else PREVIEW_NORMAL_COLOR

func _turret_item_id_at_cell(cell: Vector2i) -> String:
	if blocking_buildings == null or blocking_buildings.get_cell_source_id(cell) < 0:
		return ""
	var item_id: String = ItemCatalog.get_placeable_id_for_tile(str(blocking_buildings.name), blocking_buildings.get_cell_atlas_coords(cell))
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if str(item_def.get("category", "")) != "turret":
		return ""
	return item_id

func _after_placeable_placed(cell: Vector2i, placeable_def: Dictionary, play_placement_sound: bool = true) -> void:
	var placeable_category: String = str(placeable_def.get("category", ""))
	if placeable_category == "plant" and plant_manager and plant_manager.has_method("add_plant"):
		plant_manager.call("add_plant", cell)
	var placeable_id: String = str(placeable_def.get("id", ""))
	if placeable_id == "rose" and play_placement_sound:
		Sfx.play_sound(&"plant")
	if _uses_building_object_manager(placeable_def) and building_object_manager and building_object_manager.has_method("add_building"):
		building_object_manager.call("add_building", cell, placeable_def)
	if (placeable_id == "reservoir" or placeable_id == "small_reservoir") and reservoir_system != null and reservoir_system.has_method("request_irrigation_from_cell"):
		reservoir_system.call("request_irrigation_from_cell", cell)

func _preload_build_fx_pool() -> void:
	var count: int = maxi(build_fx_pool_size, 0)
	for index: int in range(count):
		var build_fx: Node2D = BUILD_FX_SCENE.instantiate() as Node2D
		if build_fx == null:
			continue
		build_fx.name = "BuildFX%02d" % index
		build_fx.visible = false
		build_fx.z_as_relative = false
		build_fx.z_index = BUILD_FX_Z_INDEX
		add_child(build_fx)
		_build_fx_pool.append(build_fx)

func _play_build_fx_at_cell(cell: Vector2i, target_layer: TileMapLayer) -> void:
	if _build_fx_pool.is_empty() or target_layer == null:
		return
	var build_fx: Node2D = _next_available_build_fx()
	build_fx.global_position = target_layer.to_global(target_layer.map_to_local(cell))
	build_fx.visible = true
	for particle: CPUParticles2D in _particles_for_build_fx(build_fx):
		particle.emitting = false
		particle.restart()
		particle.emitting = true

func _next_available_build_fx() -> Node2D:
	var pool_count: int = _build_fx_pool.size()
	for offset: int in range(pool_count):
		var index: int = (_build_fx_pool_cursor + offset) % pool_count
		var build_fx: Node2D = _build_fx_pool[index]
		if not _is_build_fx_busy(build_fx):
			_build_fx_pool_cursor = (index + 1) % pool_count
			return build_fx

	var fallback_index: int = _build_fx_pool_cursor
	_build_fx_pool_cursor = (_build_fx_pool_cursor + 1) % pool_count
	return _build_fx_pool[fallback_index]

func _is_build_fx_busy(build_fx: Node2D) -> bool:
	for particle: CPUParticles2D in _particles_for_build_fx(build_fx):
		if particle.emitting:
			return true
	build_fx.visible = false
	return false

func _particles_for_build_fx(root: Node) -> Array[CPUParticles2D]:
	var particles: Array[CPUParticles2D] = []
	_collect_build_fx_particles(root, particles)
	return particles

func _collect_build_fx_particles(root: Node, particles: Array[CPUParticles2D]) -> void:
	for child: Node in root.get_children():
		if child is CPUParticles2D:
			particles.append(child as CPUParticles2D)
		_collect_build_fx_particles(child, particles)

func _uses_building_object_manager(placeable_def: Dictionary) -> bool:
	var placeable_category: String = str(placeable_def.get("category", ""))
	var light_source: float = float(placeable_def.get("light_source", 0.0))
	if light_source > 0.0:
		return true
	return placeable_category == "furniture" or placeable_category == "turret" or placeable_category == "trap" or placeable_category == "shop_counter" or placeable_category == "irrigation"

func _is_occupied_by_group_node(cell: Vector2i, placeable_def: Dictionary) -> bool:
	var map_layer: TileMapLayer = previewbuild if previewbuild else wallz
	if not map_layer:
		return false
	var item_id: String = str(placeable_def.get("id", ""))
	for group_name in occupied_groups:
		if item_id == "rose" and group_name == "player":
			continue
		var nodes: Array[Node] = get_tree().get_nodes_in_group(group_name)
		for node in nodes:
			if node is Node2D:
				var occupant: Node2D = node as Node2D
				var occupant_cell: Vector2i = map_layer.local_to_map(map_layer.to_local(occupant.global_position))
				if occupant_cell == cell:
					return true
	return false

func _notify(message: String) -> void:
	if not notif:
		return
	if notif.has_method("show_notif"):
		notif.call("show_notif", message)

func _clear_hover() -> void:
	previewbuild.modulate = PREVIEW_NORMAL_COLOR
	if not _hover_active and _preview_cells.is_empty():
		_hover_item_id = ""
		return
	for cell: Vector2i in _preview_cells:
		previewbuild.erase_cell(cell)
	_preview_cells.clear()
	previewbuild.update_internals()
	_hover_active = false
	_hover_item_id = ""
	_hover_atlas_coords = Vector2i(-1, -1)

func _hovered_cell() -> Vector2i:
	if _pad_cursor_active:
		return _player_cell() + _pad_cursor_offset
	return _mouse_hovered_cell()

func _mouse_hovered_cell() -> Vector2i:
	var world: Vector2 = previewbuild.get_global_mouse_position()
	return previewbuild.local_to_map(previewbuild.to_local(world))

func _player_cell() -> Vector2i:
	var player: Node2D = get_tree().get_first_node_in_group("player") as Node2D
	if player == null:
		return _mouse_hovered_cell()
	return previewbuild.local_to_map(previewbuild.to_local(player.global_position))

func _ensure_drag_selection_rect() -> void:
	if _drag_selection_rect != null and is_instance_valid(_drag_selection_rect):
		return
	_drag_selection_rect = Panel.new()
	_drag_selection_rect.name = "DragSelectionRect"
	_drag_selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drag_selection_rect.z_index = 60
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = DRAG_SELECT_FILL_COLOR
	style.set_border_width_all(2)
	style.border_color = DRAG_SELECT_BORDER_COLOR
	style.set_corner_radius_all(2)
	_drag_selection_rect.add_theme_stylebox_override("panel", style)
	# Parented to previewbuild so it shares the tilemap's transform (cell-aligned).
	previewbuild.add_child(_drag_selection_rect)

# Frames the bounding box spanning start_cell..end_cell with the green outline.
func _show_drag_selection_rect(start_cell: Vector2i, end_cell: Vector2i) -> void:
	if previewbuild == null or previewbuild.tile_set == null:
		return
	_ensure_drag_selection_rect()
	var tile_size: Vector2 = Vector2(previewbuild.tile_set.tile_size)
	var min_cell: Vector2i = Vector2i(mini(start_cell.x, end_cell.x), mini(start_cell.y, end_cell.y))
	var max_cell: Vector2i = Vector2i(maxi(start_cell.x, end_cell.x), maxi(start_cell.y, end_cell.y))
	# map_to_local returns cell centers; expand by half a tile to cover the full cells.
	var top_left: Vector2 = previewbuild.map_to_local(min_cell) - tile_size * 0.5
	var bottom_right: Vector2 = previewbuild.map_to_local(max_cell) + tile_size * 0.5
	_drag_selection_rect.position = top_left
	_drag_selection_rect.size = bottom_right - top_left
	_drag_selection_rect.visible = true

func _hide_drag_selection_rect() -> void:
	if _drag_selection_rect != null and is_instance_valid(_drag_selection_rect):
		_drag_selection_rect.visible = false

func has_single_tile_preview() -> bool:
	return _hover_active and _preview_cells.size() == 1

func get_preview_item_id() -> String:
	return _hover_item_id

func get_preview_cell() -> Vector2i:
	return _hover_cell

func get_preview_direction() -> Vector2i:
	return _build_direction

func _flush_plant_layer_visuals() -> void:
	if not plantz:
		return
	plantz.update_internals()
	plantz.queue_redraw()
	if _plant_layer_flush_queued:
		return
	_plant_layer_flush_queued = true
	call_deferred("_flush_plant_layer_visuals_deferred")

func _flush_plant_layer_visuals_deferred() -> void:
	_plant_layer_flush_queued = false
	if not plantz:
		return
	plantz.update_internals()
	plantz.queue_redraw()

func _selected_placeable_def() -> Dictionary:
	if not game_ui or not game_ui.has_method("get_selected_build_item_id"):
		return {}
	if _placement_disabled():
		return {}
	var placeable_def: Dictionary = ItemCatalog.get_placeable_def(String(game_ui.call("get_selected_build_item_id")))
	if _is_directional_placeable(placeable_def):
		var directed_def: Dictionary = placeable_def.duplicate(true)
		directed_def["direction"] = _build_direction
		return directed_def
	return placeable_def

func _is_inventory_open() -> bool:
	return game_ui and game_ui.has_method("is_inventory_open") and bool(game_ui.call("is_inventory_open"))

func _placement_disabled() -> bool:
	if GameState.is_night:
		return true
	return false

func _atlas_coords_from_placeable(placeable_def: Dictionary) -> Vector2i:
	var raw: Variant = placeable_def.get("atlas", Vector2i(-1, -1))
	if raw is Vector2i:
		return raw
	if raw is Vector2:
		return Vector2i(int(raw.x), int(raw.y))
	if raw is Array and raw.size() == 2:
		return Vector2i(int(raw[0]), int(raw[1]))
	return Vector2i(-1, -1)

func _is_directional_placeable(placeable_def: Dictionary) -> bool:
	return bool(placeable_def.get("directional", false))

func _next_build_direction(direction: Vector2i) -> Vector2i:
	if direction == DIRECTION_RIGHT:
		return DIRECTION_DOWN
	if direction == DIRECTION_DOWN:
		return DIRECTION_LEFT
	if direction == DIRECTION_LEFT:
		return DIRECTION_UP
	return DIRECTION_RIGHT

func _prev_build_direction(direction: Vector2i) -> Vector2i:
	if direction == DIRECTION_RIGHT:
		return DIRECTION_UP
	if direction == DIRECTION_UP:
		return DIRECTION_LEFT
	if direction == DIRECTION_LEFT:
		return DIRECTION_DOWN
	return DIRECTION_RIGHT

func _alternative_from_placeable(placeable_def: Dictionary) -> int:
	if not _is_directional_placeable(placeable_def):
		return 0
	var direction: Vector2i = placeable_def.get("direction", DIRECTION_RIGHT) as Vector2i
	return _alternative_from_direction(direction)

func _alternative_from_direction(direction: Vector2i) -> int:
	if direction == DIRECTION_LEFT:
		return TILE_TRANSFORM_FLIP_H | TILE_TRANSFORM_FLIP_V
	if direction == DIRECTION_DOWN:
		return TILE_TRANSFORM_TRANSPOSE | TILE_TRANSFORM_FLIP_H
	if direction == DIRECTION_UP:
		return TILE_TRANSFORM_TRANSPOSE | TILE_TRANSFORM_FLIP_V
	return 0
