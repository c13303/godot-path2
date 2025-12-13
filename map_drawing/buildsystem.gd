extends Node

@export var wallz: TileMapLayer
@export var previewbuild: TileMapLayer
@export var pause_overlay: PauseOverlay

const BUILD_TILES_INDEX_PATH: String = "res://map_drawing/build_tiles_index.tres"
const TILE_LABEL_OFFSET: Vector2 = Vector2(12, 12)
const DEFAULT_WALL_TILE_KEY: String = "wall1"
const RANDOM_FILL_AREA: Vector2i = Vector2i(32, 32)

var _tile_index: Dictionary = {}
var _tile_specs: Array[Dictionary] = []
var _hover_label: Label
var _wall_tile_id: int = 1
var _last_pause_state: bool = false
var _label_visible: bool = false
var _logged: Dictionary = {}

var _pause_rect: Rect2i = Rect2i(Vector2i.ZERO, Vector2i.ZERO)
var _pause_rect_valid: bool = false

var _hover_active: bool = false
var _hover_cell: Vector2i = Vector2i.ZERO

func _ready() -> void:
	_load_tile_index()
	_tile_specs = _collect_tiles_from_tileset()
	if _tile_specs.is_empty():
		_log_once("tile_specs_empty", "[BuildSystem] no tile specs collected from tileset.")
	if pause_overlay:
		_prepare_hover_label()
	else:
		_log_once("pause_overlay_missing_ready", "[BuildSystem] pause_overlay not set (assign it in the editor).")
	set_process(true)

func _process(_delta: float) -> void:
	if not previewbuild:
		_log_once("previewbuild_missing", "[BuildSystem] previewbuild missing (assign it in the editor).")
		_exit_pause_mode()
		return

	if not wallz:
		_log_once("wallz_missing", "[BuildSystem] wallz missing (assign it in the editor).")
		_exit_pause_mode()
		return

	if not pause_overlay:
		_log_once("pause_overlay_missing", "[BuildSystem] pause_overlay missing (assign it in the editor).")
		_exit_pause_mode()
		return

	var paused: bool = _is_paused()
	if paused != _last_pause_state:
		_last_pause_state = paused
		if paused:
			_enter_pause_mode()
		else:
			_exit_pause_mode()

	if not paused:
		return

	var cell: Vector2i = _hovered_cell()
	if not _cell_in_pause_rect(cell):
		_clear_hover_tile()
		_hide_hover_label()
		return

	if _hover_active and cell == _hover_cell:
		_show_hover_label(cell)
		return

	_clear_hover_tile()
	_hover_active = true
	_hover_cell = cell
	_show_hover_label(cell)
	_display_wall_tile_at(cell)

func _enter_pause_mode() -> void:
	_pause_rect = previewbuild.get_used_rect()
	_pause_rect_valid = _pause_rect.size != Vector2i.ZERO
	_hover_active = false

func _exit_pause_mode() -> void:
	_clear_hover_tile()
	_hide_hover_label()
	_hover_active = false

func _cell_in_pause_rect(cell: Vector2i) -> bool:
	if not _pause_rect_valid:
		return true
	return _pause_rect.has_point(cell)

func _load_tile_index() -> void:
	var json_res: Resource = load(BUILD_TILES_INDEX_PATH)
	if json_res and json_res is JSON:
		_tile_index = (json_res as JSON).data
		_wall_tile_id = int(_tile_index.get(DEFAULT_WALL_TILE_KEY, _wall_tile_id))

func _prepare_hover_label() -> void:
	_hover_label = Label.new()
	_hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_label.visible = false
	_hover_label.text = ""
	_hover_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_hover_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_hover_label.add_theme_constant_override("outline_size", 2)
	_hover_label.z_index = 200
	pause_overlay.add_child(_hover_label)

func _hovered_cell() -> Vector2i:
	var mouse_world: Vector2 = previewbuild.get_global_mouse_position()
	var local_mouse: Vector2 = previewbuild.to_local(mouse_world)
	return previewbuild.local_to_map(local_mouse)

func _is_paused() -> bool:
	return pause_overlay.visible

func _show_hover_label(cell: Vector2i) -> void:
	if not _hover_label:
		return
	_label_visible = true
	_hover_label.text = "Tile id %d" % _wall_tile_id
	_hover_label.position = get_viewport().get_mouse_position() + TILE_LABEL_OFFSET
	_hover_label.visible = true

func _hide_hover_label() -> void:
	if not _hover_label:
		return
	_label_visible = false
	_hover_label.visible = false

func _display_wall_tile_at(cell: Vector2i) -> void:
	if _tile_specs.is_empty():
		return
	var spec_index: int = clamp(_wall_tile_id - 1, 0, _tile_specs.size() - 1)
	var spec: Dictionary = _tile_specs[spec_index]
	previewbuild.set_cell(
		cell,
		int(spec["source_id"]),
		spec["atlas_coords"],
		int(spec["alternative_tile"])
	)
	previewbuild.update_internals()

func _clear_hover_tile() -> void:
	if not _hover_active:
		return
	if previewbuild:
		previewbuild.erase_cell(_hover_cell)
		previewbuild.update_internals()
	_hover_active = false

func _collect_tiles_from_tileset() -> Array[Dictionary]:
	var tiles: Array[Dictionary] = []
	var ref := previewbuild if previewbuild else wallz
	if not ref or not ref.tile_set:
		return tiles

	var tile_set: TileSet = ref.tile_set
	for i in range(tile_set.get_source_count()):
		var source_id: int = tile_set.get_source_id(i)
		var source: TileSetSource = tile_set.get_source(source_id)
		if source is TileSetAtlasSource:
			var atlas: TileSetAtlasSource = source as TileSetAtlasSource
			var grid: Vector2i = atlas.get_atlas_grid_size()
			for x in range(grid.x):
				for y in range(grid.y):
					var c: Vector2i = Vector2i(x, y)
					if atlas.get_tile_at_coords(c) == c:
						tiles.append({
							"source_id": source_id,
							"atlas_coords": c,
							"alternative_tile": 0
						})
	return tiles

func _log_once(key: String, message: String) -> void:
	if _logged.get(key, false):
		return
	print(message)
	_logged[key] = true
