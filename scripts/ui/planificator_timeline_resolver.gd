extends RefCounted
class_name PlanificatorTimelineResolver

# Turns the current game/playlist state into an ordered list of one or two display
# slots for the planificator. This is the single owner of the planificator's schedule
# semantics: which encounter is running "now", what comes tonight/tomorrow, and when
# only victory remains.
#
# It is pure decisioning: it reads authored data from the playlist, live counts passed
# in by the renderer, and the current GameState phase. It never creates Controls,
# mutates scene nodes, spawns agents, or changes progression.
#
# Night indexing anchor (playlist indices are zero-based):
#   During a night, the anchor is the night being fought.
#   During the following day, the anchor is that same (just-completed) night, whose
#   clients the day serves. The runtime playlist night index carries this anchor across
#   the night->day transition without depending on the incremented progression day; the
#   day-number fallback (day - 1 at night, day - 2 during the day) is used only when the
#   runtime index is unavailable (e.g. a save loaded straight into a day phase).
# The upcoming night is always anchor + 1 during the day. Indices are never wrapped with
# modulo and never clamped to the final night.

const SLOT_NOW: StringName = &"now"
const SLOT_TONIGHT: StringName = &"tonight"
const SLOT_TOMORROW: StringName = &"tomorrow"
const SLOT_VICTORY: StringName = &"victory"

const CLIENT_AGENT: StringName = &"client"


# One agent row inside a slot (an icon + a count).
class TimelineRow extends RefCounted:
	var agent_type: StringName
	var count: int

	func _init(row_agent_type: StringName, row_count: int) -> void:
		agent_type = row_agent_type
		count = row_count


# One display slot: a translated section label, its ordered rows, and whether it is the
# terminal victory slot (which carries a label but no rows).
class TimelineSlot extends RefCounted:
	var kind: StringName
	var rows: Array[TimelineRow] = []
	var is_victory: bool = false

	func _init(slot_kind: StringName, slot_is_victory: bool = false) -> void:
		kind = slot_kind
		is_victory = slot_is_victory


# Resolve the ordered slots for the current frame. For a playlist-driven run this always
# returns exactly two ordered slots, or a single VICTORY slot; the renderer validates the
# result before publishing it. Legacy levels with no authored playlist fall back to a
# single live-count slot.
func resolve(
	playlist: LevelSpawnPlaylist,
	day_number: int,
	anchor_night_index: int,
	client_step_pending: bool,
	live_now_monster_counts: Dictionary,
	live_now_client_count: int
) -> Array:
	# Victory is authoritative once latched, regardless of any residual counts.
	if GameState.is_run_won:
		return [_victory_slot()]

	var total_nights: int = playlist.get_night_count() if playlist != null else 0
	if total_nights <= 0:
		return _fallback_slots(live_now_monster_counts, live_now_client_count)

	# Night: the live monster fight is the running encounter; tomorrow's clients are the
	# clients authored on the night currently being fought.
	if GameState.is_night:
		var fought_index: int = anchor_night_index if anchor_night_index >= 0 else day_number - 1
		var night_slots: Array = [_now_monster_slot(live_now_monster_counts)]
		if _index_exists(fought_index, total_nights):
			night_slots.append(_tomorrow_client_slot(_authored_client_count(playlist, fought_index)))
		return night_slots

	# Daytime. The anchor is the just-completed night whose clients this day serves.
	var completed_index: int = anchor_night_index if anchor_night_index >= 0 else day_number - 2
	var upcoming_index: int = completed_index + 1

	# The day's client step is "in progress" from the instant the night ends until the
	# step is explicitly completed or skipped (client_step_pending). We still require a
	# positive live client count so a completed night with no authored clients falls
	# straight through to the next-night preview instead of publishing an empty NOW slot.
	var clients_in_progress: bool = (
		client_step_pending
		and _index_exists(completed_index, total_nights)
		and live_now_client_count > 0
	)
	if clients_in_progress:
		var day_slots: Array = [_now_client_slot(live_now_client_count)]
		if _index_exists(upcoming_index, total_nights):
			day_slots.append(_tonight_monster_slot(playlist, upcoming_index))
		else:
			# Final client day: no authored night remains after these clients.
			day_slots.append(_victory_slot())
		return day_slots

	# No clients in progress: preview the upcoming night's build target.
	if _index_exists(upcoming_index, total_nights):
		return [
			_tonight_monster_slot(playlist, upcoming_index),
			_tomorrow_client_slot(_authored_client_count(playlist, upcoming_index)),
		]

	# No upcoming night and no clients running: the run is effectively over.
	return [_victory_slot()]


