extends RefCounted
class_name TerrainSpeedModifierService

## Authoritative Godot-side terrain movement index.
##
## `_contributions` is: Vector2i cell -> int channel -> StringName source -> float.
## Missing cells are neutral. Player-channel entries may deliberately contain a neutral
## contribution so native channel 1 overrides channel 0 (roses and bamboo use this).

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


func set_cell_contribution(
	cell: Vector2i,
	source_id: StringName,
	multiplier: float,
	channel: int = DEFAULT_CHANNEL,
	upload: bool = true
) -> void:
	var cells: Array[Vector2i] = [cell]
	set_cells_contribution(cells, source_id, multiplier, channel, upload)


func set_cells_contribution(
	cells: Array[Vector2i],
	source_id: StringName,
	multiplier: float,
	channel: int = DEFAULT_CHANNEL,
	upload: bool = true
) -> void:
	if channel < DEFAULT_CHANNEL or source_id == &"" or cells.is_empty():
		return
	var normalized: float = _sanitize_multiplier(multiplier)
	var changed_cells: Array[Vector2i] = []
	var seen: Dictionary = {}
	for cell: Vector2i in cells:
		if seen.has(cell):
			continue
		seen[cell] = true
		var before_multiplier: float = effective_multiplier(cell, channel)
		var before_explicit: bool = _has_channel_contribution(cell, channel)
		if is_equal_approx(normalized, NEUTRAL_MULTIPLIER) and channel == DEFAULT_CHANNEL:
			_remove_local_contribution(cell, source_id, channel)
		else:
			_set_local_contribution(cell, source_id, normalized, channel)
		if _effective_state_changed(cell, channel, before_multiplier, before_explicit):
			changed_cells.append(cell)
	if upload:
		_upload_cells_for_channel(changed_cells, channel)


func set_cell_contribution_pair(
	cell: Vector2i,
	source_id: StringName,
	default_multiplier: float,
	player_multiplier: float,
	upload: bool = true
) -> void:
	var cells: Array[Vector2i] = [cell]
	set_cells_contribution_pair(cells, source_id, default_multiplier, player_multiplier, upload)


func set_cells_contribution_pair(
	cells: Array[Vector2i],
	source_id: StringName,
	default_multiplier: float,
	player_multiplier: float,
	upload: bool = true
) -> void:
	if source_id == &"" or cells.is_empty():
		return
	var normalized_default: float = _sanitize_multiplier(default_multiplier)
	var normalized_player: float = _sanitize_multiplier(player_multiplier)
	var default_changed: Array[Vector2i] = []
	var player_changed: Array[Vector2i] = []
	var seen: Dictionary = {}
	for cell: Vector2i in cells:
		if seen.has(cell):
			continue
		seen[cell] = true
		var default_before: float = effective_multiplier(cell, DEFAULT_CHANNEL)
		var default_explicit_before: bool = _has_channel_contribution(cell, DEFAULT_CHANNEL)
		var player_before: float = effective_multiplier(cell, PLAYER_CHANNEL)
		var player_explicit_before: bool = _has_channel_contribution(cell, PLAYER_CHANNEL)
		if is_equal_approx(normalized_default, NEUTRAL_MULTIPLIER):
			_remove_local_contribution(cell, source_id, DEFAULT_CHANNEL)
		else:
			_set_local_contribution(cell, source_id, normalized_default, DEFAULT_CHANNEL)
		# Player channel must stay explicit even at 1.0. Without that override the native grid
		# falls back to channel 0 and player-exempt terrain would still slow the player.
		_set_local_contribution(cell, source_id, normalized_player, PLAYER_CHANNEL)
		if _effective_state_changed(cell, DEFAULT_CHANNEL, default_before, default_explicit_before):
			default_changed.append(cell)
		if _effective_state_changed(cell, PLAYER_CHANNEL, player_before, player_explicit_before):
			player_changed.append(cell)
	if upload:
		_upload_cells_for_channel(default_changed, DEFAULT_CHANNEL)
		_upload_cells_for_channel(player_changed, PLAYER_CHANNEL)


