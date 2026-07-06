extends Node

signal build_preview_changed(is_active: bool)

const REMOVE_HOLD_SECONDS: float = 0.2
const BUILD_FX_SCENE: PackedScene = preload("res://scenes/particles/buildFX.tscn")
const BUILD_FX_Z_INDEX: int = -62
const PLAYER_BUILDABLE_WALL_ATLAS: Vector2i = Vector2i(11, 1)
const DEFAULT_TERRAIN_SPEED_MULTIPLIER: float = 1.0
const TILE_TRANSFORM_FLIP_H: int = 4096
const TILE_TRANSFORM_FLIP_V: int = 8192
const TILE_TRANSFORM_TRANSPOSE: int = 16384
const DIRECTION_RIGHT: Vector2i = Vector2i(1, 0)
const DIRECTION_DOWN: Vector2i = Vector2i(0, 1)
const DIRECTION_LEFT: Vector2i = Vector2i(-1, 0)
const DIRECTION_UP: Vector2i = Vector2i(0, -1)
const ALERT_NEEDS_GRASS_KEY: String = "alert.needs_grass"
const FENCE_ITEM_ID: String = "fence"
const FENCE_NEIGHBOR_NORTH: int = 1
const FENCE_NEIGHBOR_EAST: int = 2
const FENCE_NEIGHBOR_SOUTH: int = 4
const FENCE_NEIGHBOR_WEST: int = 8
const FENCE_ATLAS_BY_MASK: Dictionary = {
	0: Vector2i(5, 7),
	1: Vector2i(4, 7),
	2: Vector2i(5, 6),
	3: Vector2i(4, 8),
	4: Vector2i(4, 7),
	5: Vector2i(4, 7),
	6: Vector2i(4, 6),
	7: Vector2i(8, 7),
	8: Vector2i(5, 6),
	9: Vector2i(6, 8),
	10: Vector2i(5, 6),
	11: Vector2i(7, 7),
	12: Vector2i(6, 6),
	13: Vector2i(8, 6),
	14: Vector2i(7, 6),
	15: Vector2i(7, 8),
}

@export var floorz: TileMapLayer
@export var watersources: TileMapLayer
@export var wallz: TileMapLayer
@export var plantz: TileMapLayer
@export var traversable_buildings: TileMapLayer
@export var blocking_buildings: TileMapLayer
@export var fences: TileMapLayer
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
var _build_preview: BuildPreviewController = BuildPreviewController.new()
var _placement_service: BuildPlacementService = BuildPlacementService.new()

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
var _remove_drag_active: bool = false
var _remove_drag_start_cell: Vector2i = Vector2i.ZERO
var _remove_drag_end_cell: Vector2i = Vector2i.ZERO
var _keyboard_unbuild_held: bool = false
var _keyboard_unbuild_cell: Vector2i = Vector2i.ZERO
var _build_direction: Vector2i = DIRECTION_RIGHT
var _build_fx_pool: Array[Node2D] = []
var _build_fx_pool_cursor: int = 0

func _ready() -> void:
	_resolve_level_layers()
	_resolve_atlas_source_id()
	_placement_service.setup(self)
	_build_preview.setup(self)
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
	if fences == null:
		fences = get_node_or_null("../MonTilemap/fences") as TileMapLayer

func _configure_preview_layer() -> void:
	_build_preview.configure_layer()

func _on_game_mode_changed(is_night: bool) -> void:
	if not is_night:
		return
	# Removal is forbidden at night. Cancel immediately rather than waiting for
	# the next process tick to clear a hold that began during the day.
	_cancel_removal()
	_cancel_drag_build()

func _process(delta: float) -> void:
	_update_keyboard_unbuild()
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

	if _build_preview.matches_hover(cell, atlas_coords, item_id):
		_refresh_preview_visual_state(placeable_def)
		return

	_clear_hover()
	_build_preview.set_hover(cell, atlas_coords)
	_draw_preview(cell, atlas_coords, item_id, placeable_def)

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event: InputEventKey = event as InputEventKey
		if key_event.physical_keycode == KEY_X:
			if key_event.pressed and not key_event.echo:
				_keyboard_unbuild_held = true
				_start_keyboard_unbuild_at_hover()
				get_viewport().set_input_as_handled()
				return
			if not key_event.pressed:
				_keyboard_unbuild_held = false
				_cancel_removal()
				get_viewport().set_input_as_handled()
				return
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

