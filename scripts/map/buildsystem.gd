extends Node
class_name BuildSystem

signal build_preview_changed(is_active: bool)

const BUILD_FX_SCENE: PackedScene = preload("res://scenes/particles/buildFX.tscn")
const TERRAIN_SPEED_MODIFIER_SERVICE: Script = preload("res://scripts/map/terrain_speed_modifier_service.gd")
const BUILD_FX_Z_INDEX: int = -62
const DEFAULT_TERRAIN_SPEED_MULTIPLIER: float = 1.0
const TERRAIN_SPEED_SOURCE_PREFIX: String = "buildsystem:"
# DIRECTION_* are fence-adjacency neighbor offsets used by the fence autotiler below.
# Build orientation rules (facing rotation, direction -> tile alternative) live in
# BuildDirectionRules, not here.
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

# Player controller, resolved lazily, used only to honour its gameplay-input lock (modal
# dialogs / cutscenes) so build input does not act underneath them.
var _player_controller: Node = null
var _atlas_source_id: int = -1
# Cached FlowFieldNative used to keep the player's hard wall collision in sync when a
# wall/building is built or removed during the day (see _refresh_cell_collision).
var _flow_field: Object = null
var _steering_system: Node = null
var _terrain_speed: RefCounted = TERRAIN_SPEED_MODIFIER_SERVICE.new()
var _building_manager: Object = null
var _build_preview: BuildPreviewController = null
var _placement_service: BuildPlacementService = null
var _removal_service: BuildRemovalService = null
var _drag_controller: BuildDragController = null
var _input_controller: BuildInputController = null
var _build_mode_state: BuildModeStateController = null
var _controllers_ready: bool = false

var _plant_layer_flush_queued: bool = false
var _build_fx_pool: Array[Node2D] = []
var _build_fx_pool_cursor: int = 0

func _enter_tree() -> void:
	set_process(false)
	set_process_input(false)

func _ready() -> void:
	set_process(false)
	set_process_input(false)
	_resolve_level_layers()
	_resolve_atlas_source_id()
	if not _create_controllers():
		push_error("BuildSystem failed to create build controllers; build input is disabled.")
		return
	_placement_service.setup(self)
	_removal_service.setup(self)
	_build_preview.setup(self, _gamepad_mode_query())
	_drag_controller.setup(self)
	_input_controller.setup(
		self,
		_drag_controller,
		_build_preview,
		_placement_service,
		_build_mode_state,
		game_ui
	)
	_build_mode_state.setup(self)
	_configure_preview_layer()
	_sync_terrain_speed_cells()
	_preload_build_fx_pool()
	_controllers_ready = true
	set_process(true)
	set_process_input(true)
	GameState.mode_changed.connect(_on_game_mode_changed)

func _gamepad_mode_query() -> Callable:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return Callable()
	var player_controller: Node = scene.get_node_or_null("Player/PlayerController")
	if player_controller == null or not player_controller.has_method("is_gamepad_control_mode"):
		return Callable()
	return Callable(player_controller, "is_gamepad_control_mode")

func _create_controllers() -> bool:
	if _build_preview == null:
		_build_preview = BuildPreviewController.new()
	if _placement_service == null:
		_placement_service = BuildPlacementService.new()
	if _removal_service == null:
		_removal_service = BuildRemovalService.new()
	if _drag_controller == null:
		_drag_controller = BuildDragController.new()
	if _input_controller == null:
		_input_controller = BuildInputController.new()
	if _build_mode_state == null:
		_build_mode_state = BuildModeStateController.new()
	return (
		_build_preview != null
		and _placement_service != null
		and _removal_service != null
		and _drag_controller != null
		and _input_controller != null
		and _build_mode_state != null
	)

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
	# Removal stays forbidden at night because it can change blocker topology while
	# monster flow fields are active.
	_cancel_removal()
	# Night can forbid the buildable being dragged (a rose rectangle, a house). The selected
	# def goes empty for a phase-disabled item, so drop the gesture, its rectangle and the
	# selection now instead of waiting for the next frame's drag tick to notice: a release in
	# this same frame must not commit the stale rectangle.
	if _drag_controller.is_build_drag_active() and _selected_placeable_def().is_empty():
		_cancel_drag_build()

