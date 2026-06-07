extends Node
## Global game state singleton (autoloaded as "GameState").
## Holds shared game data such as the current day/night mode.

## Emitted whenever the day/night mode changes. `is_night` is the new value.
signal mode_changed(is_night: bool)

## True while night is active. The game starts in day mode.
var is_night: bool = false


## Switch to night: monsters are allowed to spawn.
func start_night() -> void:
	set_night(true)


## Switch to day: monster spawning is suppressed.
func start_day() -> void:
	set_night(false)


## Toggle between day and night.
func toggle() -> void:
	set_night(not is_night)


func set_night(value: bool) -> void:
	if is_night == value:
		return
	is_night = value
	mode_changed.emit(is_night)