# True while any build tool (gardening or hammer) is equipped: right-click removal works for
# either, so the player can deconstruct regardless of which build tool is in hand.
func _build_tool_selected() -> bool:
	return game_ui and game_ui.has_method("is_build_tool_selected") and bool(game_ui.call("is_build_tool_selected"))

func _start_remove_drag() -> void:
	if GameState.is_night or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		return
	if _placement_disabled() or not _build_tool_selected():
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
	if GameState.is_night or _is_inventory_open() or not _keyboard_unbuild_held:
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
	_build_preview.set_remove_progress_value(active_cell, (_remove_elapsed / REMOVE_HOLD_SECONDS) * 100.0)
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

func _update_keyboard_unbuild() -> void:
	if not _keyboard_unbuild_held:
		return
	if GameState.is_night or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		_cancel_removal()
		return
	var cell: Vector2i = _hovered_cell()
	if _remove_active and cell == _keyboard_unbuild_cell:
		return
	if _remove_active:
		_cancel_removal()
	_keyboard_unbuild_cell = cell
	_start_keyboard_unbuild_at_hover()


func _start_keyboard_unbuild_at_hover() -> void:
	if GameState.is_night or _is_inventory_open() or get_viewport().gui_get_hovered_control() != null:
		return
	if _placement_disabled():
		return
	_cancel_drag_build_preserving_selection()
	_clear_preview_remove_progress_bars()
	var cell: Vector2i = _hovered_cell()
	var removal: Dictionary = _removable_at_cell(cell)
	if removal.is_empty():
		_cancel_removal()
		return
	_keyboard_unbuild_cell = cell
	_remove_queue.clear()
	_remove_queue.append(removal)
	_remove_elapsed = 0.0
	_remove_active = true
	_create_remove_progress(cell, 0.0)
	_clear_hover()


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
	return _build_preview.is_pad_cursor_active()


func pad_get_cursor_cell() -> Vector2i:
	return _hovered_cell()


func pad_set_cursor_active(active: bool) -> void:
	_build_preview.set_pad_cursor_active(active)


## Snaps the pad build cursor to exactly one tile to the right of the player and activates
## it. Called when the toolbuild is (re-)equipped in pad mode so the cursor starts next to
## the player instead of wherever the hidden mouse last sat.
func pad_place_cursor_right_of_player() -> void:
	_build_preview.place_cursor_right_of_player()


func pad_move_cursor(direction: Vector2i) -> void:
	_build_preview.move_pad_cursor(direction)


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
		_refresh_cell_terrain_speed(cell)
		return
	if layer == traversable_buildings or layer == blocking_buildings or layer == fences:
		_clear_pasteque_irrigation_before_unbuild(layer, cell)
		if building_object_manager and building_object_manager.has_method("remove_building"):
			building_object_manager.call("remove_building", cell, true)
		if layer.get_cell_source_id(cell) >= 0:
			layer.erase_cell(cell)
			layer.update_internals()
		_refresh_cell_collision(cell)
		_refresh_cell_terrain_speed(cell)
		if layer == fences:
			_refresh_fence_autotiles_around(cell)
		return
	layer.erase_cell(cell)
	layer.update_internals()
	_refresh_cell_collision(cell)
	_refresh_cell_terrain_speed(cell)

func _clear_pasteque_irrigation_before_unbuild(layer: TileMapLayer, cell: Vector2i) -> void:
	if layer != traversable_buildings:
		return
	var item_id: String = ""
	if building_object_manager and building_object_manager.has_method("get_building"):
		var building: Dictionary = building_object_manager.call("get_building", cell) as Dictionary
		item_id = str(building.get("item_id", ""))
	if item_id == "" and layer.get_cell_source_id(cell) >= 0:
		item_id = ItemCatalog.get_placeable_id_for_tile(str(layer.name), layer.get_cell_atlas_coords(cell))
	if item_id != "pasteque":
		return
	if reservoir_system != null and reservoir_system.has_method("clear_pasteque_irrigation_from_cell"):
		reservoir_system.call("clear_pasteque_irrigation_from_cell", cell)

