@tool
extends HBoxContainer

var dock: Control
var spawner_id: StringName = &""
var wave_index: int = -1
var wave_count: int = 0
var wave: SpawnWave

var _monster_type: OptionButton
var _count: SpinBox
var _interval: SpinBox
var _wait_event: LineEdit
var _emit_event: LineEdit
var _emit_delay: SpinBox


func setup(p_dock: Control, p_spawner_id: StringName, p_wave_index: int, p_wave_count: int, p_wave: SpawnWave, monster_types: Array[StringName], event_names: Array[StringName]) -> void:
	dock = p_dock
	spawner_id = p_spawner_id
	wave_index = p_wave_index
	wave_count = p_wave_count
	wave = p_wave
	custom_minimum_size = Vector2(0.0, 30.0)
	_build(monster_types, event_names)


func _build(monster_types: Array[StringName], event_names: Array[StringName]) -> void:
	var move_box: HBoxContainer = HBoxContainer.new()
	move_box.custom_minimum_size = Vector2(76.0, 0.0)
	add_child(move_box)

	var up_button: Button = Button.new()
	up_button.text = "Up"
	up_button.tooltip_text = "Move this wave above its previous neighbor."
	up_button.disabled = wave_index <= 0
	up_button.pressed.connect(_on_move_up_pressed)
	move_box.add_child(up_button)

	var down_button: Button = Button.new()
	down_button.text = "Down"
	down_button.tooltip_text = "Move this wave below its next neighbor."
	down_button.disabled = wave_index >= wave_count - 1
	down_button.pressed.connect(_on_move_down_pressed)
	move_box.add_child(down_button)

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

	_emit_delay = SpinBox.new()
	_emit_delay.min_value = 0.0
	_emit_delay.max_value = 3600.0
	_emit_delay.step = 0.1
	_emit_delay.value = wave.emit_delay_seconds
	_emit_delay.suffix = "s"
	_emit_delay.custom_minimum_size = Vector2(86.0, 0.0)
	_emit_delay.tooltip_text = "Seconds to wait after the wave finishes before emitting its Emit Event."
	_emit_delay.value_changed.connect(_on_emit_delay_changed)
	add_child(_emit_delay)

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


func _on_emit_delay_changed(value: float) -> void:
	if wave == null:
		return
	wave.emit_delay_seconds = value
	_mark_dirty()


func _on_delete_pressed() -> void:
	if dock != null and dock.has_method("delete_wave"):
		dock.call("delete_wave", spawner_id, wave_index)


func _on_move_up_pressed() -> void:
	if dock != null and dock.has_method("move_wave"):
		dock.call("move_wave", spawner_id, wave_index, wave_index - 1)


func _on_move_down_pressed() -> void:
	if dock != null and dock.has_method("move_wave"):
		dock.call("move_wave", spawner_id, wave_index, wave_index + 1)


func _mark_dirty() -> void:
	if dock != null and dock.has_method("mark_dirty"):
		dock.call("mark_dirty")
