Use this corrected prompt. It locks the gait to actual pixel distance and timing, and forces every loop to contain an even number of steps so the `L → R → L → R` sequence never breaks.

````text
Read `AGENTS.md` first and follow it strictly.

Task: finalize the existing Starpath footprint rendering. Patch the current implementation; do not redesign route generation.

Primary files:
- `scripts/map/path_preview_runner.gd`
- `scripts/map/path_preview_controller.gd`
- Update the relevant section of `scripts/map/ARCHITECTURE.md`

Keep `path_preview_route_planner.gd`, navigation, flow fields, route signatures, phase rules, pooling, and tile-center paths unchanged.

Do not run Godot, tests, compilation, build, or export.

## Exact visual contract

One Walk Animation must continuously produce:

```text
Left
16 px farther: Right
16 px farther: Left
16 px farther: Right
...
````

Use these exact defaults in world pixels:

```gdscript
footstep_stride_distance: float = 16.0
walk_speed: float = 32.0
footstep_side_offset: float = 6.0
footstep_fade_duration: float = 0.45
steps_per_nominal_animation: int = 6
```

Resulting cadence:

* one new footprint every `0.5 s`
* same foot repeats every `1.0 s`
* left/right centers are `12 px` apart across a straight line
* nominal Walk Animation section is `6 × 16 = 96 px`
* nominal section traversal lasts `96 / 32 = 3 s`

Do not approximate these values using point count, tile count, timers, or frame count. Movement and stamping must use actual arc-length distance along the polyline.

## Footprint state and fading

Each Walk Animation owns:

* current path distance
* next local step index
* held left footprint
* fading previous left footprint
* held right footprint
* fading previous right footprint

When printing a footprint:

1. Determine side from the step index:

   * even index: left
   * odd index: right
2. Sample the exact path position and local non-zero tangent.
3. Calculate:

```gdscript
var perpendicular: Vector2 = Vector2(-tangent.y, tangent.x)
var side_sign: float = -1.0 if is_left else 1.0
var final_position: Vector2 = path_position \
	+ perpendicular * side_sign * footstep_side_offset
```

4. Store `final_position` and rotation in the footprint record.
5. Move the existing held footprint of that same side into its fading slot.
6. Replace any older fading footprint of that side.
7. Store the new footprint fully opaque as the held footprint.

The held footprint remains fully visible until the next footprint of the same side is printed. The replaced footprint then fades linearly from alpha `1.0` to `0.0` in exactly `0.45 s`.

This bounds every Walk Animation to at most:

* one held left
* one fading left
* one held right
* one fading right

Never retain a historical trail of all stamps.

Sprite flipping may distinguish feet, but it must never replace the real `±6 px` positional offset.

## Dynamic Walk Animation sections

Several Walk Animations must cover the route immediately. Each animation walks only from its section start to the next animation’s section start, then loops back.

Sections must contain an even number of steps. This is mandatory: every section must end on Right and restart on Left, preserving continuous alternation.

Calculate:

```gdscript
var full_step_count: int = int(floor(total_line_length / 16.0))
var usable_step_count: int = full_step_count - (full_step_count % 2)
```

For normal routes, require at least two usable steps.

Then:

```gdscript
var total_pair_count: int = usable_step_count / 2
var wanted_animation_count: int = int(ceil(total_line_length / 96.0))

# Prevent tiny one-pair sections except on genuinely short routes.
var maximum_animation_count: int = maxi(1, total_pair_count / 2)
var animation_count: int = clampi(
	wanted_animation_count,
	1,
	maximum_animation_count
)
```

Distribute `total_pair_count` evenly between animations:

```gdscript
base_pairs = total_pair_count / animation_count
remainder_pairs = total_pair_count % animation_count
pairs_for_animation = base_pairs + (1 if index < remainder_pairs else 0)
steps_for_animation = pairs_for_animation * 2
```

Therefore every normal section contains an even number of steps, generally:

* 4 steps / 64 px for shorter remainder sections
* 6 steps / 96 px normally
* occasionally 8 steps / 128 px when needed for even distribution

Build each section from cumulative stride distance. Do not split the polyline by point index.

The final section may travel the small remaining route tail before looping, but it must not emit an extra unmatched step there.

## Section runtime

At preview start:

* Create the dynamic section states.
* Place each animation at its section start.
* Print its first Left footprint immediately.

During processing:

* Move each animation at exactly `32 px/s`.
* Emit every crossed `16 px` step, including multiple steps if one frame has a large delta.
* Never lose steps because of frame rate.
* After the section’s final Right step, continue to its boundary.
* At the boundary, wrap to the same section start.
* Do not treat the teleport as travelled distance.
* The next emitted footprint is Left.
* Do not clear the old end footprints abruptly; normal same-side replacement makes them fade as the restarted animation advances.

Remove the incorrect “two-step pair, pause, wait for fade” behavior entirely.

## Shared route sections

Preserve or complete shared-edge deduplication in `path_preview_controller.gd`.

When active routes/signatures change:

1. Build canonical keys for every consecutive path edge.
2. Treat `(A, B)` and `(B, A)` as the same edge.
3. Assign every shared edge to one deterministic route using stable route order.
4. Give each runner its owned-segment mask.
5. A Walk Animation may move through all its sections, but may print only on segments owned by its route.

Requirements:

* identical routes show one walking visualization
* partially overlapping routes merge only on shared edges
* routes render independently after divergence
* a point crossing without a shared edge is not merged
* no per-frame ownership rebuilding
* clear existing footprint state when route ownership is rebuilt

## Rendering and performance

Keep procedural `_draw()` rendering.

Do not create a Sprite2D, Tween, Timer, material, or particle node per footprint.

Precompute segment and cumulative lengths once when assigning the line. Sampling position/tangent must use this cache.

Remove obsolete state and exports from the previous pair/pause or moving-arrow implementations.

## Acceptance criteria

* Visible sequence is always `L, R +16 px, L +16 px, R +16 px`.
* A new step appears exactly every `0.5 s`.
* Left/right footprints are visibly separated by `12 px` center-to-center.
* Previous same-side footprint begins fading exactly when its replacement prints.
* Its fade completes before the following opposite step.
* No dense continuous footprint trail remains.
* Each Walk Animation loops without producing `L → L` or `R → R`.
* Route length dynamically determines the number of Walk Animations.
* Normal sections contain 4, 6, or 8 steps, never an odd step count.
* Shared edges display only one walking animation.
* No stale footprints, ownership data, or active processing remain after cleanup.

At completion, report only:

* files changed
* final exact tuning values
* section-count and even-step allocation
* footprint replacement/fading logic
* lateral-offset fix
* shared-edge deduplication behavior
* confirmation that no tests or builds were run

```
```
