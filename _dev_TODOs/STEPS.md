Read `AGENTS.md` first and follow it strictly.

Task: replace the current moving-arrow Starpath rendering with fading alternating footprints.

Scope:
- `scripts/map/path_preview_controller.gd`
- `scripts/map/path_preview_runner.gd`
- `scripts/map/path_preview_route_planner.gd` is read-only unless an actual bug blocks this task.
- Update the relevant `PathPreviewController / PathPreviewRunner` section in `scripts/map/ARCHITECTURE.md`.
- Do not touch C++, navigation, route generation, flow groups, spawner logic, or gameplay phase logic.
- Do not run Godot, tests, builds, compilation, or export.

## Existing behavior that must remain unchanged

The computed path is already correct. Treat its `PackedVector2Array` as “the line”.

Keep unchanged:
- route descriptors and signatures
- client/monster route selection
- route readiness and invalidation handling
- phase activation/cleanup
- `PathPreviewRoutePlanner.build_cell_center_path()`
- route paths going through tile centers
- runner pooling

The line is path data only. Do not visibly draw the line.

## New visual behavior

Completely remove:
- visible moving arrows
- arrow glow
- additive material
- line trails
- particles
- periodic arrow emission

`res://assets/sprites/house/starpath_arrow.png` is now a footprint sheet:
- frame 0: client footprint
- frame 1: monster footprint
- two 24×24 frames, with the existing 16×16 content and 4 px inner padding

The preview must look like several invisible agents continuously walking along the line:

- Each invisible walker moves forward along the full polyline.
- It stamps one footprint after each fixed travelled stride distance.
- Footprints alternate left/right.
- Left/right means a perpendicular offset on opposite sides of the local path direction.
- Mirror the sprite for the opposite foot if required; do not introduce additional texture frames.
- Every footprint is oriented using the local path tangent.
- Each footprint starts fully visible, then slowly fades to zero and is removed.
- At the route end, the invisible walker wraps to the start and continues.
- Never count the end-to-start wrap as travelled line distance and never stamp across that teleport.

Use the authored client/monster colors directly. Alpha fading is allowed; remove the old brightening tints and additive glow.

## Immediate route coverage: distributed walkers

Do not pre-draw a static trail.

Instead, initialize a dynamic number of invisible walkers already distributed along the line, as though walkers had been leaving the spawner regularly before the preview became visible.

Calculate the actual polyline length by summing segment lengths. Never use path point count.

Use:

```gdscript
walker_spacing = walker_speed * walker_departure_interval
walker_count = maxi(1, ceili(total_line_length / walker_spacing))
walker_start_distance = total_line_length * float(index) / float(walker_count)