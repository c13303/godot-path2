extends RichTextEffect
class_name TutorialRichTextEffect
## Per-glyph look of a freshly revealed tutorial hint.
##
## TutorialTextAnimator installs this on the tutorial RichTextLabel and wraps the message in
## a [tuto_fx] block while it is fresh, driving `set_time()` from its own clock. Everything
## here is derived from that clock and the glyph index, so a whole animated message costs one
## label, no per-character node, tween or string rebuild.
##
## Two treatments run together:
##   * a bright rainbow scrolling horizontally through the whole message
##   * a landing bounce played once per character, as the typewriter reveals it
##
## Glyph transform: the engine hands us a transform whose origin is the glyph pen position
## and pivots our basis around that point, so scaling grows the glyph up from its baseline.
## That vertical anchor is what we want (letters stay on their baseline instead of drifting
## into the line above), so we only compensate horizontally: a scaled glyph is pulled back by
## half its extra advance and stays centred over the space it occupies at rest.
##
## Shadow: the label draws a shadow pass through here too. The engine overwrites the colour
## of that pass with the shadow colour afterwards, so the shadow keeps its own look while
## still following the transform of the glyph it belongs to.

## BBCode tag wrapping an animated message. `bbcode` below is what RichTextLabel reads to
## match the tag, and must stay a plain property for the engine to find it.
const BBCODE_TAG: String = "tuto_fx"
var bbcode: String = BBCODE_TAG

## Landing keyframes: [age in seconds, scale, vertical offset in pixels]. The first entry is
## how a character pops in, the last must rest at the normal scale and baseline, on
## LANDING_DURATION. Values in between overshoot small, then settle.
const LANDING_KEYS: Array[Array] = [
	[0.0, 1.55, -7.0],
	[0.08, 0.92, 2.0],
	[0.15, 1.06, -1.0],
	[0.22, 1.0, 0.0],
]
const LANDING_DURATION: float = 0.22

const RAINBOW_HUE_PER_SECOND: float = 0.55
const RAINBOW_HUE_PER_CHARACTER: float = 0.075
const RAINBOW_SATURATION: float = 0.9
const RAINBOW_VALUE: float = 1.0

## Whitespace glyphs, which must not bounce. Deliberately not GRAPHEME_IS_BREAK_SOFT: that
## marks every legal break point, including inked characters such as a hyphen, and a space
## already carries GRAPHEME_IS_SPACE.
const BLANK_GLYPH_FLAGS: int = (
	TextServer.GRAPHEME_IS_SPACE
	| TextServer.GRAPHEME_IS_BREAK_HARD
	| TextServer.GRAPHEME_IS_TAB
)

var _time: float = 0.0
var _type_speed: float = 1.0
var _font_size: int = 16


## Called once by the animator, with the font size the label actually renders at.
func configure(font_size: int, type_speed: float) -> void:
	_font_size = font_size
	_type_speed = maxf(0.001, type_speed)


## Animator clock, in seconds since the current message started typing. Driving both this and
## visible_characters from that single clock is what keeps a character's bounce starting on
## the exact frame the label first draws it.
func set_time(time: float) -> void:
	_time = time


func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	var index: int = char_fx.relative_index
	# Characters past the typewriter cursor still reach us; the label trims them at draw
	# time, so there is nothing to compute for them yet.
	var age: float = _time - float(index + 1) / _type_speed
	if age < 0.0:
		return true
	var hue: float = fposmod(
		_time * RAINBOW_HUE_PER_SECOND + float(index) * RAINBOW_HUE_PER_CHARACTER, 1.0
	)
	char_fx.color = Color.from_hsv(hue, RAINBOW_SATURATION, RAINBOW_VALUE, char_fx.color.a)
	if age >= LANDING_DURATION or (char_fx.glyph_flags & BLANK_GLYPH_FLAGS) != 0:
		return true
	var landing: Vector2 = _landing_state(age)
	var glyph_scale: float = landing.x
	var advance: float = _glyph_advance(char_fx.font, char_fx.glyph_index)
	var transform: Transform2D = char_fx.transform
	# The origin moves the glyph by exactly this many screen pixels, and carries the scaling
	# pivot with it. scaled_local() then scales around that pivot, leaving the origin alone.
	transform.origin += Vector2(-(glyph_scale - 1.0) * advance * 0.5, landing.y)
	char_fx.transform = transform.scaled_local(Vector2(glyph_scale, glyph_scale))
	return true


## Scale (x) and vertical offset in pixels (y) for a character revealed `age` seconds ago,
## smoothly interpolated between LANDING_KEYS. Only called inside the landing window.
func _landing_state(age: float) -> Vector2:
	var last_index: int = LANDING_KEYS.size() - 1
	for i: int in range(last_index):
		var from_key: Array = LANDING_KEYS[i]
		var to_key: Array = LANDING_KEYS[i + 1]
		if age > float(to_key[0]) and i < last_index - 1:
			continue
		var weight: float = smoothstep(float(from_key[0]), float(to_key[0]), age)
		return Vector2(
			lerpf(float(from_key[1]), float(to_key[1]), weight),
			lerpf(float(from_key[2]), float(to_key[2]), weight)
		)
	return Vector2(1.0, 0.0)


## Resting horizontal advance of one glyph. Only the few characters inside their landing
## window ask for this, so it stays a handful of lookups per frame. Glyphs the label draws
## without a font of their own have no advance to centre on.
func _glyph_advance(font: RID, glyph_index: int) -> float:
	if not font.is_valid():
		return 0.0
	var text_server: TextServer = TextServerManager.get_primary_interface()
	return text_server.font_get_glyph_advance(font, _font_size, glyph_index).x
