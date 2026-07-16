extends RefCounted
class_name TerrainSpeedModifierService

const DEFAULT_CHANNEL: int = 0
const PLAYER_CHANNEL: int = 1
const NEUTRAL_MULTIPLIER: float = 1.0
const MIN_MULTIPLIER: float = 0.05
const MAX_MULTIPLIER: float = 4.0

var _steering: Node = null
var _contributions: Dictionary = {}


func setup(steering: Node) -> void:
	_steering = steering


func set_steering(steering: Node) -> void:
	_steering = steering


func set_cell_contribution(cell: Vector2i, source_id: StringName, multiplier: float, channel: int = DEFAULT_CHANNEL, upload: bool = true) -> void:
	if channel < DEFAULT_CHANNEL:
		return
	var normalized: float = _sanitize_multiplier(multiplier)
	if is_equal_approx(normalized, NEUTRAL_MULTIPLIER):
		clear_cell_contribution(cell, source_id, channel)
		return
	_set_local_contribution(cell, source_id, normalized, channel)
	if upload:
		_upload_cell(cell, channel)


func set_cell_contribution_pair(cell: Vector2i, source_id: StringName, default_multiplier: float, player_multiplier: float, upload: bool = true) -> void:
	set_cell_contribution(cell, source_id, default_multiplier, DEFAULT_CHANNEL, upload)
	# Player channel must be explicit even when neutral, otherwise native fallback would use
	# channel 0 and player-exempt tiles such as roses/bamboo would still slow the player.
	_set_local_contribution(cell, source_id, _sanitize_multiplier(player_multiplier), PLAYER_CHANNEL)
	if upload:
		_upload_cell(cell, PLAYER_CHANNEL)


func clear_cell_contribution(cell: Vector2i, source_id: StringName, channel: int = DEFAULT_CHANNEL) -> void:
	if channel < DEFAULT_CHANNEL:
		return
	var by_channel: Dictionary = _contributions.get(cell, {}) as Dictionary
	if by_channel.is_empty() or not by_channel.has(channel):
		return
	var by_source: Dictionary = by_channel[channel] as Dictionary
	by_source.erase(source_id)
	if by_source.is_empty():
		by_channel.erase(channel)
	else:
		by_channel[channel] = by_source
	if by_channel.is_empty():
		_contributions.erase(cell)
	else:
		_contributions[cell] = by_channel
	_upload_cell(cell, channel)


func replace_channel(cells: PackedVector2Array, multipliers: PackedFloat32Array, channel: int = DEFAULT_CHANNEL) -> void:
	if _steering == null or not _steering.has_method("replace_terrain_speed_channel"):
		return
	if cells.size() != multipliers.size():
		push_warning("TerrainSpeedModifierService.replace_channel ignored mismatched arrays.")
		return
	_steering.call("replace_terrain_speed_channel", cells, multipliers, channel)


func upload_all_channels() -> void:
	var default_cells: PackedVector2Array = PackedVector2Array()
	var default_multipliers: PackedFloat32Array = PackedFloat32Array()
	var player_cells: PackedVector2Array = PackedVector2Array()
	var player_multipliers: PackedFloat32Array = PackedFloat32Array()
	for raw_cell: Variant in _contributions.keys():
		var cell: Vector2i = raw_cell as Vector2i
		_append_effective(default_cells, default_multipliers, cell, DEFAULT_CHANNEL)
		_append_effective(player_cells, player_multipliers, cell, PLAYER_CHANNEL)
	replace_channel(default_cells, default_multipliers, DEFAULT_CHANNEL)
	replace_channel(player_cells, player_multipliers, PLAYER_CHANNEL)


