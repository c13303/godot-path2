extends RefCounted
class_name BuildingPreparationWorkGate

# Single shared generation for budgeted topology/route work. This intentionally
# does not know which controller owns the work beyond a diagnostic purpose.

var _generation: int = 0
var _purpose: StringName = &""


func begin_work(purpose: StringName) -> int:
	assert(purpose != &"")
	_generation += 1
	_purpose = purpose
	return _generation


func is_current(token: int) -> bool:
	return token > 0 and token == _generation and _purpose != &""


func finish_work(token: int) -> bool:
	if not is_current(token):
		return false
	_purpose = &""
	return true


func cancel_if_current(token: int) -> bool:
	if not is_current(token):
		return false
	_generation += 1
	_purpose = &""
	return true


func cancel_current_work() -> int:
	_generation += 1
	_purpose = &""
	return _generation


func current_purpose() -> StringName:
	return _purpose


func current_token() -> int:
	return _generation
