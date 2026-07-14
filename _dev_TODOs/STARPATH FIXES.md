Update the existing star-path preview system in the attached codebase.

Follow `AGENTS.md`. Do not run Godot, tests, builds, compilation, or exports.

## Required changes

### Star-path visuals

Replace the current star visual with:

```txt
starpath_arrow.png
```

Sprite sheet:

* 16×16 frames
* 4 px inner padding
* frame 0: white arrow for clients
* frame 1: red arrow for monsters

Keep the internal system/name “star path” if convenient, but the displayed object must now be an arrow.

The arrow must rotate to face its current movement direction.

### Visibility

Make the arrows substantially easier to see:

* brighter;
* visible glow;
* visible fading trail.

Keep the implementation lightweight and pooled. Reuse the existing runner pooling and avoid creating particles, sprites, materials, or trail nodes every frame.

A pooled trail, afterimages, particles, or `Line2D` are acceptable. Choose the simplest clean solution consistent with the existing architecture.

### Speed

Make the arrows move approximately twice as fast as currently.

They must still follow turns correctly at the increased speed and must not skip route segments.

### Tile-center movement

The arrows must visibly travel through tile centers.

Currently they appear to run along tile edges, which makes the route difficult to understand.

Fix this in the runner’s actual traversal logic:

* move from one flow-field cell center to the next cell center;
* interpolate smoothly between centers;
* turn at tile centers;
* do not solve this by adding a visual sprite offset;
* do not hardcode tile size if existing map conversion helpers are available.

Do not change flow-field generation or route selection. This is a path-preview traversal/visual fix only.

## Remove obsolete spawner arrows

Remove the dedicated screen-edge arrows that point toward upcoming spawners, because the star-path preview now replaces them.

Clean their node, script, references, and any helper methods used only by that feature.

Do **not** remove or break the project’s generic arrow systems used for other purposes, such as tutorials, merchants, monsters, targets, or other off-screen indicators.

## Preserve

Do not modify:

* flow-field computation;
* garden entrance selection;
* wall/navigation invalidation;
* monster or client spawning;
* generic arrow behavior unrelated to upcoming-spawner warnings.

## Acceptance criteria

* Client previews use the white arrow frame.
* Monster previews use the red arrow frame.
* Arrows face their movement direction.
* Arrows are brighter, glowing, and leave a visible fading trail.
* Arrows move about twice as fast.
* Arrows clearly pass through tile centers and turn at tile centers.
* No dedicated upcoming-spawner edge arrows remain.
* Generic arrow systems still work.
* No new per-frame visual allocations or navigation recomputation are introduced.

At the end, report the files changed/deleted and briefly explain the tile-center traversal and pooled trail/glow implementation.
