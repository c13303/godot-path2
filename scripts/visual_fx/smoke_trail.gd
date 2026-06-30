extends Node2D
class_name SmokeTrail

## Recyclable pool of one-shot smoke puffs used for the player's running trail.
## Pre-instances [member smoke_scene] on ready and fires them round-robin via
## [method emit_at], so gameplay never pays an instantiation cost mid-dash.

@export var smoke_scene: PackedScene
@export_range(1, 64, 1) var pool_size: int = 16

var _puffs: Array[Node2D] = []
var _emitters: Array[CPUParticles2D] = []
var _next: int = 0

func _ready() -> void:
	if smoke_scene == null:
		push_warning("SmokeTrail: smoke_scene is not assigned; no trail will spawn.")
		return
	for i in pool_size:
		var puff: Node2D = smoke_scene.instantiate() as Node2D
		if puff == null:
			continue
		add_child(puff)
		puff.visible = false
		_puffs.append(puff)
		_emitters.append(_find_emitter(puff))

## Returns the CPUParticles2D driving the puff, whether it is the root or a child.
func _find_emitter(puff: Node2D) -> CPUParticles2D:
	if puff is CPUParticles2D:
		return puff as CPUParticles2D
	for child in puff.get_children():
		if child is CPUParticles2D:
			return child as CPUParticles2D
	return null

## Places the next pooled puff at [param world_position] and fires a one-shot
## burst. No-op until the pool has been built.
func emit_at(world_position: Vector2) -> void:
	if _puffs.is_empty():
		return
	var puff: Node2D = _puffs[_next]
	var emitter: CPUParticles2D = _emitters[_next]
	_next = (_next + 1) % _puffs.size()
	puff.global_position = world_position
	puff.visible = true
	if emitter:
		emitter.restart()
