extends Node

## Ensures the persistent music owner is playing when mainRun is entered
## directly, without a splash screen first.

@export var disable_music: bool = false


func _ready() -> void:
	if disable_music:
		Sfx.stop_music()
	else:
		Sfx.start_music()
