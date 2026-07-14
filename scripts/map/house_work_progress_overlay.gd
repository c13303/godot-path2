extends Node2D
class_name HouseWorkProgressOverlay

var _indicators_by_house_id: Dictionary = {}  # StringName -> HouseWorkProgressIndicator


func show_progress(house_id: StringName, sprite: Sprite2D, progress: float) -> void:
	if sprite == null or not is_instance_valid(sprite):
		remove_progress(house_id)
		return
	var indicator: HouseWorkProgressIndicator = _indicators_by_house_id.get(house_id, null) as HouseWorkProgressIndicator
	if indicator == null or not is_instance_valid(indicator) or indicator.get_parent() != sprite:
		remove_progress(house_id)
		indicator = HouseWorkProgressIndicator.new()
		indicator.name = "HouseWorkProgressIndicator"
		sprite.add_child(indicator)
		indicator.setup(sprite)
		_indicators_by_house_id[house_id] = indicator
	indicator.set_progress(progress)


func hide_progress(house_id: StringName) -> void:
	var indicator: HouseWorkProgressIndicator = _indicators_by_house_id.get(house_id, null) as HouseWorkProgressIndicator
	if indicator != null and is_instance_valid(indicator):
		indicator.visible = false


func remove_progress(house_id: StringName) -> void:
	var indicator: HouseWorkProgressIndicator = _indicators_by_house_id.get(house_id, null) as HouseWorkProgressIndicator
	_indicators_by_house_id.erase(house_id)
	if indicator != null and is_instance_valid(indicator):
		indicator.queue_free()


func clear_all() -> void:
	for raw_house_id: Variant in _indicators_by_house_id.keys():
		remove_progress(StringName(str(raw_house_id)))
