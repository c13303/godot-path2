Implement a lightweight animated presentation for the main tutorial text.

Read `AGENTS.md` first and follow it strictly. Do not run Godot, tests, builds, or exports.

## Objective

Whenever the tutorial message genuinely changes:

1. Reveal the new text with a typewriter effect.
2. Each newly revealed character appears oversized and slightly raised, then quickly bounces into its normal size and baseline position.
3. During the complete typewriter animation, and for exactly 2 seconds after the final character appears, display a bright rainbow gradient scrolling horizontally through the text.
4. After that fresh period, the text becomes the current normal static white tutorial text.

The purpose is to make tutorial changes immediately noticeable instead of silently replacing one white message with another.

## Current implementation

The tutorial label is:

```text
mainRun.tscn
GameUI/top anchor/tutorial
```

Its main controller is:

```text
scripts/misc/tutorial.gd
```

`tutorial.gd` currently assigns `text` from several separate paths:

* normal contextual tutorial keys
* `_show_key_immediately()`
* alerts
* hold-action prompts
* locale refreshes
* clear/hide branches

Some of these methods run every frame. Therefore, directly starting an animation from every `text = ...` assignment would constantly restart it.

The existing `CHANGE_DELAY` behavior should remain unchanged: delayed contextual messages still wait before beginning their animated reveal.

## Architecture

`scripts/misc/tutorial.gd` is already over 1,100 lines. Do not implement the animation internals directly inside it.

Create two focused files:

```text
scripts/misc/tutorial_text_animator.gd
scripts/misc/tutorial_rich_text_effect.gd
```

Suggested ownership:

### `tutorial_text_animator.gd`

Owns:

* current logical message identity
* current plain translated text
* typewriter progress
* visible-character count
* fresh/rainbow lifetime
* starting, updating, finishing and clearing presentation
* replacing the animated BBCode content with plain static text when animation finishes

Expose a small API similar to:

```gdscript
setup(label: RichTextLabel) -> void
show_message(message_id: String, message_text: String) -> bool
clear_message() -> void
update(delta: float) -> void
is_fresh() -> bool
get_minimum_visible_duration() -> float
```

`show_message()` must do nothing and return `false` when the same logical message and same text are already displayed. This prevents `_show_key_immediately()` and other per-frame paths from restarting the animation.

A message that was fully cleared or hidden should animate again if it is later shown again.

### `tutorial_rich_text_effect.gd`

Implement one `RichTextEffect` for the temporary per-character visual treatment.

Do not create one `Label`, `Control`, `Tween`, or node per character.

Use the existing single `RichTextLabel`, `visible_characters`, and one custom RichText effect. Character animation must be calculated from the character index and the effect’s elapsed time.

Keep this effect specific to tutorial presentation. Do not build a global text-animation framework.

## Presentation tuning

Use these initial values as production defaults:

```text
Typewriter speed:             34 characters/second
Character landing duration:   0.22 seconds
Fresh rainbow after typing:   2.0 seconds
Initial character scale:      1.55
Initial vertical offset:      -7 px
Rainbow temporal speed:       approximately 0.55 hue cycles/second
Rainbow character spacing:    approximately 0.075 hue per character
```

Character landing should feel like:

```text
0.00 s: scale 1.55, Y offset -7 px
0.08 s: scale around 0.92, Y offset +2 px
0.15 s: scale around 1.06, Y offset -1 px
0.22 s: scale 1.00, normal baseline
```

Interpolate smoothly between those phases. The glyph should appear to bounce into place, not shake continuously.

Compensate the glyph transform so scaling remains visually centered and does not make the baseline jump sideways.

Whitespace should not visibly bounce. Accents, punctuation, line breaks and translated French/English strings must remain correct.

The rainbow should:

* travel continuously across the complete visible text
* continue moving while letters are being typed
* remain active for 2 seconds after the last letter appears
* use bright saturation and value
* retain the existing readable shadow
* become completely white and static when freshness ends