func clear_cell_contribution(
	cell: Vector2i,
	source_id: StringName,
	channel: int = DEFAULT_CHANNEL,
	upload: bool = true
) -> void:
	var cells: Array[Vector2i] = [cell]
	clear_cells_contribution(cells, source_id, channel, upload)


func clear_cells_contribution(
	cells: Array[Vector2i],
	source_id: StringName,
	channel: int = DEFAULT_CHANNEL,
	upload: bool = true
) -> void:
	if channel < DEFAULT_CHANNEL or source_id == &"" or cells.is_empty():
		return
	var changed_cells: Array[Vector2i] = []
	var seen: Dictionary = {}
	for cell: Vector2i in cells:
		if seen.has(cell):
			continue
		seen[cell] = true
		var before_multiplier: float = effective_multiplier(cell, channel)
		var before_explicit: bool = _has_channel_contribution(cell, channel)
		_remove_local_contribution(cell, source_id, channel)
		if _effective_state_changed(cell, channel, before_multiplier, before_explicit):
			changed_cells.append(cell)
	if upload:
		_upload_cells_for_channel(changed_cells, channel)


func clear_cell_contribution_pair(cell: Vector2i, source_id: StringName, upload: bool = true) -> void:
	var cells: Array[Vector2i] = [cell]
	clear_cells_contribution_pair(cells, source_id, upload)


func clear_cells_contribution_pair(cells: Array[Vector2i], source_id: StringName, upload: bool = true) -> void:
	if source_id == &"" or cells.is_empty():
		return
	var default_changed: Array[Vector2i] = []
	var player_changed: Array[Vector2i] = []
	var seen: Dictionary = {}
	for cell: Vector2i in cells:
		if seen.has(cell):
			continue
		seen[cell] = true
		var default_before: float = effective_multiplier(cell, DEFAULT_CHANNEL)
		var default_explicit_before: bool = _has_channel_contribution(cell, DEFAULT_CHANNEL)
		var player_before: float = effective_multiplier(cell, PLAYER_CHANNEL)
		var player_explicit_before: bool = _has_channel_contribution(cell, PLAYER_CHANNEL)
		_remove_local_contribution(cell, source_id, DEFAULT_CHANNEL)
		_remove_local_contribution(cell, source_id, PLAYER_CHANNEL)
		if _effective_state_changed(cell, DEFAULT_CHANNEL, default_before, default_explicit_before):
			default_changed.append(cell)
		if _effective_state_changed(cell, PLAYER_CHANNEL, player_before, player_explicit_before):
			player_changed.append(cell)
	if upload:
		_upload_cells_for_channel(default_changed, DEFAULT_CHANNEL)
		_upload_cells_for_channel(player_changed, PLAYER_CHANNEL)


func upload_all_channels() -> void:
	var default_cells: PackedVector2Array = PackedVector2Array()
	var default_multipliers: PackedFloat32Array = PackedFloat32Array()
	var player_cells: PackedVector2Array = PackedVector2Array()
	var player_multipliers: PackedFloat32Array = PackedFloat32Array()
	for raw_cell: Variant in _contributions.keys():
		var cell: Vector2i = raw_cell as Vector2i
		_append_effective(default_cells, default_multipliers, cell, DEFAULT_CHANNEL)
		_append_effective(player_cells, player_multipliers, cell, PLAYER_CHANNEL)
	_replace_channel(default_cells, default_multipliers, DEFAULT_CHANNEL)
	_replace_channel(player_cells, player_multipliers, PLAYER_CHANNEL)


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
	return compose_multipliers((by_channel[channel] as Dictionary).values())