# Godot input/tick callbacks are thin wrappers: BuildInputController owns build-mode
# input routing (mouse/keyboard press/release/motion/wheel, hover preview dispatch,
# and the per-frame drag tick).
func _process(delta: float) -> void:
	if not _controllers_ready or _input_controller == null:
		return
	_input_controller.process(delta)

func _input(event: InputEvent) -> void:
	if not _controllers_ready or _input_controller == null:
		return
	# A modal dialog / cutscene locks gameplay input on the player controller. Build input runs
	# from _input (before the modal's GUI backdrop), so honour that lock here too, otherwise
	# keyboard rotate/unbuild would still act underneath an open dialog.
	if _gameplay_input_locked():
		return
	_input_controller.input(event)


## True while the player controller has gameplay input locked (an open modal dialog or a
## running cutscene). Resolved lazily and cached.
func _gameplay_input_locked() -> bool:
	if _player_controller == null or not is_instance_valid(_player_controller):
		var scene: Node = get_tree().current_scene
		_player_controller = scene.get_node_or_null("Player/PlayerController") if scene != null else null
	return _player_controller != null and _player_controller.has_method("is_cutscene_input_locked") and bool(_player_controller.call("is_cutscene_input_locked"))

# Narrow wrappers exposed to BuildInputController so it can route input without owning
# drag/preview state (those stay in BuildDragController / BuildPreviewController).
func _tick_drag(delta: float) -> void:
	_drag_controller.process(delta)

func _is_remove_drag_active() -> bool:
	return _drag_controller.is_remove_drag_active()

func _is_build_drag_active() -> bool:
	return _drag_controller.is_build_drag_active()

func _update_build_drag(placeable_def: Dictionary) -> void:
	_drag_controller.update_build_drag(placeable_def)

func _update_remove_drag() -> void:
	_drag_controller.update_remove_drag()

func _preview_matches_hover(cell: Vector2i, atlas_coords: Vector2i, item_id: String) -> bool:
	return _build_preview.matches_hover(cell, atlas_coords, item_id)

func _set_preview_hover(cell: Vector2i, atlas_coords: Vector2i) -> void:
	_build_preview.set_hover(cell, atlas_coords)

func _start_remove_drag() -> void:
	_drag_controller.start_remove_drag()

func _preview_remove_drag() -> void:
	_drag_controller.preview_remove_drag()

func _finish_remove_drag() -> void:
	_drag_controller.finish_remove_drag()

func _process_removal(delta: float) -> void:
	_drag_controller.process_removal(delta)

func _finish_removal() -> void:
	_drag_controller.finish_removal()

func pad_place_selected_at_cursor() -> void:
	if _placement_disabled() or _is_inventory_open():
		return
	var placeable_def: Dictionary = _selected_placeable_def()
	if placeable_def.is_empty():
		return
	_cancel_removal()
	if _drag_controller.is_build_drag_active():
		_finish_drag_build()
		return
	if _is_drag_buildable(placeable_def) and not _pad_skips_preview(placeable_def):
		_start_drag_build(placeable_def)
	else:
		_apply_placeable(placeable_def)


func pad_cancel_build_preview() -> bool:
	if not _drag_controller.is_build_drag_active():
		return false
	_cancel_drag_build()
	return true


func _pad_skips_preview(placeable_def: Dictionary) -> bool:
	return bool(placeable_def.get("pad_skip_preview", false))


func pad_is_build_preview_active() -> bool:
	return _drag_controller.is_build_drag_active()


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
	# Keep an in-progress pad unbuild rectangle following the cursor as it steps.
	if _is_remove_drag_active():
		_update_remove_drag()


## Pad unbuild validation via the accept (A) button, mirroring how placement is confirmed. The
## first A anchors a removal rectangle at the cursor; moving the cursor grows it (see
## pad_move_cursor); a second A commits the rectangle to the removal queue, which drains one cell
## at a time. Anchor + commit on the same cell just queues that single cell.
func pad_confirm_remove_at_cursor() -> void:
	if _placement_disabled() or _is_inventory_open():
		return
	if _is_remove_drag_active():
		_finish_remove_drag()
	else:
		_start_remove_drag()


## Aborts an in-progress removal drag rectangle without touching the committed removal queue.
## Returns true when a drag was active. Called on any deselect that happens mid-drag (right-click,
## pad-B) so the drag rect is never orphaned.
func cancel_remove_drag() -> bool:
	return _drag_controller.cancel_remove_drag()


