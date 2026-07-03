extends RefCounted
class_name SpawnPlaylistController

const RETRY_DELAY_SECONDS: float = 0.25

var _playlist: LevelSpawnPlaylist
var _spawner_bindings_by_id: Dictionary = {}
var _resource_path: String = ""
var _current_night_index: int = -1
var _current_night: NightSpawnPlaylist
var _tracks: Array[Dictionary] = []
var _events_emitted: Dictionary = {}
var _pending_emits: Array[Dictionary] = []
var _valid_monster_types: Dictionary = {}
var _configured: bool = false
var _last_errors: Array[String] = []


func configure(
		playlist: LevelSpawnPlaylist,
		spawner_bindings_by_id: Dictionary,
		physical_spawner_cells: Dictionary,
		valid_monster_types: Dictionary
) -> bool:
	_playlist = playlist
	_spawner_bindings_by_id = spawner_bindings_by_id.duplicate()
	_valid_monster_types = valid_monster_types.duplicate()
	_resource_path = playlist.resource_path if playlist != null else "<missing>"
	_last_errors.clear()
	_configured = _validate_playlist(physical_spawner_cells)
	return _configured


func get_last_errors() -> Array[String]:
	return _last_errors.duplicate()


func is_configured() -> bool:
	return _configured


func get_total_night_count() -> int:
	return _playlist.get_night_count() if _playlist != null else 0


func get_current_night_debug_lines() -> Array[String]:
	var lines: Array[String] = []
	if _current_night == null:
		return lines
	for track: SpawnerWaveTrack in _current_night.spawner_tracks:
		if track == null:
			lines.append("track=<null>")
			continue
		if track.waves.is_empty():
			lines.append("spawner_id=%s waves=0" % String(track.spawner_id))
			continue
		var wave: SpawnWave = track.waves[0]
		if wave == null:
			lines.append("spawner_id=%s first_wave=<null>" % String(track.spawner_id))
			continue
		lines.append("spawner_id=%s first_wave_count=%d interval=%.2f wait=%s emit=%s wave_count=%d" % [
			String(track.spawner_id),
			wave.monster_count,
			wave.spawn_interval_seconds,
			String(wave.wait_for_event),
			String(wave.emit_event),
			track.waves.size(),
		])
	return lines


func begin_night(night_index: int) -> bool:
	_current_night_index = night_index
	_current_night = null
	_tracks.clear()
	_events_emitted.clear()
	_pending_emits.clear()
	if not _configured:
		return false
	if _playlist == null or night_index < 0 or night_index >= _playlist.nights.size():
		return false
	_current_night = _playlist.nights[night_index]
	var track_index: int = 0
	for track: SpawnerWaveTrack in _current_night.spawner_tracks:
		_tracks.append({
			"track_index": track_index,
			"spawner_id": track.spawner_id,
			"wave_index": 0,
			"spawned_count": 0,
			"time_until_next_spawn": 0.0,
			"pending": false,
			"complete": false,
		})
		track_index += 1
	return true


func advance(delta: float) -> Array[Dictionary]:
	var requests: Array[Dictionary] = []
	if _current_night == null:
		return requests
	# Fire any delayed wave events whose timer has elapsed before advancing tracks,
	# so a wave waiting on the event can react on the same tick it becomes ready.
	_advance_pending_emits(delta)
	for track_state: Dictionary in _tracks:
		_advance_track_past_completed_zero_waves(track_state)
		if bool(track_state.get("complete", false)) or bool(track_state.get("pending", false)):
			continue
		var wave: SpawnWave = _get_current_wave(track_state)
		if wave == null:
			track_state["complete"] = true
			continue
		if wave.wait_for_event != &"" and not _events_emitted.has(wave.wait_for_event):
			continue
		var time_left: float = float(track_state.get("time_until_next_spawn", 0.0))
		if time_left > 0.0:
			time_left = maxf(0.0, time_left - delta)
			track_state["time_until_next_spawn"] = time_left
			if time_left > 0.0:
				continue
		var spawner_id: StringName = StringName(str(track_state.get("spawner_id", "")))
		var cell: Vector2i = _spawner_bindings_by_id.get(spawner_id, Vector2i.ZERO) as Vector2i
		track_state["pending"] = true
		requests.append({
			"track_index": int(track_state.get("track_index", -1)),
			"spawner_id": spawner_id,
			"spawner_cell": cell,
			"monster_type": wave.monster_type,
			"night_index": _current_night_index,
			"wave_index": int(track_state.get("wave_index", 0)),
		})
	return requests