## Central composition rule shared by runtime contributions and layer-derived sources:
## strongest slowdown wins; otherwise strongest speed-up wins; otherwise neutral.
func compose_multipliers(multipliers: Array) -> float:
	var strongest_slowdown: float = NEUTRAL_MULTIPLIER
	var strongest_speedup: float = NEUTRAL_MULTIPLIER
	for raw_value: Variant in multipliers:
		var multiplier: float = _sanitize_multiplier(float(raw_value))
		if multiplier < NEUTRAL_MULTIPLIER:
			strongest_slowdown = minf(strongest_slowdown, multiplier)
		elif multiplier > NEUTRAL_MULTIPLIER:
			strongest_speedup = maxf(strongest_speedup, multiplier)
	if strongest_slowdown < NEUTRAL_MULTIPLIER:
		return strongest_slowdown
	return strongest_speedup


func _effective_state_changed(
	cell: Vector2i,
	channel: int,
	before_multiplier: float,
	before_explicit: bool
) -> bool:
	var after_multiplier: float = effective_multiplier(cell, channel)
	var after_explicit: bool = _has_channel_contribution(cell, channel)
	return before_explicit != after_explicit or not is_equal_approx(before_multiplier, after_multiplier)


func _has_channel_contribution(cell: Vector2i, channel: int) -> bool:
	var by_channel: Dictionary = _contributions.get(cell, {}) as Dictionary
	return not by_channel.is_empty() and by_channel.has(channel)


func _set_local_contribution(cell: Vector2i, source_id: StringName, multiplier: float, channel: int) -> void:
	var by_channel: Dictionary = _contributions.get(cell, {}) as Dictionary
	var by_source: Dictionary = by_channel.get(channel, {}) as Dictionary
	by_source[source_id] = multiplier
	by_channel[channel] = by_source
	_contributions[cell] = by_channel


func _remove_local_contribution(cell: Vector2i, source_id: StringName, channel: int) -> void:
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


func _upload_cells_for_channel(cells: Array[Vector2i], channel: int) -> void:
	if _steering == null or cells.is_empty():
		return
	var set_cells: PackedVector2Array = PackedVector2Array()
	var set_multipliers: PackedFloat32Array = PackedFloat32Array()
	var clear_cells: PackedVector2Array = PackedVector2Array()
	var seen: Dictionary = {}
	for cell: Vector2i in cells:
		if seen.has(cell):
			continue
		seen[cell] = true
		var explicit: bool = _has_channel_contribution(cell, channel)
		var multiplier: float = effective_multiplier(cell, channel)
		if not explicit or (channel == DEFAULT_CHANNEL and is_equal_approx(multiplier, NEUTRAL_MULTIPLIER)):
			clear_cells.append(Vector2(float(cell.x), float(cell.y)))
		else:
			set_cells.append(Vector2(float(cell.x), float(cell.y)))
			set_multipliers.append(multiplier)
	if set_cells.size() > 0 and _steering.has_method("set_terrain_speed_cells"):
		_steering.call("set_terrain_speed_cells", set_cells, set_multipliers, channel)
	if clear_cells.size() > 0 and _steering.has_method("clear_terrain_speed_cells"):
		_steering.call("clear_terrain_speed_cells", clear_cells, channel)


func _replace_channel(cells: PackedVector2Array, multipliers: PackedFloat32Array, channel: int) -> void:
	if _steering == null or not _steering.has_method("replace_terrain_speed_channel"):
		return
	_steering.call("replace_terrain_speed_channel", cells, multipliers, channel)


func _append_effective(
	cells: PackedVector2Array,
	multipliers: PackedFloat32Array,
	cell: Vector2i,
	channel: int
) -> void:
	if not _has_channel_contribution(cell, channel):
		return
	var multiplier: float = effective_multiplier(cell, channel)
	if is_equal_approx(multiplier, NEUTRAL_MULTIPLIER) and channel == DEFAULT_CHANNEL:
		return
	cells.append(Vector2(float(cell.x), float(cell.y)))
	multipliers.append(multiplier)


func _sanitize_multiplier(multiplier: float) -> float:
	if is_nan(multiplier) or is_inf(multiplier) or multiplier <= 0.0:
		return NEUTRAL_MULTIPLIER
	return clampf(multiplier, MIN_MULTIPLIER, MAX_MULTIPLIER)