func _removable_at_cell(cell: Vector2i) -> Dictionary:
	var layers: Array[TileMapLayer] = [blocking_buildings, fences, traversable_buildings, plantz, wallz]
	for layer: TileMapLayer in layers:
		if not layer or layer.get_cell_source_id(cell) < 0:
			continue
		var atlas_coords: Vector2i = layer.get_cell_atlas_coords(cell)
		var item_id: String = ItemCatalog.get_placeable_id_for_tile(str(layer.name), atlas_coords)
		if building_object_manager and building_object_manager.has_method("get_building") and (layer == blocking_buildings or layer == traversable_buildings or layer == fences):
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
	_build_preview.create_remove_progress(cell, value)

func _cancel_removal() -> void:
	_remove_active = false
	_remove_drag_active = false
	_remove_elapsed = 0.0
	_remove_queue.clear()
	_hide_drag_selection_rect()
	_clear_remove_progress_bars()

func _clear_remove_progress_bars() -> void:
	_build_preview.clear_remove_progress_bars()

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
	_build_preview.clear_preview_remove_progress_bars(committed)

func _free_remove_progress_for_cell(cell: Vector2i) -> void:
	_build_preview.free_remove_progress_for_cell(cell)

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
	elif _blocking_building_blocks_player(cell):
		blocked = true
	ff.call("set_cell_blocked", cell, blocked)

func _blocking_building_blocks_player(cell: Vector2i) -> bool:
	if blocking_buildings == null or blocking_buildings.get_cell_source_id(cell) < 0:
		return false
	var item_id: String = ItemCatalog.get_placeable_id_for_tile(str(blocking_buildings.name), blocking_buildings.get_cell_atlas_coords(cell))
	if item_id == "":
		return true
	var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
	if item_def.has("blocks_player_movement"):
		return bool(item_def.get("blocks_player_movement", false))
	return bool(item_def.get("blocks_movement", false)) or bool(item_def.get("isWall", false))

func _sync_terrain_speed_cells() -> void:
	var ff: Object = _resolve_flow_field()
	if ff == null:
		return
	if ff.has_method("clear_cell_speed_multipliers"):
		ff.call("clear_cell_speed_multipliers")
	if not ff.has_method("set_cell_speed_multiplier"):
		return
	for layer: TileMapLayer in [plantz, traversable_buildings, blocking_buildings, fences]:
		if layer == null:
			continue
		for raw_cell: Variant in layer.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
			_refresh_cell_terrain_speed(cell)

