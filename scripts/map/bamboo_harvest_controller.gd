extends Node2D
class_name BambooHarvestController

## Owns the authored permanent bamboo plants: the cell registry LevelLoader captured from
## the level's `bamboo` marker container, each plant's maturity, its visual, player-proximity
## harvesting, dawn regrowth, the bamboo save section, and the permanent terrain-speed
## registration for every bamboo cell.
##
## It does not own general plant state or growth, flow-field rebuilding, build placement
## algorithms, global currency storage, or save-file orchestration.
##
## Bamboo is authored and permanent: it is never player-placed, removed, damaged, trampled,
## eaten or destroyed, so it is deliberately absent from PlantManager, BuildingObjectManager,
## PlayerPlaceableDurabilityService, BuildRemovalService and every damage/target system. It
## has no health, collision or removal callbacks. A harvest changes only maturity and the
## granted reward; its cell's slowdown and walkability never change.

const BAMBOO_PLANT_VISUAL_SCRIPT: Script = preload("res://scripts/map/bamboo_plant_visual.gd")

const BAMBOO_CURRENCY: StringName = &"bamboo"
const HARVEST_AMOUNT: int = 10
## Permanent slowdown of a bamboo cell. Belongs to the bamboo's presence, not its maturity:
## registered once per cell at setup and never touched again, so maturity changes can never
## dirty navigation.
const TERRAIN_SPEED_MULTIPLIER: float = 0.5
## Bamboo never slows the PLAYER, only the agents crossing it (same rule as roses, see the
## rose's "slows_player" in ItemCatalog): you walk your own grove at full speed.
const PLAYER_TERRAIN_SPEED_MULTIPLIER: float = 1.0
const TERRAIN_SPEED_SOURCE: StringName = &"bamboo"


## One authored bamboo. `world_position` is cached because authored cells never move.
class BambooRecord:
	var cell: Vector2i = Vector2i.ZERO
	var world_position: Vector2 = Vector2.ZERO
	var mature: bool = true
	var visual: BambooPlantVisual = null


var _floor_layer: TileMapLayer = null
var _navigation_sync: BuildingNavigationSyncService = null
var _game_ui: CanvasLayer = null
## Registry order follows LevelLoader's deterministic Y-then-X cell sort, so serialization
## is stable without re-sorting.
var _records: Array[BambooRecord] = []
var _record_by_cell: Dictionary = {}  # Vector2i -> BambooRecord
var _player: Node2D = null
var _pickup_radius_squared: float = 0.0
var _pickup_check_elapsed: float = 0.0


## Explicit dependencies only — never the whole BuildingManager. Must run synchronously
## during BuildingManager._ready(), before Progression._ready() can call the restore facade.
func setup(
	floor_layer: TileMapLayer,
	level_loader: LevelLoader,
	navigation_sync: BuildingNavigationSyncService,
	game_ui: CanvasLayer
) -> void:
	_floor_layer = floor_layer
	_navigation_sync = navigation_sync
	_game_ui = game_ui
	_records.clear()
	_record_by_cell.clear()
	if level_loader != null:
		for cell: Vector2i in level_loader.get_loaded_bamboo_cells():
			_add_record(cell)
	refresh_terrain_slowdowns()
	# Exactly the gem/ground-drop pickup rule, from the one shared helper.
	var pickup_radius: float = GroundDropManager.pickup_radius_for_floor(_floor_layer)
	_pickup_radius_squared = pickup_radius * pickup_radius
	var dawn_callback: Callable = Callable(self, "_on_dawn_phase_changed")
	if not GameState.dawn_phase_changed.is_connected(dawn_callback):
		GameState.dawn_phase_changed.connect(dawn_callback)
	# A level with no bamboo markers costs nothing beyond this inactive node.
	set_process(not _records.is_empty())


## True for every authored bamboo cell, mature or not. Build placement uses this to keep
## bamboo cells permanently unbuildable without stamping a tile into any saved layer.
func has_bamboo_at(cell: Vector2i) -> bool:
	return _record_by_cell.has(cell)


## Idempotent regrowth: every authored bamboo becomes mature again. Grants nothing, and
## never touches terrain speed, navigation, or the visual nodes themselves.
func mature_all_for_dawn() -> void:
	for record: BambooRecord in _records:
		_set_record_mature(record, true)


## One entry per currently authored bamboo cell, in the registry's Y-then-X order. Only
## stable state is emitted: no visual transform, animation phase, pickup timer or slowdown.
func serialize_state() -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	for record: BambooRecord in _records:
		states.append({
			"x": record.cell.x,
			"y": record.cell.y,
			"mature": record.mature,
		})
	return states


