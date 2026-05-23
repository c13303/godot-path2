extends Node

@export var wallz: TileMapLayer
@export var buildings: TileMapLayer
@export var previewbuild: TileMapLayer
@export var pause_overlay: PauseOverlay

const BUILD_TILES_INDEX_PATH := "res://map_drawing/build_tiles_index.tres"
const TILE_LABEL_OFFSET := Vector2(12, 12)
const DEFAULT_WALL_TILE_KEY := "wall1"

var _tile_index: Dictionary = {}
var _tile_selection_keys: Array[String] = []

var _current_tile_key: String = DEFAULT_WALL_TILE_KEY
var _current_tile_key_index: int = 0
var _current_atlas_coords: Vector2i = Vector2i(-1, -1)
var _current_tile_kind: String = "wall"
var _current_target_layer: String = "wallz"

var _atlas_source_id: int = -1

var _hover_label: Label
var _hover_active: bool = false
var _hover_cell: Vector2i

func _ready() -> void:
	_resolve_atlas_source_id()
	_load_tile_index()
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
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_select_next_tile(-1)
			MOUSE_BUTTON_WHEEL_DOWN:
				_select_next_tile(1)
			MOUSE_BUTTON_LEFT:
				_apply_current_tile()
			MOUSE_BUTTON_RIGHT:
				_remove_tile()

func _resolve_atlas_source_id() -> void:
	var ref := previewbuild if previewbuild else wallz
	if not ref or not ref.tile_set:
		return

	var ts := ref.tile_set
	for i in range(ts.get_source_count()):
		var sid := ts.get_source_id(i)
		if ts.get_source(sid) is TileSetAtlasSource:
			_atlas_source_id = sid
			return

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
	_select_tile_by_key(_current_tile_key)

func _select_next_tile(dir: int) -> void:
	if _tile_selection_keys.is_empty():
		return

	_current_tile_key_index = (_current_tile_key_index + dir) % _tile_selection_keys.size()
	if _current_tile_key_index < 0:
		_current_tile_key_index += _tile_selection_keys.size()

	_select_tile_by_key(_tile_selection_keys[_current_tile_key_index])

	if _hover_active:
		_draw_preview(_hover_cell)
		_update_label()

func _select_tile_by_key(key: String) -> void:
	_current_tile_key = key

	var raw: Array = []
	if _tile_index.has(key):
		var definition: Variant = _tile_index[key]
		if definition is Dictionary:
			var tile_definition: Dictionary = definition as Dictionary
			_current_tile_kind = str(tile_definition.get("kind", "wall"))
			_current_target_layer = str(tile_definition.get("layer", "wallz"))
			raw = tile_definition.get("atlas", []) as Array
		elif definition is Array:
			_current_tile_kind = "wall"
			_current_target_layer = "wallz"
			raw = definition as Array

	if raw.size() != 2:
		_current_atlas_coords = Vector2i(-1, -1)
		return

	_current_atlas_coords = Vector2i(int(raw[0]), int(raw[1]))


func _draw_preview(cell: Vector2i) -> void:
	if _atlas_source_id < 0:
		return

	if _current_atlas_coords == Vector2i(-1, -1):
		previewbuild.erase_cell(cell)
	else:
		previewbuild.set_cell(
			cell,
			_atlas_source_id,
			_current_atlas_coords,
			0
		)
	previewbuild.update_internals()

func _apply_current_tile() -> void:
	if not _hover_active:
		return
	if _atlas_source_id < 0:
		return
	if _current_atlas_coords == Vector2i(-1, -1):
		return

	var target_layer := _target_tile_layer()
	if not target_layer:
		return

	_clear_other_build_layer(target_layer)
	target_layer.set_cell(
		_hover_cell,
		_atlas_source_id,
		_current_atlas_coords,
		0
	)
	target_layer.update_internals()

func _remove_tile() -> void:
	if not _hover_active:
		return
	if wallz:
		wallz.erase_cell(_hover_cell)
		wallz.update_internals()
	if buildings:
		buildings.erase_cell(_hover_cell)
		buildings.update_internals()

func _target_tile_layer() -> TileMapLayer:
	if _current_target_layer == "buildings":
		return buildings
	return wallz

func _clear_other_build_layer(target_layer: TileMapLayer) -> void:
	if target_layer != wallz and wallz:
		wallz.erase_cell(_hover_cell)
		wallz.update_internals()
	if target_layer != buildings and buildings:
		buildings.erase_cell(_hover_cell)
		buildings.update_internals()

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
	_hover_label.text = "%s [%d,%d]" % [
		_current_tile_key,
		_current_atlas_coords.x,
		_current_atlas_coords.y
	]
	_hover_label.position = get_viewport().get_mouse_position() + TILE_LABEL_OFFSET
	_hover_label.visible = true
