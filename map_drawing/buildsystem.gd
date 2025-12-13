extends Node

@export var wallz: TileMapLayer
@export var previewbuild: TileMapLayer
@export var pause_overlay: PauseOverlay

const BUILD_TILES_INDEX_PATH: String = "res://map_drawing/build_tiles_index.tres"
const TILE_LABEL_OFFSET: Vector2 = Vector2(12, 12)
const DEFAULT_WALL_TILE_KEY: String = "wall1"
const RANDOM_FILL_AREA: Vector2i = Vector2i(32, 32)

var _tile_index: Dictionary = {}
var _hover_label: Label
var _wall_tile_id: int = 1
var _last_pause_state: bool = false
var _last_hover_key: String = ""
var _last_hover_valid: bool = false
var _label_visible: bool = false
var _logged: Dictionary = {}

func _ready() -> void:
	_load_tile_index()
	if pause_overlay:
		_prepare_hover_label()
	else:
		_log_once("pause_overlay_missing_ready", "[BuildSystem] pause_overlay not set (assign it in the editor).")
	#_populate_tilemaps_with_random_tiles()
	set_process(true)
	print("[BuildSystem] ready: previewbuild=%s wallz=%s pause_overlay=%s" %
		[previewbuild, wallz, pause_overlay])

func _process(_delta: float) -> void:
	if not previewbuild:
		_log_once("previewbuild_missing", "[BuildSystem] previewbuild missing (assign it in the editor).")
		_hide_hover_label()
		return

	if not wallz:
		_log_once("wallz_missing", "[BuildSystem] wallz missing (assign it in the editor).")
		_hide_hover_label()
		return

	if not pause_overlay:
		_log_once("pause_overlay_missing", "[BuildSystem] pause_overlay missing (assign it in the editor).")
		_hide_hover_label()
		return

	var paused: bool = _is_paused()
	_log_pause_state(paused)
	if not paused:
		_hide_hover_label()
		return

	var cell: Vector2i = _hovered_cell()
	var valid: bool = _is_in_preview(cell)
	_log_hover_cell(cell, valid)
	if not valid:
		_hide_hover_label()
		return

	_show_hover_label(cell)


func _load_tile_index() -> void:
	var json_res: Resource = load(BUILD_TILES_INDEX_PATH)
	if json_res and json_res is JSON:
		_tile_index = (json_res as JSON).data
		_wall_tile_id = int(_tile_index.get(DEFAULT_WALL_TILE_KEY, _wall_tile_id))
		print("[BuildSystem] loaded tile index: %s" % _tile_index)
	else:
		print("[BuildSystem] failed to load tile index:", BUILD_TILES_INDEX_PATH)

func _prepare_hover_label() -> void:
	if not pause_overlay:
		return
	_hover_label = Label.new()
	_hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_label.visible = false
	_hover_label.text = ""
	_hover_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_hover_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_hover_label.add_theme_constant_override("outline_size", 2)
	_hover_label.z_index = 200
	pause_overlay.add_child(_hover_label)
	print("[BuildSystem] hover label parented to pause_overlay")

func _hovered_cell() -> Vector2i:
	var mouse_world: Vector2 = previewbuild.get_global_mouse_position()
	var local_mouse: Vector2 = previewbuild.to_local(mouse_world)
	return previewbuild.local_to_map(local_mouse)

func _is_paused() -> bool:
	return pause_overlay.visible

func _show_hover_label(cell: Vector2i) -> void:
	if not _hover_label:
		return
	if not _label_visible:
		print("[BuildSystem] showing hover label for cell %d,%d" % [cell.x, cell.y])
	_label_visible = true
	_hover_label.text = "Tile id %d" % _wall_tile_id
	var screen_pos: Vector2 = get_viewport().get_mouse_position()
	_hover_label.position = screen_pos + TILE_LABEL_OFFSET
	_hover_label.visible = true

func _hide_hover_label() -> void:
	if not _hover_label:
		return
	if _label_visible:
		print("[BuildSystem] hiding hover label")
	_label_visible = false
	_hover_label.visible = false

func _is_in_preview(cell: Vector2i) -> bool:
	var used: Rect2i = previewbuild.get_used_rect()
	if used.size == Vector2i.ZERO:
		return true
	return used.has_point(cell)


func _populate_tilemaps_with_random_tiles() -> void:
	var tiles: Array[Dictionary] = _collect_tiles_from_tileset()
	if tiles.size() == 0:
		print("[BuildSystem] no atlas tiles found in tileset, skipping random fill")
		return

	_fill_tilemap_randomly(wallz, tiles)
	_fill_tilemap_randomly(previewbuild, tiles)

func _fill_tilemap_randomly(tilemap: TileMapLayer, tiles: Array[Dictionary]) -> void:
	if not tilemap or not tilemap.tile_set:
		return
	if tiles.size() == 0:
		return

	var used: Rect2i = tilemap.get_used_rect()
	if used.size == Vector2i.ZERO:
		used.position = Vector2i.ZERO
		used.size = RANDOM_FILL_AREA

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()

	for x in range(used.position.x, used.position.x + used.size.x):
		for y in range(used.position.y, used.position.y + used.size.y):
			var chosen: Dictionary = tiles[rng.randi_range(0, tiles.size() - 1)]
			var source_id: int = int(chosen.get("source_id", -1))
			var atlas_coords: Vector2i = chosen.get("atlas_coords", Vector2i(-1, -1))
			var alternative_tile: int = int(chosen.get("alternative_tile", 0))
			tilemap.set_cell(Vector2i(x, y), source_id, atlas_coords, alternative_tile)

	tilemap.update_internals()

func _collect_tiles_from_tileset() -> Array[Dictionary]:
	var tiles: Array[Dictionary] = []

	var reference_map: TileMapLayer = previewbuild
	if not reference_map:
		reference_map = wallz
	if not reference_map or not reference_map.tile_set:
		return tiles

	var tile_set: TileSet = reference_map.tile_set
	var source_count: int = tile_set.get_source_count()
	for source_index in range(source_count):
		var source_id: int = tile_set.get_source_id(source_index)
		var source: TileSetSource = tile_set.get_source(source_id)
		if source is TileSetAtlasSource:
			var atlas_source: TileSetAtlasSource = source as TileSetAtlasSource
			var grid: Vector2i = atlas_source.get_atlas_grid_size()
			for x in range(grid.x):
				for y in range(grid.y):
					var coords: Vector2i = Vector2i(x, y)
					var top_left: Vector2i = atlas_source.get_tile_at_coords(coords)
					if top_left == coords:
						var spec: Dictionary = {
							"source_id": source_id,
							"atlas_coords": coords,
							"alternative_tile": 0,
						}
						tiles.append(spec)

	return tiles


func _log_pause_state(paused: bool) -> void:
	if paused == _last_pause_state:
		return
	_last_pause_state = paused
	print("[BuildSystem] pause state changed -> %s" % paused)

func _log_hover_cell(cell: Vector2i, valid: bool) -> void:
	var key: String = "%d,%d" % [cell.x, cell.y]
	if key == _last_hover_key and valid == _last_hover_valid:
		return
	_last_hover_key = key
	_last_hover_valid = valid
	if valid:
		var tile_data: TileData = wallz.get_cell_tile_data(cell)
		print("[BuildSystem] hovering preview cell %s, wall tile data=%s" % [key, tile_data])
	else:
		print("[BuildSystem] preview cell %s is not part of previewbuild" % key)

func _log_once(key: String, message: String) -> void:
	if bool(_logged.get(key, false)):
		return
	print(message)
	_logged[key] = true