func upload_cells(cells: Array[Vector2i]) -> void:
	if _steering == null:
		return
	var default_set_cells: PackedVector2Array = PackedVector2Array()
	var default_set_multipliers: PackedFloat32Array = PackedFloat32Array()
	var default_clear_cells: PackedVector2Array = PackedVector2Array()
	var player_set_cells: PackedVector2Array = PackedVector2Array()
	var player_set_multipliers: PackedFloat32Array = PackedFloat32Array()
	for cell: Vector2i in cells:
		var default_multiplier: float = effective_multiplier(cell, DEFAULT_CHANNEL)
		if is_equal_approx(default_multiplier, NEUTRAL_MULTIPLIER):
			default_clear_cells.append(Vector2(float(cell.x), float(cell.y)))
		else:
			default_set_cells.append(Vector2(float(cell.x), float(cell.y)))
			default_set_multipliers.append(default_multiplier)
		if _has_channel_contribution(cell, PLAYER_CHANNEL):
			var player_multiplier: float = effective_multiplier(cell, PLAYER_CHANNEL)
			player_set_cells.append(Vector2(float(cell.x), float(cell.y)))
			player_set_multipliers.append(player_multiplier)
	if default_set_cells.size() > 0 and _steering.has_method("set_terrain_speed_cells"):
		_steering.call("set_terrain_speed_cells", default_set_cells, default_set_multipliers, DEFAULT_CHANNEL)
	if default_clear_cells.size() > 0 and _steering.has_method("clear_terrain_speed_cells"):
		_steering.call("clear_terrain_speed_cells", default_clear_cells, DEFAULT_CHANNEL)
	if player_set_cells.size() > 0 and _steering.has_method("set_terrain_speed_cells"):
		_steering.call("set_terrain_speed_cells", player_set_cells, player_set_multipliers, PLAYER_CHANNEL)


func clear_all_native_channels() -> void:
	if _steering == null or not _steering.has_method("clear_terrain_speed_channel"):
		return
	_steering.call("clear_terrain_speed_channel", DEFAULT_CHANNEL)
	_steering.call("clear_terrain_speed_channel", PLAYER_CHANNEL)


func clear_local_contributions() -> void:
	_contributions.clear()


func effective_multiplier(cell: Vector2i, channel: int = DEFAULT_CHANNEL) -> float:
	var by_channel: Dictionary = _contributions.get(cell, {}) as Dictionary
	if by_channel.is_empty() or not by_channel.has(channel):
		return NEUTRAL_MULTIPLIER
	return _compose(by_channel[channel] as Dictionary)


func _has_channel_contribution(cell: Vector2i, channel: int) -> bool:
	var by_channel: Dictionary = _contributions.get(cell, {}) as Dictionary
	return not by_channel.is_empty() and by_channel.has(channel)


func _set_local_contribution(cell: Vector2i, source_id: StringName, multiplier: float, channel: int) -> void:
	var by_channel: Dictionary = _contributions.get(cell, {}) as Dictionary
	var by_source: Dictionary = by_channel.get(channel, {}) as Dictionary
	by_source[source_id] = multiplier
	by_channel[channel] = by_source
	_contributions[cell] = by_channel


func _upload_cell(cell: Vector2i, channel: int) -> void:
	if _steering == null:
		return
	var multiplier: float = effective_multiplier(cell, channel)
	if is_equal_approx(multiplier, NEUTRAL_MULTIPLIER) and (channel == DEFAULT_CHANNEL or not _has_channel_contribution(cell, channel)):
		if _steering.has_method("clear_terrain_speed_cell"):
			_steering.call("clear_terrain_speed_cell", cell, channel)
		return
	if _steering.has_method("set_terrain_speed_cell"):
		_steering.call("set_terrain_speed_cell", cell, multiplier, channel)


func _append_effective(cells: PackedVector2Array, multipliers: PackedFloat32Array, cell: Vector2i, channel: int) -> void:
	var by_channel: Dictionary = _contributions.get(cell, {}) as Dictionary
	if by_channel.is_empty() or not by_channel.has(channel):
		return
	var multiplier: float = _compose(by_channel[channel] as Dictionary)
	if is_equal_approx(multiplier, NEUTRAL_MULTIPLIER) and channel == DEFAULT_CHANNEL:
		return
	cells.append(Vector2(float(cell.x), float(cell.y)))
	multipliers.append(multiplier)


func _compose(by_source: Dictionary) -> float:
	var strongest_slowdown: float = NEUTRAL_MULTIPLIER
	var strongest_speedup: float = NEUTRAL_MULTIPLIER
	for raw_value: Variant in by_source.values():
		var multiplier: float = _sanitize_multiplier(float(raw_value))
		if multiplier < NEUTRAL_MULTIPLIER:
			strongest_slowdown = minf(strongest_slowdown, multiplier)
		elif multiplier > NEUTRAL_MULTIPLIER:
			strongest_speedup = maxf(strongest_speedup, multiplier)
	if strongest_slowdown < NEUTRAL_MULTIPLIER:
		return strongest_slowdown
	return strongest_speedup


func _sanitize_multiplier(multiplier: float) -> float:
	if is_nan(multiplier) or is_inf(multiplier) or multiplier <= 0.0:
		return NEUTRAL_MULTIPLIER
	return clampf(multiplier, MIN_MULTIPLIER, MAX_MULTIPLIER)