func _refresh_cell_terrain_speed(cell: Vector2i) -> void:
	var ff: Object = _resolve_flow_field()
	if ff == null or not ff.has_method("set_cell_speed_multiplier"):
		return
	var speed_multiplier: float = DEFAULT_TERRAIN_SPEED_MULTIPLIER
	if plantz != null and plantz.get_cell_source_id(cell) >= 0:
		var plant_atlas_coords: Vector2i = plantz.get_cell_atlas_coords(cell)
		var plant_item_id: String = ItemCatalog.get_placeable_id_for_tile(str(plantz.name), plant_atlas_coords)
		if plant_item_id != "":
			var plant_item_def: Dictionary = ItemCatalog.get_item_def(plant_item_id)
			var plant_speed_multiplier: float = clampf(float(plant_item_def.get("speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER)), 0.01, 1.0)
			speed_multiplier = minf(speed_multiplier, plant_speed_multiplier)
	if traversable_buildings != null and traversable_buildings.get_cell_source_id(cell) >= 0:
		var atlas_coords: Vector2i = traversable_buildings.get_cell_atlas_coords(cell)
		var item_id: String = ItemCatalog.get_placeable_id_for_tile(str(traversable_buildings.name), atlas_coords)
		if item_id != "":
			var item_def: Dictionary = ItemCatalog.get_item_def(item_id)
			var traversable_speed_multiplier: float = clampf(float(item_def.get("speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER)), 0.01, 1.0)
			speed_multiplier = minf(speed_multiplier, traversable_speed_multiplier)
	if blocking_buildings != null and blocking_buildings.get_cell_source_id(cell) >= 0:
		var blocking_atlas_coords: Vector2i = blocking_buildings.get_cell_atlas_coords(cell)
		var blocking_item_id: String = ItemCatalog.get_placeable_id_for_tile(str(blocking_buildings.name), blocking_atlas_coords)
		if blocking_item_id != "":
			var blocking_item_def: Dictionary = ItemCatalog.get_item_def(blocking_item_id)
			var blocking_speed_multiplier: float = clampf(float(blocking_item_def.get("speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER)), 0.01, 1.0)
			speed_multiplier = minf(speed_multiplier, blocking_speed_multiplier)
	if fences != null and fences.get_cell_source_id(cell) >= 0:
		var fence_atlas_coords: Vector2i = fences.get_cell_atlas_coords(cell)
		var fence_item_id: String = ItemCatalog.get_placeable_id_for_tile(str(fences.name), fence_atlas_coords)
		if fence_item_id != "":
			var fence_item_def: Dictionary = ItemCatalog.get_item_def(fence_item_id)
			var fence_speed_multiplier: float = clampf(float(fence_item_def.get("speed_multiplier", DEFAULT_TERRAIN_SPEED_MULTIPLIER)), 0.01, 1.0)
			speed_multiplier = minf(speed_multiplier, fence_speed_multiplier)
	ff.call("set_cell_speed_multiplier", cell, speed_multiplier)

func _refresh_fence_autotiles_for_cells(cells: Array[Vector2i]) -> void:
	var touched: Dictionary = {}
	for cell: Vector2i in cells:
		for refresh_cell: Vector2i in _fence_refresh_cells(cell):
			touched[refresh_cell] = true
	for raw_cell: Variant in touched.keys():
		_refresh_fence_autotile(raw_cell as Vector2i)
	if fences != null:
		fences.update_internals()

func _refresh_fence_autotiles_around(cell: Vector2i) -> void:
	var cells: Array[Vector2i] = [cell]
	_refresh_fence_autotiles_for_cells(cells)

func _fence_refresh_cells(cell: Vector2i) -> Array[Vector2i]:
	return [
		cell,
		cell + DIRECTION_UP,
		cell + DIRECTION_RIGHT,
		cell + DIRECTION_DOWN,
		cell + DIRECTION_LEFT,
	]

func _refresh_fence_autotile(cell: Vector2i) -> void:
	if fences == null or fences.get_cell_source_id(cell) < 0:
		return
	var mask: int = _fence_neighbor_mask(cell)
	var atlas_coords: Vector2i = _fence_atlas_by_mask(mask)
	fences.set_cell(cell, _atlas_source_id, atlas_coords)

func _fence_atlas_by_mask(mask: int) -> Vector2i:
	return FENCE_ATLAS_BY_MASK.get(mask, Vector2i(5, 7)) as Vector2i

func _fence_neighbor_mask(cell: Vector2i) -> int:
	var mask: int = 0
	if _has_fence_cell(cell + DIRECTION_UP):
		mask |= FENCE_NEIGHBOR_NORTH
	if _has_fence_cell(cell + DIRECTION_RIGHT):
		mask |= FENCE_NEIGHBOR_EAST
	if _has_fence_cell(cell + DIRECTION_DOWN):
		mask |= FENCE_NEIGHBOR_SOUTH
	if _has_fence_cell(cell + DIRECTION_LEFT):
		mask |= FENCE_NEIGHBOR_WEST
	return mask

func _has_fence_cell(cell: Vector2i) -> bool:
	return fences != null and fences.get_cell_source_id(cell) >= 0

func _resolve_flow_field() -> Object:
	if _flow_field and is_instance_valid(_flow_field):
		return _flow_field
	var scene: Node = get_tree().get_current_scene()
	if scene:
		_flow_field = scene.get_node_or_null("CPP/FlowFieldNative")
	return _flow_field

func _draw_preview(cell: Vector2i, atlas_coords: Vector2i, item_id: String, placeable_def: Dictionary) -> void:
	_build_preview.draw_preview(cell, atlas_coords, item_id, placeable_def)

# Placeables build as a click-drag rectangle chunk by default, placed up to the
# affordable/limited count while skipping occupied or invalid cells. Specific
# future placeables can opt out with `"drag_buildable": false`.
func _is_drag_buildable(placeable_def: Dictionary) -> bool:
	return bool(placeable_def.get("drag_buildable", true))

# Placement sound for a finished chunk build. This preserves the old per-item
# behavior: roses play the plant sound, other buildings stay silent unless they
# define a build sound later.
func _drag_build_sound(item_id: String) -> StringName:
	return _placement_service.drag_build_sound(item_id)

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
	_drag_build_preview_limit = available
	_build_preview.draw_drag_build_preview(_drag_build_start_cell, _drag_build_end_cell, placeable_def, available)

func _drag_build_rectangle_cells(
	start_cell: Vector2i,
	end_cell: Vector2i,
	target_layer: TileMapLayer,
	placeable_def: Dictionary,
	limit: int
) -> Array[Vector2i]:
	return _placement_service.drag_build_rectangle_cells(start_cell, end_cell, target_layer, placeable_def, limit)

func _drag_build_candidate_blocked_by_batch(
	cell: Vector2i,
	target_layer: TileMapLayer,
	placeable_def: Dictionary,
	accepted_cells: Array[Vector2i]
) -> bool:
	return _placement_service.drag_build_candidate_blocked_by_batch(cell, target_layer, placeable_def, accepted_cells)

func _finish_drag_build() -> void:
	var placeable_def: Dictionary = _selected_placeable_def()
	var item_id: String = _drag_build_item_id
	if _placement_disabled() or str(placeable_def.get("id", "")) != item_id:
		_cancel_drag_build()
		return
	_drag_build_end_cell = _hovered_cell()
	var start_cell: Vector2i = _drag_build_start_cell
	var end_cell: Vector2i = _drag_build_end_cell
	_clear_hover()
	_hide_drag_selection_rect()
	_set_drag_build_active(false)
	_drag_build_item_id = ""
	_placement_service.commit_drag_build(placeable_def, item_id, start_cell, end_cell)

func _cancel_drag_build() -> void:
	_set_drag_build_active(false)
	_drag_build_item_id = ""
	_hide_drag_selection_rect()
	_clear_hover()
	_clear_build_selection()

func _cancel_drag_build_preserving_selection() -> void:
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
	return _placement_service.affordable_quantity(item_id)

func _can_afford(item_id: String) -> bool:
	return _placement_service.can_afford(item_id)

func _clear_build_selection() -> void:
	if game_ui != null and game_ui.has_method("clear_build_selection"):
		game_ui.call("clear_build_selection")

func _clear_build_selection_if_unaffordable(item_id: String) -> void:
	_placement_service.clear_build_selection_if_unaffordable(item_id)

func _apply_placeable(placeable_def: Dictionary) -> void:
	_placement_service.try_apply_placeable(placeable_def, _hovered_cell())

func _target_tile_layer(layer_name: String) -> TileMapLayer:
	return _placement_service.target_tile_layer(layer_name)

func _target_layer_affects_collision(target_layer: TileMapLayer) -> bool:
	return _placement_service.target_layer_affects_collision(target_layer)

func _clear_other_build_layer(target_layer: TileMapLayer, cell: Vector2i) -> void:
	_placement_service.clear_other_build_layer(target_layer, cell)

# True only when `cell` is a real floor tile with no blocking wall on it. Used by
# placeables (e.g. turret1) that may only be built on free walkable ground. This is
# a placement-time guard; it does not affect navigation/flowfields.
func _is_free_walkable_cell(cell: Vector2i) -> bool:
	return _placement_service.is_free_walkable_cell(cell)

func _is_debris_cell(cell: Vector2i) -> bool:
	return _placement_service.is_debris_cell(cell)

func _is_placeable_occupied(cell: Vector2i, target_layer: TileMapLayer, placeable_def: Dictionary) -> bool:
	return _placement_service.is_placeable_occupied(cell, target_layer, placeable_def)

func _is_valid_placeable_cell(cell: Vector2i, target_layer: TileMapLayer, placeable_def: Dictionary) -> bool:
	return _placement_service.is_valid_placeable_cell(cell, target_layer, placeable_def)

func _requires_grass_green_floor(placeable_def: Dictionary) -> bool:
	return _placement_service.requires_grass_green_floor(placeable_def)

func _is_grass_green_floor_cell(cell: Vector2i) -> bool:
	return _placement_service.is_grass_green_floor_cell(cell)

func _placement_attempt_needs_grass_alert(start_cell: Vector2i, end_cell: Vector2i, placeable_def: Dictionary) -> bool:
	return _placement_service.placement_attempt_needs_grass_alert(start_cell, end_cell, placeable_def)

func _show_tutorial_alert(key: String) -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var tutorial: Node = scene.get_node_or_null("GameUI/top anchor/tutorial")
	if tutorial != null and tutorial.has_method("show_alert"):
		tutorial.call("show_alert", key)

func _is_water_source_cell(cell: Vector2i) -> bool:
	return _placement_service.is_water_source_cell(cell)

func _turret_range_blocker_for_cell(cell: Vector2i, placeable_def: Dictionary) -> Dictionary:
	return _placement_service.turret_range_blocker_for_cell(cell, placeable_def)

func _turret_data_from_placeable(placeable_def: Dictionary) -> TurretData:
	return _placement_service.turret_data_from_placeable(placeable_def)

func _refresh_preview_visual_state(placeable_def: Dictionary) -> void:
	_build_preview.refresh_preview_visual_state(placeable_def)

func _turret_item_id_at_cell(cell: Vector2i) -> String:
	return _placement_service.turret_item_id_at_cell(cell)

func _after_placeable_placed(cell: Vector2i, placeable_def: Dictionary, play_placement_sound: bool = true) -> void:
	_placement_service.after_placeable_placed(cell, placeable_def, play_placement_sound)

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
	return _placement_service.uses_building_object_manager(placeable_def)

func _is_occupied_by_group_node(cell: Vector2i, placeable_def: Dictionary) -> bool:
	return _placement_service.is_occupied_by_group_node(cell, placeable_def)

func _notify(message: String) -> void:
	if not notif:
		return
	if notif.has_method("show_notif"):
		notif.call("show_notif", message)

func _clear_hover() -> void:
	_build_preview.clear_hover()

func _hovered_cell() -> Vector2i:
	return _build_preview.hovered_cell()

func _mouse_hovered_cell() -> Vector2i:
	return _build_preview.mouse_hovered_cell()

func _player_cell() -> Vector2i:
	return _build_preview.player_cell()

# Frames the bounding box spanning start_cell..end_cell with the green outline.
func _show_drag_selection_rect(start_cell: Vector2i, end_cell: Vector2i) -> void:
	_build_preview.show_drag_selection_rect(start_cell, end_cell)

func _hide_drag_selection_rect() -> void:
	_build_preview.hide_drag_selection_rect()

func has_single_tile_preview() -> bool:
	return _build_preview.has_single_tile_preview()

func get_preview_item_id() -> String:
	return _build_preview.get_preview_item_id()

func get_preview_cell() -> Vector2i:
	return _build_preview.get_preview_cell()

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
	return _placement_service.atlas_coords_from_placeable(placeable_def)

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
	return _placement_service.alternative_from_placeable(placeable_def)

func _alternative_from_direction(direction: Vector2i) -> int:
	if direction == DIRECTION_LEFT:
		return TILE_TRANSFORM_FLIP_H | TILE_TRANSFORM_FLIP_V
	if direction == DIRECTION_DOWN:
		return TILE_TRANSFORM_TRANSPOSE | TILE_TRANSFORM_FLIP_H
	if direction == DIRECTION_UP:
		return TILE_TRANSFORM_TRANSPOSE | TILE_TRANSFORM_FLIP_V
	return 0