func mark_spawn_result(track_index: int, success: bool, failure_reason: String = "") -> void:
	if track_index < 0 or track_index >= _tracks.size():
		return
	var track_state: Dictionary = _tracks[track_index]
	track_state["pending"] = false
	var wave: SpawnWave = _get_current_wave(track_state)
	if wave == null:
		track_state["complete"] = true
		return
	if not success:
		track_state["time_until_next_spawn"] = RETRY_DELAY_SECONDS
		if failure_reason != "":
			track_state["last_failure_reason"] = failure_reason
		return
	var spawned_count: int = int(track_state.get("spawned_count", 0)) + 1
	track_state["spawned_count"] = spawned_count
	if spawned_count >= wave.monster_count:
		_emit_wave_event(wave)
		track_state["wave_index"] = int(track_state.get("wave_index", 0)) + 1
		track_state["spawned_count"] = 0
		track_state["time_until_next_spawn"] = 0.0
		_advance_track_past_completed_zero_waves(track_state)
	else:
		track_state["time_until_next_spawn"] = wave.spawn_interval_seconds


func is_current_night_schedule_complete() -> bool:
	if _current_night == null:
		return false
	for track_state: Dictionary in _tracks:
		_advance_track_past_completed_zero_waves(track_state)
		if not bool(track_state.get("complete", false)):
			return false
	return true


func get_track_debug_context(track_index: int) -> String:
	if track_index < 0 or track_index >= _tracks.size():
		return "night=%d track=%d" % [_current_night_index + 1, track_index]
	var state: Dictionary = _tracks[track_index]
	var wave_index: int = int(state.get("wave_index", 0))
	var wave: SpawnWave = _get_current_wave(state)
	var total: int = wave.monster_count if wave != null else 0
	return "night=%d spawner_id=%s wave=%d spawned=%d/%d" % [
		_current_night_index + 1,
		String(state.get("spawner_id", &"")),
		wave_index + 1,
		int(state.get("spawned_count", 0)),
		total,
	]


func _advance_track_past_completed_zero_waves(track_state: Dictionary) -> void:
	while true:
		var wave: SpawnWave = _get_current_wave(track_state)
		if wave == null:
			track_state["complete"] = true
			return
		if wave.wait_for_event != &"" and not _events_emitted.has(wave.wait_for_event):
			return
		if wave.monster_count > 0:
			return
		_emit_wave_event(wave)
		track_state["wave_index"] = int(track_state.get("wave_index", 0)) + 1
		track_state["spawned_count"] = 0
		track_state["time_until_next_spawn"] = 0.0


func _emit_wave_event(wave: SpawnWave) -> void:
	if wave.emit_event == &"":
		return
	# A zero delay keeps the old immediate behaviour; otherwise the emit is queued and
	# fired later from _advance_pending_emits once its timer runs out.
	if wave.emit_delay_seconds > 0.0:
		_pending_emits.append({"event": wave.emit_event, "time_left": wave.emit_delay_seconds})
	else:
		_events_emitted[wave.emit_event] = true


# Counts down queued delayed emits, marking each event emitted once its timer elapses.
# Any wait_for_event depending on it will see it on the tick it fires.
func _advance_pending_emits(delta: float) -> void:
	if _pending_emits.is_empty():
		return
	var still_pending: Array[Dictionary] = []
	for pending: Dictionary in _pending_emits:
		var time_left: float = float(pending.get("time_left", 0.0)) - delta
		if time_left <= 0.0:
			_events_emitted[StringName(str(pending.get("event", "")))] = true
		else:
			pending["time_left"] = time_left
			still_pending.append(pending)
	_pending_emits = still_pending