## Applies saved maturity onto the current level's authored bamboo, starting from all-mature
## so an old save with no bamboo section leaves everything mature. Saved cells this level
## does not author are ignored: bamboo only ever exists where the level authored it.
func restore_state(saved_states: Array) -> void:
	for record: BambooRecord in _records:
		_set_record_mature(record, true)
	var restored_cells: Dictionary = {}
	for raw_entry: Variant in saved_states:
		if not (raw_entry is Dictionary):
			push_warning("BambooHarvestController: ignoring a non-dictionary bamboo save entry.")
			continue
		var entry: Dictionary = raw_entry as Dictionary
		if not entry.has("x") or not entry.has("y") or not entry.has("mature"):
			push_warning("BambooHarvestController: ignoring a bamboo save entry missing x/y/mature.")
			continue
		var cell: Vector2i = Vector2i(int(entry["x"]), int(entry["y"]))
		if not _record_by_cell.has(cell):
			push_warning("BambooHarvestController: ignoring saved bamboo at %s; this level authors no bamboo there." % str(cell))
			continue
		if restored_cells.has(cell):
			push_warning("BambooHarvestController: ignoring a duplicate saved bamboo entry for %s." % str(cell))
			continue
		restored_cells[cell] = true
		_set_record_mature(_record_by_cell[cell] as BambooRecord, bool(entry["mature"]))


func _add_record(cell: Vector2i) -> void:
	if _record_by_cell.has(cell):
		return
	var record: BambooRecord = BambooRecord.new()
	record.cell = cell
	record.world_position = _cell_center_world(cell)
	record.mature = true
	record.visual = _create_visual(record)
	_records.append(record)
	_record_by_cell[cell] = record


func _create_visual(record: BambooRecord) -> BambooPlantVisual:
	if _floor_layer == null or _floor_layer.tile_set == null:
		push_warning("BambooHarvestController: no floor tile set; bamboo at %s has no visual." % str(record.cell))
		return null
	var visual: BambooPlantVisual = BAMBOO_PLANT_VISUAL_SCRIPT.new()
	visual.name = "Bamboo_%d_%d" % [record.cell.x, record.cell.y]
	add_child(visual)
	visual.setup(record.world_position, Vector2(_floor_layer.tile_set.tile_size))
	visual.set_mature(record.mature)
	return visual


## Registers the permanent slowdown once. This writes the shared native terrain-speed map,
## which every native-steered agent reads live — no flow rebuild, no route invalidation, no
## garden topology work, and no per-species branch. The player is exempt (see
## PLAYER_TERRAIN_SPEED_MULTIPLIER).
## Re-publishes controller-owned terrain contributions after a bulk terrain-channel rebuild.
## Save restoration replaces world layers and rebuilds their composed speed map; that rebuild
## deliberately clears every prior source, including these authored bamboo entries.
func refresh_terrain_slowdowns() -> void:
	if _navigation_sync == null or _records.is_empty():
		return
	var cells: Array[Vector2i] = []
	for record: BambooRecord in _records:
		cells.append(record.cell)
	_navigation_sync.set_static_terrain_speed_multipliers(
		cells,
		TERRAIN_SPEED_SOURCE,
		TERRAIN_SPEED_MULTIPLIER,
		PLAYER_TERRAIN_SPEED_MULTIPLIER
	)


func _cell_center_world(cell: Vector2i) -> Vector2:
	if _floor_layer == null:
		return Vector2.ZERO
	return _floor_layer.to_global(_floor_layer.map_to_local(cell))


# Default process_mode (inherit) already halts this while the tree is paused, so a paused
# game cannot harvest.
func _process(delta: float) -> void:
	_pickup_check_elapsed += delta
	if _pickup_check_elapsed < GroundDropManager.PICKUP_CHECK_INTERVAL:
		return
	_pickup_check_elapsed = 0.0
	_check_player_harvest()


func _check_player_harvest() -> void:
	if not _has_mature_bamboo():
		return
	var player: Node2D = _resolve_player()
	if player == null:
		return
	# Radial distance, exactly like ground drops: standing on the bamboo's cell is not
	# required, and several bamboo inside the radius are each collected.
	var player_position: Vector2 = player.global_position
	for record: BambooRecord in _records:
		if not record.mature:
			continue
		if player_position.distance_squared_to(record.world_position) > _pickup_radius_squared:
			continue
		_harvest(record)


## Reward and saved state change together: GameUI credits the full HARVEST_AMOUNT before the
## first icon leaves the plant, so a save taken mid-flight always shows the full reward against
## an immature plant. The plant turns immature only once the grant is confirmed, and an already
## immature plant can never grant again before the next dawn.
func _harvest(record: BambooRecord) -> void:
	if _game_ui == null or not _game_ui.has_method("grant_currency_from_world_immediate"):
		return
	var granted: bool = bool(_game_ui.call(
		"grant_currency_from_world_immediate",
		BAMBOO_CURRENCY,
		record.world_position,
		HARVEST_AMOUNT
	))
	if not granted:
		return
	_set_record_mature(record, false)


func _set_record_mature(record: BambooRecord, mature: bool) -> void:
	record.mature = mature
	if record.visual != null and is_instance_valid(record.visual):
		record.visual.set_mature(mature)


func _has_mature_bamboo() -> bool:
	for record: BambooRecord in _records:
		if record.mature:
			return true
	return false


func _resolve_player() -> Node2D:
	if _player != null and is_instance_valid(_player):
		return _player
	_player = get_tree().get_first_node_in_group("player") as Node2D
	return _player


func _on_dawn_phase_changed(is_dawn_phase: bool) -> void:
	if not is_dawn_phase:
		return
	# Loading a save made during dawn replays the phase flags. Treating that replay as a real
	# dawn would re-mature bamboo the player had already harvested before saving.
	if GameState.is_emitting_restored_phase_signals():
		return
	mature_all_for_dawn()