## Aborts an in-progress pad removal drag (the B / cancel button). Returns true when one was active.
func pad_cancel_remove_drag() -> bool:
	return cancel_remove_drag()


func pad_rotate_selected_at_cursor() -> bool:
	return rotate_selected_build_direction()


func rotate_selected_build_direction(reverse: bool = false) -> bool:
	var rotated: bool = _build_mode_state.rotate_selected_build_direction(reverse)
	if rotated and _is_build_drag_active():
		_drag_controller.refresh_build_drag_preview(_selected_placeable_def())
	return rotated

func _remove_tile(layer: TileMapLayer, cell: Vector2i) -> void:
	_removal_service.remove_tile(layer, cell)

func _clear_pasteque_irrigation_before_unbuild(layer: TileMapLayer, cell: Vector2i) -> void:
	_removal_service.clear_pasteque_irrigation_before_unbuild(layer, cell)

func _removable_at_cell(cell: Vector2i) -> Dictionary:
	return _removal_service.removable_at_cell(cell)

func _can_unbuild_tile(layer: TileMapLayer, item_id: String, atlas_coords: Vector2i) -> bool:
	return _removal_service.can_unbuild_tile(layer, item_id, atlas_coords)

func _remove_rectangle_cells(start_cell: Vector2i, end_cell: Vector2i) -> Array[Dictionary]:
	return _removal_service.remove_rectangle_cells(start_cell, end_cell)

func _create_remove_progress(cell: Vector2i, value: float) -> void:
	_build_preview.create_remove_progress(cell, value)

func _cancel_removal() -> void:
	_drag_controller.cancel_removal()

func _clear_remove_progress_bars() -> void:
	_build_preview.clear_remove_progress_bars()

# Cells committed to the active removal queue (drives dedup + bar preservation when
# a fresh drag stacks onto an in-progress removal).
func _committed_cell_set() -> Dictionary:
	return _drag_controller.committed_cell_set()

# Free only transient drag-preview bars, keeping the bars for cells already
# committed to the active removal queue.
func _clear_preview_remove_progress_bars(committed: Dictionary = {}) -> void:
	if committed.is_empty():
		committed = _committed_cell_set()
	_build_preview.clear_preview_remove_progress_bars(committed)

func _free_remove_progress_for_cell(cell: Vector2i) -> void:
	_build_preview.free_remove_progress_for_cell(cell)

func _set_remove_progress_value(cell: Vector2i, value: float) -> void:
	_build_preview.set_remove_progress_value(cell, value)

func _commit_removal(removal: Dictionary) -> bool:
	return _removal_service.commit_removal(removal)

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

# Fences are hard navigation blockers only while they block client / merchant routing
# (day, no active tantrum); at night monsters route through them and are merely slowed.
# Placement / removal services query this to pick the right navigation impact for a fence.
func fences_currently_block_navigation() -> bool:
	var building_manager: Object = _resolve_building_manager()
	if building_manager != null and building_manager.has_method("_fences_block_navigation"):
		return bool(building_manager.call("_fences_block_navigation"))
	return true

func _notify_navigation_topology_changed(cell: Vector2i, reason: String) -> void:
	var building_manager: Object = _resolve_building_manager()
	if building_manager == null or not building_manager.has_method("get_building_invalidation_controller"):
		return
	var invalidation_controller: Object = building_manager.call("get_building_invalidation_controller")
	if invalidation_controller == null or not invalidation_controller.has_method("after_walkability_changed"):
		return
	invalidation_controller.call("after_walkability_changed", reason)
	# Under-construction visual: a placed navigation-blocking cell (wall/fence/turret)
	# is ghosted at 50% with a progress bar until the budgeted rebuild and the lazy
	# flow fields make it functional; a removal clears any pending ghost.
	var placed: bool = reason == "placeable_placed" or reason == "drag_placeable_placed"
	if placed and building_manager.has_method("notify_blocking_placeable_placed"):
		building_manager.call("notify_blocking_placeable_placed", cell)
	elif not placed and building_manager.has_method("notify_blocking_placeable_removed"):
		building_manager.call("notify_blocking_placeable_removed", cell)

# Player-built provenance registration, forwarded to the BuildingManager-owned
# PlayerPlaceableDurabilityService. Called from the central placement/removal hooks
# so only genuinely player-built placeables become destructible tantrum targets.
func register_player_placeable(cell: Vector2i, item_id: String, layer_name: String) -> void:
	var building_manager: Object = _resolve_building_manager()
	if building_manager != null and building_manager.has_method("register_player_placeable"):
		building_manager.call("register_player_placeable", cell, item_id, layer_name)

