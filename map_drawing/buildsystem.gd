extends Node

@export var wallz: TileMapLayer
@export var previewbuild: TileMapLayer
@export var pause_overlay: PauseOverlay

const BUILD_TILES_INDEX_PATH := "res://map_drawing/build_tiles_index.tres"
const TILE_LABEL_OFFSET := Vector2(12, 12)
const DEFAULT_WALL_TILE_KEY := "wall1"

var _tile_index: Dictionary = {}
var _tile_specs: Array[Dictionary] = []

var _tile_selection_keys: Array[String] = []
var _current_tile_key: String = DEFAULT_WALL_TILE_KEY
var _current_tile_key_index: int = 0
var _wall_tile_id: int = 1

var _hover_label: Label
var _hover_active: bool = false
var _hover_cell: Vector2i

func _ready() -> void:
	_load_tile_index()
	_tile_specs = _collect_tiles_from_tileset()
	_prepare_hover_label()
	set_process(true)
	set_process_input(true)

func _process(_delta: float) -> void:
	if not _is_paused():
		_clear_hover()
		return

	var cell := _hovered_cell()

	if _hover_active and cell == _hover_cell:
		_update_label()
		return

	_clear_hover()
	_hover_cell = cell
	_hover_active = true
	_draw_preview(cell)
	_update_label()

func _input(event: InputEvent) -> void:
	if not _is_paused():
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_select_next_tile(-1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_select_next_tile(1)

func _load_tile_index() -> void:
	var res := load(BUILD_TILES_INDEX_PATH)
	if res is JSON:
		_tile_index = res.data
	else:
		_tile_index = {}

	_tile_selection_keys.clear()
	for k in _tile_index.keys():
		_tile_selection_keys.append(str(k))

	if _tile_selection_keys.is_empty():
		return

	if not _tile_selection_keys.has(DEFAULT_WALL_TILE_KEY):
		_current_tile_key = _tile_selection_keys[0]

	_current_tile_key_index = _tile_selection_keys.find(_current_tile_key)
	_wall_tile_id = int(_tile_index.get(_current_tile_key, 1))

func _select_next_tile(dir: int) -> void:
	if _tile_selection_keys.is_empty():
		return
	_current_tile_key_index = (_current_tile_key_index + dir) % _tile_selection_keys.size()
	if _current_tile_key_index < 0:
		_current_tile_key_index += _tile_selection_keys.size()
	_current_tile_key = _tile_selection_keys[_current_tile_key_index]
	_wall_tile_id = int(_tile_index.get(_current_tile_key, 1))
	if _hover_active:
		_draw_preview(_hover_cell)
		_update_label()

func _draw_preview(cell: Vector2i) -> void:
	if _tile_specs.is_empty():
		return
	if _wall_tile_id < 1 or _wall_tile_id > _tile_specs.size():
		previewbuild.erase_cell(cell)
		previewbuild.update_internals()
		return
	var spec := _tile_specs[_wall_tile_id - 1]
	previewbuild.set_cell(
		cell,
		int(spec["source_id"]),
		spec["atlas_coords"],
		int(spec["alternative_tile"])
	)
	previewbuild.update_internals()

func _clear_hover() -> void:
	if not _hover_active:
		return
	previewbuild.erase_cell(_hover_cell)
	previewbuild.update_internals()
	_hover_active = false
	_hover_label.visible = false

func _hovered_cell() -> Vector2i:
	var world := previewbuild.get_global_mouse_position()
	return previewbuild.local_to_map(previewbuild.to_local(world))

func _is_paused() -> bool:
	return pause_overlay and pause_overlay.visible

func _prepare_hover_label() -> void:
	_hover_label = Label.new()
	_hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_label.visible = false
	_hover_label.add_theme_constant_override("outline_size", 2)
	pause_overlay.add_child(_hover_label)

func _update_label() -> void:
	_hover_label.text = "%s (id %d)" % [_current_tile_key, _wall_tile_id]
	_hover_label.position = get_viewport().get_mouse_position() + TILE_LABEL_OFFSET
	_hover_label.visible = true

func _collect_tiles_from_tileset() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ref := previewbuild if previewbuild else wallz
	if not ref or not ref.tile_set:
		return out
	var ts := ref.tile_set
	for i in range(ts.get_source_count()):
		var sid := ts.get_source_id(i)
		var src := ts.get_source(sid)
		if src is TileSetAtlasSource:
			var atlas := src as TileSetAtlasSource
			var grid := atlas.get_atlas_grid_size()
			for x in range(grid.x):
				for y in range(grid.y):
					var c := Vector2i(x, y)
					if atlas.get_tile_at_coords(c) == c:
						out.append({
							"source_id": sid,
							"atlas_coords": c,
							"alternative_tile": 0
						})
	return out
