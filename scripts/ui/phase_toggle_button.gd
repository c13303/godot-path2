extends Button
## Phase-advance hint button shown to the left of the planificator.
##
## It owns no phase rules. The confirm input (space / pad X) stays authoritative and the
## tutorial hint owns which phase advance that input is bound to this frame; this button
## only mirrors that availability as a green/gray frame and offers a click as a second way
## to trigger the same action. If the tutorial says nothing is available, the button is grey
## and inert even though it is still shown.
##
## Everything visual is authored in the scene: the four phase icons, both frame styles, and
## the animation tuning are exported so they can be tweaked in the Inspector without
## touching this file.

## Frame styles are pushed into every button state slot, so the frame is never dropped while
## hovering, pressing or focusing. Both styles must be authored with identical border widths
## and content margins, otherwise the button would resize when availability flips.
const FRAME_STYLE_SLOTS: Array[String] = ["normal", "hover", "pressed", "focus", "disabled"]

@export var tutorial: Node
@export var night_icon: Texture2D
@export var dawn_icon: Texture2D
@export var morning_icon: Texture2D
@export var afternoon_icon: Texture2D
@export var available_style: StyleBoxFlat
@export var unavailable_style: StyleBoxFlat
## One bounce cycle: scale up then back down.
@export var bounce_scale: float = 1.18
@export var bounce_seconds: float = 0.28
## How long the become-available alert bounces and flashes before settling.
@export var alert_seconds: float = 1.0
## Overbright modulate peak of the alert flash.
@export var flash_color: Color = Color(2.6, 2.6, 2.6)
@export var flash_seconds: float = 0.16

var _available: bool = false
var _alert_remaining: float = 0.0
var _bounce_tween: Tween
var _flash_tween: Tween
var _applied_style: StyleBoxFlat
var _applied_icon: Texture2D
# Availability is only interesting once it changes. Without this the button would fire its
# alert on the first processed frame if the confirm input happened to be live already
# (a loaded save dropped straight into an afternoon that can already end).
var _availability_known: bool = false


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	pressed.connect(_on_pressed)
	_refresh()


func _process(delta: float) -> void:
	if _alert_remaining > 0.0:
		_alert_remaining = maxf(0.0, _alert_remaining - delta)
	_refresh()


func _refresh() -> void:
	var available: bool = _resolve_available()
	if available and not _available and _availability_known:
		_alert_remaining = alert_seconds
	_available = available
	_availability_known = true
	_apply_icon()
	_apply_frame()
	_apply_animation()


## True while the confirm input would advance the phase. Delegating keeps the rule in one
## place: the tutorial walks the branch tree that decides what the input is bound to, so the
## button can never disagree with the spacebar.
func _resolve_available() -> bool:
	if tutorial == null or not tutorial.has_method("available_phase_action"):
		return false
	return StringName(tutorial.call("available_phase_action")) != &""


func _apply_icon() -> void:
	var next: Texture2D = _phase_icon()
	if next == _applied_icon:
		return
	_applied_icon = next
	icon = next


func _phase_icon() -> Texture2D:
	match GameState.gameplay_phase:
		GameState.GameplayPhase.NIGHT:
			return night_icon
		GameState.GameplayPhase.DAWN:
			return dawn_icon
		GameState.GameplayPhase.MORNING:
			return morning_icon
	return afternoon_icon


func _apply_frame() -> void:
	var style: StyleBoxFlat = available_style if _available else unavailable_style
	if style == null or style == _applied_style:
		return
	_applied_style = style
	for slot: String in FRAME_STYLE_SLOTS:
		add_theme_stylebox_override(slot, style)


func _apply_animation() -> void:
	var alerting: bool = _alert_remaining > 0.0
	# Hovering an unavailable button must stay dead quiet: the bounce means "you can press
	# this now", so it may only answer the mouse while the action is actually offered.
	_set_bouncing(alerting or (_available and is_hovered()))
	_set_flashing(alerting)


func _set_bouncing(active: bool) -> void:
	if active == (_bounce_tween != null and _bounce_tween.is_valid()):
		return
	if not active:
		if _bounce_tween != null:
			_bounce_tween.kill()
			_bounce_tween = null
		scale = Vector2.ONE
		return
	pivot_offset = size * 0.5
	_bounce_tween = create_tween().set_loops()
	_bounce_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bounce_tween.tween_property(self, "scale", Vector2(bounce_scale, bounce_scale), bounce_seconds * 0.5)
	_bounce_tween.tween_property(self, "scale", Vector2.ONE, bounce_seconds * 0.5)


func _set_flashing(active: bool) -> void:
	if active == (_flash_tween != null and _flash_tween.is_valid()):
		return
	if not active:
		if _flash_tween != null:
			_flash_tween.kill()
			_flash_tween = null
		modulate = Color.WHITE
		return
	_flash_tween = create_tween().set_loops()
	_flash_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_flash_tween.tween_property(self, "modulate", flash_color, flash_seconds)
	_flash_tween.tween_property(self, "modulate", Color.WHITE, flash_seconds)


func _on_pressed() -> void:
	if not _available or tutorial == null or not tutorial.has_method("trigger_phase_action"):
		return
	tutorial.call("trigger_phase_action")