func unregister_player_placeable(cell: Vector2i, layer_name: String = "") -> void:
	var building_manager: Object = _resolve_building_manager()
	if building_manager != null and building_manager.has_method("unregister_player_placeable"):
		building_manager.call("unregister_player_placeable", cell, layer_name)

# Hostile destruction: identical low-level removal + cleanup as a normal unbuild, but
# without the currency/inventory refund. Reuses BuildRemovalService.remove_tile (which
# commit_removal also calls before it refunds), so wall topology, turret runtime,
# counter-stock clearing, fence autotiling and navigation are updated exactly as a
# normal removal requires.
func destroy_placeable_no_refund(cell: Vector2i, layer_name: String = "", target_item_id: String = "") -> bool:
	if _removal_service == null:
		return false
	if layer_name != "":
		if layer_name == "traversable_buildings" or layer_name == "buildings":
			if _removal_service.remove_runtime_placeable(cell, target_item_id):
				return true
		var target_layer: TileMapLayer = _placeable_layer_for_name(layer_name)
		if target_layer == null or target_layer.get_cell_source_id(cell) < 0:
			return false
		var resolved_item_id: String = target_item_id
		if resolved_item_id == "":
			resolved_item_id = ItemCatalog.get_placeable_id_for_tile(str(target_layer.name), target_layer.get_cell_atlas_coords(cell))
		if resolved_item_id == "":
			return false
		_removal_service.remove_tile(target_layer, cell, resolved_item_id)
		return true
	var removal: Dictionary = _removal_service.removable_at_cell(cell)
	if removal.is_empty():
		return false
	var layer: TileMapLayer = removal.get("layer") as TileMapLayer
	var item_id: String = str(removal.get("item_id", ""))
	if bool(removal.get("runtime_placeable", false)):
		return _removal_service.remove_runtime_placeable(cell, item_id)
	if layer == null or item_id == "":
		return false
	_removal_service.remove_tile(layer, cell, item_id)
	return true


func _placeable_layer_for_name(layer_name: String) -> TileMapLayer:
	match layer_name:
		"wallz":
			return wallz
		"plantz":
			return plantz
		"traversable_buildings", "buildings":
			return traversable_buildings
		"blocking_buildings":
			return blocking_buildings
		"fences":
			return fences
	return null

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
	var steering: Node = _resolve_steering_system()
	if steering == null:
		return
	if not steering.has_method("replace_terrain_speed_channel"):
		return
	_terrain_speed.setup(steering)
	_terrain_speed.clear_local_contributions()
	_terrain_speed.clear_all_native_channels()
	for layer: TileMapLayer in [plantz, traversable_buildings, blocking_buildings, fences]:
		if layer == null:
			continue
		for raw_cell: Variant in layer.get_used_cells():
			var cell: Vector2i = raw_cell as Vector2i
			_refresh_cell_terrain_speed(cell, false)
	if plant_manager != null and plant_manager.has_method("get_plant_cells"):
		var plant_cells: Array = plant_manager.call("get_plant_cells") as Array
		for raw_cell: Variant in plant_cells:
			var cell: Vector2i = raw_cell as Vector2i
			_refresh_cell_terrain_speed(cell, false)
	if building_object_manager != null and building_object_manager.has_method("get_building_cells"):
		var building_cells: Array = building_object_manager.call("get_building_cells") as Array
		for raw_cell: Variant in building_cells:
			var cell: Vector2i = raw_cell as Vector2i
			_refresh_cell_terrain_speed(cell, false)
	_terrain_speed.upload_all_channels()

