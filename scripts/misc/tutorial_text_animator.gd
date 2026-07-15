extends RefCounted
class_name TutorialTextAnimator
## Animated reveal of the tutorial hint label.
##
## Owns the identity of the message on screen, the typewriter progress and the "fresh" window
## that follows it. A message is presented in three stages:
##   1. typing: characters appear one by one, each bouncing into place
##   2. fresh: the whole message keeps its scrolling rainbow for FRESH_SECONDS
##   3. static: the plain message is written back once, white and still
##
## While a message is fresh the label holds a single [tuto_fx] block (TutorialRichTextEffect)
## and this animator only advances visible_characters and the effect clock. Writing the plain
## text back at the end drops that block, which is what stops the label processing the effect
## every frame: a settled hint costs what it always did.
##
## tutorial.gd re-requests the message it wants every frame. show_message() ignores a request
## for the message already presented, so an animation only ever starts on a real change.

const TYPE_SPEED: float = 34.0  # characters per second
## How long the rainbow keeps running after the last character lands.
const FRESH_SECONDS: float = 2.0

var _label: RichTextLabel
var _effect: TutorialRichTextEffect
var _message_id: String = ""
var _message_text: String = ""
var _elapsed: float = 0.0
var _typing_duration: float = 0.0
var _active: bool = false


func setup(label: RichTextLabel) -> void:
	_label = label
	if _label == null:
		return
	_effect = TutorialRichTextEffect.new()
	_effect.configure(_label.get_theme_font_size(&"normal_font_size"), TYPE_SPEED)
	_label.install_effect(_effect)
	# Trim after shaping: the message is shaped once and the typewriter only skips glyphs at
	# draw time. Otherwise every new character would reshape the paragraph and a centred hint
	# would slide sideways as it types.
	_label.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	# Landing characters are drawn oversized and raised, i.e. outside the text rect the label
	# clips to by default.
	_label.clip_contents = false
	# From here on the animator owns the label's text: drop whatever the scene authored, so
	# "no message presented" and "label is blank" mean the same thing.
	_label.text = ""


## Starts the animated reveal of `message_text`, identified by `message_id`. Returns false and
## changes nothing when that exact message is already presented, which is the common case:
## most tutorial paths ask for their message every frame.
func show_message(message_id: String, message_text: String) -> bool:
	if _label == null:
		return false
	if message_id == _message_id and message_text == _message_text:
		return false
	if message_text == "":
		clear_message()
		return false
	_message_id = message_id
	_message_text = message_text
	_label.text = "[%s]%s[/%s]" % [
		TutorialRichTextEffect.BBCODE_TAG, message_text, TutorialRichTextEffect.BBCODE_TAG
	]
	# Character count of the parsed text, so the typewriter stays right even if a translation
	# ever carries BBCode of its own.
	_typing_duration = float(_label.get_total_character_count()) / TYPE_SPEED
	_elapsed = 0.0
	_active = true
	_effect.set_time(0.0)
	_label.visible_characters = 0
	return true


## Cancels any running animation and blanks the label. The message identity is dropped, so the
## same message shown again later animates from scratch.
func clear_message() -> void:
	# Tutorial branches that hide the label ask for this every frame, and blanking a
	# RichTextLabel is not free: assigning an empty text rebuilds its content every time.
	if not _active and _message_id == "" and _message_text == "":
		return
	_message_id = ""
	_message_text = ""
	_elapsed = 0.0
	_typing_duration = 0.0
	_active = false
	if _label == null:
		return
	_label.visible_characters = -1
	_label.text = ""


func update(delta: float) -> void:
	if not _active or _label == null or delta <= 0.0:
		return
	_elapsed += delta
	_effect.set_time(_elapsed)
	if _elapsed < _typing_duration:
		var revealed: int = int(_elapsed * TYPE_SPEED)
		if _label.visible_characters != revealed:
			_label.visible_characters = revealed
		return
	if _label.visible_characters != -1:
		_label.visible_characters = -1
	if _elapsed >= _typing_duration + FRESH_SECONDS:
		_finish()


## True while the message is typing or still inside its rainbow window.
func is_fresh() -> bool:
	return _active


## How long the presented message needs to stay on screen to play in full.
func get_minimum_visible_duration() -> float:
	return _typing_duration + FRESH_SECONDS


## Fresh window over: write the plain message back once, dropping the effect from the content.
func _finish() -> void:
	_active = false
	_label.text = _message_text