# Legacy behaviour for levels with no authored playlist: show only the current phase's
# live count, matching the old single-section planificator.
func _fallback_slots(live_now_monster_counts: Dictionary, live_now_client_count: int) -> Array:
	if GameState.is_night:
		return [_now_monster_slot(live_now_monster_counts)]
	if live_now_client_count > 0:
		return [_now_client_slot(live_now_client_count)]
	return []


func _index_exists(index: int, total_nights: int) -> bool:
	return index >= 0 and index < total_nights


func _now_monster_slot(counts: Dictionary) -> TimelineSlot:
	var slot: TimelineSlot = TimelineSlot.new(SLOT_NOW)
	_append_monster_rows(slot, counts)
	return slot


func _now_client_slot(live_count: int) -> TimelineSlot:
	var slot: TimelineSlot = TimelineSlot.new(SLOT_NOW)
	_append_row(slot, CLIENT_AGENT, live_count)
	return slot


func _tomorrow_client_slot(authored_count: int) -> TimelineSlot:
	var slot: TimelineSlot = TimelineSlot.new(SLOT_TOMORROW)
	_append_row(slot, CLIENT_AGENT, authored_count)
	return slot


func _tonight_monster_slot(playlist: LevelSpawnPlaylist, night_index: int) -> TimelineSlot:
	var slot: TimelineSlot = TimelineSlot.new(SLOT_TONIGHT)
	_append_monster_rows(slot, _authored_monster_counts(playlist, night_index))
	return slot


func _victory_slot() -> TimelineSlot:
	return TimelineSlot.new(SLOT_VICTORY, true)


# Emit one row per monster type, catalog types first (in catalog order) and any other
# authored/live type appended after. Generic: a newly catalogued monster type needs no
# change here.
func _append_monster_rows(slot: TimelineSlot, counts: Dictionary) -> void:
	for monster_type: StringName in _ordered_monster_types(counts):
		_append_row(slot, monster_type, int(counts.get(monster_type, 0)))


func _ordered_monster_types(counts: Dictionary) -> Array[StringName]:
	var ordered: Array[StringName] = []
	var seen: Dictionary = {}
	for monster_id: StringName in MonsterCatalog.get_ids():
		if counts.has(monster_id) and not seen.has(monster_id):
			ordered.append(monster_id)
			seen[monster_id] = true
	for raw_type: Variant in counts.keys():
		var monster_type: StringName = StringName(str(raw_type))
		if seen.has(monster_type):
			continue
		ordered.append(monster_type)
		seen[monster_type] = true
	return ordered


# Skip empty rows so the renderer never draws an "X 0" line.
func _append_row(slot: TimelineSlot, agent_type: StringName, count: int) -> void:
	if count <= 0:
		return
	slot.rows.append(TimelineRow.new(agent_type, count))


func _authored_client_count(playlist: LevelSpawnPlaylist, night_index: int) -> int:
	var night: NightSpawnPlaylist = _night_at(playlist, night_index)
	if night == null:
		return 0
	return maxi(0, night.clients)


func _authored_monster_counts(playlist: LevelSpawnPlaylist, night_index: int) -> Dictionary:
	var counts: Dictionary = {}
	var night: NightSpawnPlaylist = _night_at(playlist, night_index)
	if night == null:
		return counts
	for track: SpawnerWaveTrack in night.spawner_tracks:
		if track == null:
			continue
		for wave: SpawnWave in track.waves:
			if wave == null:
				continue
			var monster_type: StringName = wave.monster_type
			var count: int = maxi(0, wave.monster_count)
			counts[monster_type] = int(counts.get(monster_type, 0)) + count
	return counts


func _night_at(playlist: LevelSpawnPlaylist, night_index: int) -> NightSpawnPlaylist:
	if playlist == null or night_index < 0 or night_index >= playlist.nights.size():
		return null
	return playlist.nights[night_index]