Once the fresh period ends, restore the plain text once and remove the custom effect from the displayed content. Do not keep processing an inactive custom effect forever.

## Integration into `tutorial.gd`

Instantiate and configure the animator in `_ready()`.

Update it once per frame using the existing `_process(delta)` path.

Centralize visible message changes through one small tutorial method, for example:

```gdscript
func _present_tutorial_message(message_id: String, message_text: String) -> void:
```

Replace the relevant direct `text = ...` assignments with this method.

Use stable message identities, for example:

```text
tutorial:<translation key>
alert:<translation key>:<count>
hold:<translation key>
```

Requirements:

* Normal contextual key changes animate.
* `_show_key_immediately()` messages animate, despite bypassing `CHANGE_DELAY`.
* Alerts animate.
* Hold-action prompt changes animate.
* The same message being requested every frame does not restart.
* A changed alert count may animate because the visible content changed.
* Clearing/hiding the tutorial cancels and resets the animation.
* Locale changes must update the visible translated text safely without leaving stale BBCode or animation state.
* Tutorial arrows must retain their current timing and behavior.
* Hold progression, alert timing, onboarding priority and tutorial-selection logic must not change.

During the rainbow period, ensure the label’s global `modulate` does not tint the rainbow into a single color.

For normal tutorial messages, it remains white.

For alerts:

* show the full rainbow correctly during freshness
* resume the existing red alert modulation afterward when the alert is still active

A transient alert must remain visible long enough to complete its typewriter and the full 2-second fresh period. Its minimum lifetime should therefore be:

```text
max(existing alert duration, typing duration + 2 seconds)
```

Persistent alerts remain unaffected after their fresh animation finishes.

## Performance constraints

Do not:

* create per-character nodes
* create per-character tweens
* rebuild the displayed string every frame
* repeatedly parse BBCode every frame
* restart an animation merely because `_refresh()` requested the same message again
* add animation logic to unrelated tutorial selection branches

Allowed ongoing work while active:

* update `visible_characters`
* update a small amount of animator state
* let the single custom RichText effect calculate character transforms/colors

After the fresh period ends, presentation should return to approximately the same runtime cost as the current static tutorial label.

## Preserve existing behavior

Do not change:

* tutorial priority rules
* translation keys or text
* tutorial arrows
* world arrows
* the 0.5-second contextual `CHANGE_DELAY`
* alert semantics beyond guaranteeing the requested animation lifetime
* hold controls
* builder onboarding
* visibility rules during night, dialogs or cutscenes
* dialog UI typewriter behavior in `scripts/ui/dialog.gd`

The dialog system is unrelated. Do not couple the tutorial animator to it.

## Manual verification checklist

Verify through code inspection and report the expected manual cases:

1. A normal tutorial changes after `CHANGE_DELAY`: typewriter, character bounce and rainbow all start.
2. A forced Builder tutorial requested every frame animates only once.
3. A tutorial changes to another key: the new animation starts from character zero.
4. The same key remains active for several seconds: no restart or repeated allocation.
5. An alert appears: it receives the animation and remains visible for the full fresh lifetime.
6. A persistent alert settles into its existing red state after freshness.
7. A hold prompt changes between keyboard and gamepad text: the changed message animates once.
8. A dialog or cutscene hides the tutorial: active animation is cancelled cleanly.
9. A hidden tutorial appears again later: it animates again.
10. After typing plus 2 seconds: text is static white, with no remaining animated-effect processing.
11. Long text, multiple lines, French accents and punctuation retain correct layout.
12. Existing tutorial arrows and hold interactions behave exactly as before.

At the end, report:

* files created
* files modified
* the centralized message presentation path
* how duplicate per-frame requests are prevented from restarting animation
* the final tuning constants
* any existing direct `text` assignments intentionally left untouched and why
