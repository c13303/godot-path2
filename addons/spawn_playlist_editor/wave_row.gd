@tool
extends HBoxContainer

var dock: Control
var spawner_id: StringName = &""
var wave_index: int = -1
var wave: SpawnWave

var _monster_type: OptionButton
var _count: SpinBox
var _interval: SpinBox
var _wait_event: LineEdit
var _emit_event: LineEdit


func setup(p_dock: Control, p_spawner_id: StringName, p_wave_index: int, p_wave: SpawnWave, monster_types: Array[StringName], event_names: Array[StringName]) -> void:
	dock = p_dock
	spawner_id = p_spawner_id
	wave_index = p_wave_index
	wave = p_wave
	custom_minimum_size = Vector2(0.0, 30.0)
	_build(monster_types, event_names)


func _build(monster_types: Array[StringName], event_names: Array[StringName]) -> void:
	var drag_label: Label = Label.new()
	drag_label.text = "drag"
	drag_label.tooltip_text = "Drag to reorder this wave."
	drag_label.custom_minimum_size = Vector2(38.0, 0.0)
	add_child(drag_label)

	var number: Label = Label.new()
	number.text = "%d" % (wave_index + 1)
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	number.custom_minimum_size = Vector2(24.0, 0.0)
	add_child(number)

	_monster_type = OptionButton.new()
	_monster_type.custom_minimum_size = Vector2(90.0, 0.0)
	var selected_index: int = 0
	var index: int = 0
	for monster_type: StringName in monster_types:
		_monster_type.add_item(String(monster_type))
		if monster_type == wave.monster_type:
			selected_index = index
		index += 1
	_monster_type.select(selected_index)
	_monster_type.item_selected.connect(_on_monster_type_selected)
	add_child(_monster_type)

	_count = SpinBox.new()
	_count.min_value = 0.0
	_count.max_value = 100000.0
	_count.step = 1.0
	_count.value = float(wave.monster_count)
	_count.custom_minimum_size = Vector2(74.0, 0.0)
	_count.tooltip_text = "Monster count. Zero can be used for event-only waves."
	_count.value_changed.connect(_on_count_changed)
	add_child(_count)

	_interval = SpinBox.new()
	_interval.min_value = 0.0
	_interval.max_value = 3600.0
	_interval.step = 0.1
	_interval.value = wave.spawn_interval_seconds
	_interval.custom_minimum_size = Vector2(86.0, 0.0)
	_interval.tooltip_text = "Seconds between successful spawns."
	_interval.value_changed.connect(_on_interval_changed)
	add_child(_interval)

	_wait_event = LineEdit.new()
	_wait_event.text = String(wave.wait_for_event)
	_wait_event.placeholder_text = _event_placeholder("wait event", event_names)
	_wait_event.custom_minimum_size = Vector2(110.0, 0.0)
	_wait_event.text_changed.connect(_on_wait_event_changed)
	add_child(_wait_event)

	_emit_event = LineEdit.new()
	_emit_event.text = String(wave.emit_event)
	_emit_event.placeholder_text = _event_placeholder("emit event", event_names)
	_emit_event.custom_minimum_size = Vector2(110.0, 0.0)
	_emit_event.text_changed.connect(_on_emit_event_changed)
	add_child(_emit_event)

	var delete_button: Button = Button.new()
	delete_button.text = "Delete"
	delete_button.pressed.connect(_on_delete_pressed)
	add_child(delete_button)


func _event_placeholder(prefix: String, event_names: Array[StringName]) -> String:
	if event_names.is_empty():
		return prefix
	var names: PackedStringArray = PackedStringArray()
	for event_name: StringName in event_names:
		names.append(String(event_name))
	return "%s: %s" % [prefix, ", ".join(names)]


func _get_drag_data(_at_position: Vector2) -> Variant:
	var preview: Label = Label.new()
	preview.text = "Wave %d" % (wave_index + 1)
	set_drag_preview(preview)
	return {
		"type": &"spawn_wave",
		"spawner_id": spawner_id,
		"wave_index": wave_index,
	}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not data is Dictionary:
		return false
	var drag_data: Dictionary = data as Dictionary
	var dragged_spawner_id: StringName = StringName(str(drag_data.get("spawner_id", "")))
	return drag_data.get("type", &"") == &"spawn_wave" and dragged_spawner_id == spawner_id


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if dock == null or not data is Dictionary:
		return
	var drag_data: Dictionary = data as Dictionary
	var from_index: int = int(drag_data.get("wave_index", -1))
	if dock.has_method("move_wave"):
		dock.call("move_wave", spawner_id, from_index, wave_index)


func _on_monster_type_selected(index: int) -> void:
	if wave == null:
		return
	wave.monster_type = StringName(_monster_type.get_item_text(index))
	_mark_dirty()


func _on_count_changed(value: float) -> void:
	if wave == null:
		return
	wave.monster_count = int(value)
	_mark_dirty()


func _on_interval_changed(value: float) -> void:
	if wave == null:
		return
	wave.spawn_interval_seconds = value
	_mark_dirty()


func _on_wait_event_changed(value: String) -> void:
	if wave == null:
		return
	wave.wait_for_event = StringName(value.strip_edges())
	_mark_dirty()


func _on_emit_event_changed(value: String) -> void:
	if wave == null:
		return
	wave.emit_event = StringName(value.strip_edges())
	_mark_dirty()


func _on_delete_pressed() -> void:
	if dock != null and dock.has_method("delete_wave"):
		dock.call("delete_wave", spawner_id, wave_index)


func _mark_dirty() -> void:
	if dock != null and dock.has_method("mark_dirty"):
		dock.call("mark_dirty")
