extends Node

## Ensures the persistent music owner is playing when mainRun is entered
## directly, without a splash screen first.


func _ready() -> void:
	Sfx.start_music()
