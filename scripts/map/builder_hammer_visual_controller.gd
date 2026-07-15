extends RefCounted
class_name BuilderHammerVisualController

# Builder-only presentation of the hammer the Builder already holds through the generic
# held-object API. It owns the swing shape and its Tweens; HouseBuilderWorkController owns
# when a Builder strikes, and BuilderController resolves which agent node to animate.
#
# marto.png rests head-up / handle-down on a centered pivot, so a positive rotation tips the
# head toward the Builder's right. The angles below are authored for a house on the right and
# mirrored for one on the left.

const SWING_DURATION_SECONDS: float = 0.32
# Kept in degrees and converted at the use site: GDScript const initializers only fold
# preload(), not utility calls like deg_to_rad().
const WINDUP_ANGLE_DEGREES: float = -25.0
const IMPACT_ANGLE_DEGREES: float = 50.0
const STRIKE_DISTANCE_PIXELS: float = 8.0
# The wind-up pulls the hammer slightly away from the house before it drives in.
const WINDUP_PULL_BACK_RATIO: float = 0.25
# Swing timeline: raise to WINDUP_END_PROGRESS, drive in to IMPACT_END_PROGRESS, settle back.
const WINDUP_END_PROGRESS: float = 0.4
const IMPACT_END_PROGRESS: float = 0.6

var _tween_by_builder_id: Dictionary = {}  # int -> Tween


# One strike: rest -> wind up -> drive toward target_global -> rest. A new strike replaces an
# unfinished one, and each Tween is created from its own Builder's agent node, so one Builder
# can never animate another and a freed Builder takes its Tween with it.
func play_swing(builder_id: int, agent: Node2D, target_global: Vector2) -> void:
	stop_swing(builder_id, agent)
	if not is_instance_valid(agent) or not agent.has_method("set_held_object_animation_transform"):
		return
	var direction: Vector2 = _strike_direction(agent, target_global)
	var tween: Tween = agent.create_tween()
	tween.tween_method(
		Callable(self, "_apply_swing_pose").bind(agent, direction),
		0.0,
		1.0,
		SWING_DURATION_SECONDS
	)
	tween.tween_callback(Callable(self, "_apply_rest_pose").bind(agent))
	_tween_by_builder_id[builder_id] = tween


# Ends any strike and puts the hammer back on its normal held pose. The hammer stays visible.
func stop_swing(builder_id: int, agent: Node2D) -> void:
	forget_builder(builder_id)
	_apply_rest_pose(agent)


# Drops Tween state for a Builder whose agent node is already gone or being removed.
func forget_builder(builder_id: int) -> void:
	var tween: Tween = _tween_by_builder_id.get(builder_id, null) as Tween
	if tween != null and tween.is_valid():
		tween.kill()
	_tween_by_builder_id.erase(builder_id)


func clear_all() -> void:
	for raw_tween: Variant in _tween_by_builder_id.values():
		var tween: Tween = raw_tween as Tween
		if tween != null and tween.is_valid():
			tween.kill()
	_tween_by_builder_id.clear()


# to_local() already yields the agent-origin -> house vector, so its direction is the strike
# direction in the held sprite's own parent space.
func _strike_direction(agent: Node2D, target_global: Vector2) -> Vector2:
	if not target_global.is_finite():
		return Vector2.ZERO
	var to_target: Vector2 = agent.to_local(target_global)
	if to_target.length_squared() <= 0.0001:
		return Vector2.ZERO
	return to_target.normalized()


# The pose is derived from progress alone rather than accumulated, so a strike cannot drift:
# progress 1.0 is exactly the rest pose whatever the frame timing was.
func _apply_swing_pose(progress: float, agent: Node2D, direction: Vector2) -> void:
	if not is_instance_valid(agent):
		return
	var swing_progress: float = clampf(progress, 0.0, 1.0)
	var pull_back: float = -STRIKE_DISTANCE_PIXELS * WINDUP_PULL_BACK_RATIO
	var angle_degrees: float = 0.0
	var reach: float = 0.0
	if swing_progress < WINDUP_END_PROGRESS:
		var windup_progress: float = swing_progress / WINDUP_END_PROGRESS
		angle_degrees = lerpf(0.0, WINDUP_ANGLE_DEGREES, windup_progress)
		reach = lerpf(0.0, pull_back, windup_progress)
	elif swing_progress < IMPACT_END_PROGRESS:
		var impact_progress: float = (swing_progress - WINDUP_END_PROGRESS) / (IMPACT_END_PROGRESS - WINDUP_END_PROGRESS)
		angle_degrees = lerpf(WINDUP_ANGLE_DEGREES, IMPACT_ANGLE_DEGREES, impact_progress)
		reach = lerpf(pull_back, STRIKE_DISTANCE_PIXELS, impact_progress)
	else:
		var return_progress: float = (swing_progress - IMPACT_END_PROGRESS) / (1.0 - IMPACT_END_PROGRESS)
		angle_degrees = lerpf(IMPACT_ANGLE_DEGREES, 0.0, return_progress)
		reach = lerpf(STRIKE_DISTANCE_PIXELS, 0.0, return_progress)
	var angle_sign: float = -1.0 if direction.x < 0.0 else 1.0
	agent.call("set_held_object_animation_transform", direction * reach, deg_to_rad(angle_degrees * angle_sign))


func _apply_rest_pose(agent: Node2D) -> void:
	if not is_instance_valid(agent) or not agent.has_method("clear_held_object_animation_transform"):
		return
	agent.call("clear_held_object_animation_transform")