# Startup terrain-speed seed for one cell. Pushes both the all-agent and the player
# multiplier (a rose slows every agent but never the player -- see
# PlaceableNavImpact.def_player_speed_multiplier). This walks the layers itself rather
# than reusing BuildingNavigationSyncService: BuildSystem._ready() runs before
# BuildingManager's (it is the earlier sibling under Map), so the service does not exist
# yet at seed time. The "who does a def slow" rule is shared, only the walk is duplicated.
func _refresh_cell_terrain_speed(cell: Vector2i, upload: bool = true) -> void:
	var steering: Node = _resolve_steering_system()
	if steering == null or not steering.has_method("set_terrain_speed_cell"):
		return
	_terrain_speed.set_steering(steering)
	var speed_multiplier: float = DEFAULT_TERRAIN_SPEED_MULTIPLIER
	var player_speed_multiplier: float = DEFAULT_TERRAIN_SPEED_MULTIPLIER
	if plant_manager != null and plant_manager.has_method("get_plant_item_id"):
		var logical_plant_item_id: String = str(plant_manager.call("get_plant_item_id", cell))
		if logical_plant_item_id != "":
			var logical_plant_item_def: Dictionary = ItemCatalog.get_item_def(logical_plant_item_id)
			speed_multiplier = minf(speed_multiplier, PlaceableNavImpact.def_speed_multiplier(logical_plant_item_def))
			player_speed_multiplier = minf(player_speed_multiplier, PlaceableNavImpact.def_player_speed_multiplier(logical_plant_item_def))
	for layer: TileMapLayer in [plantz, traversable_buildings, blocking_buildings, fences]:
		if layer == null or layer.get_cell_source_id(cell) < 0:
			continue
		var layer_item_id: String = ItemCatalog.get_placeable_id_for_tile(str(layer.name), layer.get_cell_atlas_coords(cell))
		if layer_item_id == "":
			continue
		var layer_item_def: Dictionary = ItemCatalog.get_item_def(layer_item_id)
		speed_multiplier = minf(speed_multiplier, PlaceableNavImpact.def_speed_multiplier(layer_item_def))
		player_speed_multiplier = minf(player_speed_multiplier, PlaceableNavImpact.def_player_speed_multiplier(layer_item_def))
	if building_object_manager != null and building_object_manager.has_method("get_placeable_item_id"):
		var runtime_item_id: String = str(building_object_manager.call("get_placeable_item_id", cell))
		if runtime_item_id != "":
			var runtime_item_def: Dictionary = ItemCatalog.get_item_def(runtime_item_id)
			speed_multiplier = minf(speed_multiplier, PlaceableNavImpact.def_speed_multiplier(runtime_item_def))
			player_speed_multiplier = minf(player_speed_multiplier, PlaceableNavImpact.def_player_speed_multiplier(runtime_item_def))
	_terrain_speed.set_cell_contribution_pair(cell, StringName(TERRAIN_SPEED_SOURCE_PREFIX + str(cell)), speed_multiplier, player_speed_multiplier, upload)

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


func _resolve_steering_system() -> Node:
	if _steering_system and is_instance_valid(_steering_system):
		return _steering_system
	var scene: Node = get_tree().get_current_scene()
	if scene:
		_steering_system = scene.get_node_or_null("CPP/SteeringSystemNative")
	return _steering_system

# Typed access to the house owner for the placement/preview services (houses are placed and
# previewed as one logical object, not through the generic tile path).
func get_house_manager() -> HouseManager:
	var building_manager: Object = _resolve_building_manager()
	if building_manager != null and building_manager.has_method("get_house_manager"):
		return building_manager.call("get_house_manager") as HouseManager
	return null


func is_house_build_item_available(item_id: String) -> bool:
	var building_manager: Object = _resolve_building_manager()
	if building_manager != null and building_manager.has_method("is_house_build_item_available"):
		return bool(building_manager.call("is_house_build_item_available", item_id))
	return true


func notify_player_house_placed(item_id: String) -> void:
	var building_manager: Object = _resolve_building_manager()
	if building_manager != null and building_manager.has_method("notify_player_house_placed"):
		building_manager.call("notify_player_house_placed", item_id)


# True on a cell holding a permanent authored world feature (bamboo), which nothing may be
# built on. Placement/preview reach the owning controller only through this facade.
func is_permanent_world_feature_cell(cell: Vector2i) -> bool:
	var building_manager: Object = _resolve_building_manager()
	if building_manager != null and building_manager.has_method("is_permanent_world_feature_cell"):
		return bool(building_manager.call("is_permanent_world_feature_cell", cell))
	return false


# True when a house may be placed with `cell` as its entrance (whole six-cell footprint valid).
# Shared by the placement commit and the live preview tint.
func _house_placement_valid(cell: Vector2i, placeable_def: Dictionary) -> bool:
	return _placement_service.house_placement_rejection(cell, placeable_def) == ""