func _get_current_wave(track_state: Dictionary) -> SpawnWave:
	if _current_night == null:
		return null
	var track_index: int = int(track_state.get("track_index", -1))
	if track_index < 0 or track_index >= _current_night.spawner_tracks.size():
		return null
	var track: SpawnerWaveTrack = _current_night.spawner_tracks[track_index]
	var wave_index: int = int(track_state.get("wave_index", 0))
	if wave_index < 0 or wave_index >= track.waves.size():
		return null
	return track.waves[wave_index]


func _validate_playlist(physical_spawner_cells: Dictionary) -> bool:
	if _playlist == null:
		_add_error("missing playlist")
		return false
	if _playlist.nights.is_empty():
		_add_error("empty playlist")
	for raw_id: Variant in _spawner_bindings_by_id.keys():
		var spawner_id: StringName = StringName(str(raw_id))
		var cell: Vector2i = _spawner_bindings_by_id[spawner_id] as Vector2i
		if not physical_spawner_cells.has(cell):
			_add_error("bound cell does not correspond to a scanned physical spawner: spawner_id=%s cell=%s" % [String(spawner_id), str(cell)])
	var night_index: int = 0
	for night: NightSpawnPlaylist in _playlist.nights:
		if night == null:
			_add_error("night=%d null night entry" % [night_index + 1])
			night_index += 1
			continue
		_validate_night(night, night_index)
		night_index += 1
	return _last_errors.is_empty()


func _validate_night(night: NightSpawnPlaylist, night_index: int) -> void:
	var track_ids: Dictionary = {}
	var emit_counts: Dictionary = {}
	for track: SpawnerWaveTrack in night.spawner_tracks:
		if track == null:
			continue
		for wave: SpawnWave in track.waves:
			if wave != null and wave.emit_event != &"":
				emit_counts[wave.emit_event] = int(emit_counts.get(wave.emit_event, 0)) + 1
	var track_index: int = 0
	for track: SpawnerWaveTrack in night.spawner_tracks:
		if track == null:
			_add_error("night=%d track=%d null spawner track" % [night_index + 1, track_index + 1])
			track_index += 1
			continue
		var spawner_id: StringName = track.spawner_id
		if spawner_id == &"":
			_add_error("night=%d track=%d empty spawner_id" % [night_index + 1, track_index + 1])
		elif track_ids.has(spawner_id):
			_add_error("night=%d spawner_id=%s duplicate spawner track" % [night_index + 1, String(spawner_id)])
		elif not _spawner_bindings_by_id.has(spawner_id):
			_add_error("night=%d spawner_id=%s unknown spawner ID" % [night_index + 1, String(spawner_id)])
		track_ids[spawner_id] = true
		var wave_index: int = 0
		for wave: SpawnWave in track.waves:
			if wave == null:
				_add_error("night=%d spawner_id=%s wave=%d null wave entry" % [night_index + 1, String(spawner_id), wave_index + 1])
				wave_index += 1
				continue
			if wave.monster_count < 0:
				_add_error("night=%d spawner_id=%s wave=%d negative monster_count" % [night_index + 1, String(spawner_id), wave_index + 1])
			if wave.spawn_interval_seconds < 0.0:
				_add_error("night=%d spawner_id=%s wave=%d negative spawn_interval_seconds" % [night_index + 1, String(spawner_id), wave_index + 1])
			if wave.monster_type == &"" or not _valid_monster_types.has(wave.monster_type):
				_add_error("night=%d spawner_id=%s wave=%d invalid monster_type=%s" % [night_index + 1, String(spawner_id), wave_index + 1, String(wave.monster_type)])
			if wave.wait_for_event != &"":
				if not emit_counts.has(wave.wait_for_event):
					_add_error("night=%d spawner_id=%s wave=%d waits for event never emitted in this night: %s" % [night_index + 1, String(spawner_id), wave_index + 1, String(wave.wait_for_event)])
				if wave.wait_for_event == wave.emit_event and int(emit_counts.get(wave.wait_for_event, 0)) == 1:
					_add_error("night=%d spawner_id=%s wave=%d waits for event only emitted by itself: %s" % [night_index + 1, String(spawner_id), wave_index + 1, String(wave.wait_for_event)])
			wave_index += 1
		track_index += 1


func _add_error(message: String) -> void:
	_last_errors.append("Spawn playlist '%s': %s" % [_resource_path, message])