func _resolve_building_manager() -> Object:
	if _building_manager and is_instance_valid(_building_manager):
		return _building_manager
	var parent_node: Node = get_parent()
	if parent_node:
		_building_manager = parent_node.get_node_or_null("BuildingManager")
	if _building_manager == null:
		var scene: Node = get_tree().get_current_scene()
		if scene:
			_building_manager = scene.get_node_or_null("Map/BuildingManager")
	return _building_manager

func _draw_preview(cell: Vector2i, atlas_coords: Vector2i, item_id: String, placeable_def: Dictionary) -> void:
	_build_preview.draw_preview(cell, atlas_coords, item_id, placeable_def)

# Placeables build as a click-drag rectangle chunk by default, placed up to the
# affordable/limited count while skipping occupied or invalid cells. Specific
# placeables opt out with `"drag_buildable": false` (the rule itself lives in ItemCatalog).
func _is_drag_buildable(placeable_def: Dictionary) -> bool:
	return ItemCatalog.is_drag_buildable(placeable_def)

## True when the tool currently in hand can start a drag/chunk gesture: the unbuild tool (which
## always drags a removal rectangle) or an armed drag-buildable placeable. This is the single
## rule behind the drag hint icon, so any future drag-capable tool lights it up by answering
## here rather than by touching the preview code.
func is_current_tool_drag_capable() -> bool:
	if _is_unbuild_selected():
		return true
	var placeable_def: Dictionary = _selected_placeable_def()
	if placeable_def.is_empty():
		return false
	return _is_drag_buildable(placeable_def)

func _is_unbuild_selected() -> bool:
	return game_ui != null and game_ui.has_method("is_unbuild_tool_selected") and bool(game_ui.call("is_unbuild_tool_selected"))

# Placement sound for a finished chunk build. This preserves the old per-item
# behavior: roses play the plant sound, other buildings stay silent unless they
# define a build sound later.
func _drag_build_sound(item_id: String) -> StringName:
	return _placement_service.drag_build_sound(item_id)

func _start_drag_build(placeable_def: Dictionary) -> void:
	_drag_controller.start_drag_build(placeable_def)

func _draw_drag_build_preview(start_cell: Vector2i, end_cell: Vector2i, placeable_def: Dictionary, available: int) -> void:
	_build_preview.draw_drag_build_preview(start_cell, end_cell, placeable_def, available)

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
	_drag_controller.finish_drag_build()

func _cancel_drag_build() -> void:
	_drag_controller.cancel_drag_build()

func _cancel_drag_build_preserving_selection() -> void:
	_drag_controller.cancel_drag_build_preserving_selection()

func _set_drag_build_active(active: bool) -> void:
	_drag_controller.set_drag_build_active(active)

func _emit_build_preview_changed(active: bool) -> void:
	build_preview_changed.emit(active)

func _commit_drag_build(placeable_def: Dictionary, item_id: String, start_cell: Vector2i, end_cell: Vector2i) -> bool:
	return _placement_service.commit_drag_build(placeable_def, item_id, start_cell, end_cell)

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
# placeables (e.g. turret_epine) that may only be built on free walkable ground. This is
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

# Frames the bounding box spanning start_cell..end_cell: green for placement, red when remove.
func _show_drag_selection_rect(start_cell: Vector2i, end_cell: Vector2i, remove: bool = false) -> void:
	_build_preview.show_drag_selection_rect(start_cell, end_cell, remove)

func _hide_drag_selection_rect() -> void:
	_build_preview.hide_drag_selection_rect()

func has_single_tile_preview() -> bool:
	return _build_preview.has_single_tile_preview()

func get_preview_item_id() -> String:
	return _build_preview.get_preview_item_id()

func get_preview_cell() -> Vector2i:
	return _build_preview.get_preview_cell()

func get_preview_direction() -> Vector2i:
	return _build_mode_state.get_build_direction()

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
	return _build_mode_state.selected_placeable_def()

func _is_inventory_open() -> bool:
	return game_ui and game_ui.has_method("is_inventory_open") and bool(game_ui.call("is_inventory_open"))

func _placement_disabled() -> bool:
	return false

func _atlas_coords_from_placeable(placeable_def: Dictionary) -> Vector2i:
	return _placement_service.atlas_coords_from_placeable(placeable_def)

func _alternative_from_placeable(placeable_def: Dictionary) -> int:
	return _placement_service.alternative_from_placeable(placeable_def)
