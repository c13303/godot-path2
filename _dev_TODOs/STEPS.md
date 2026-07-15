Read `AGENTS.md` first and follow it. Do not run Godot, tests, builds, compilation, or export.

Task: patch the current Starpath footprint implementation. The route computation is correct; do not modify navigation or path generation.

Primary files:
- `scripts/map/path_preview_controller.gd`
- `scripts/map/path_preview_runner.gd`
- Touch other files only if directly required by these fixes.

## 1. Fix the walking gait

Current problem: left/right footprints are effectively centered on the path, so they read as a continuous symbol trail instead of walking.

For every footprint:

```gdscript
tangent = normalized local path direction
perpendicular = Vector2(-tangent.y, tangent.x)
position = path_position + perpendicular * side_sign * footstep_side_offset

Requirements:

Alternate side_sign strictly between -1 and +1.
Apply the offset to the footprint’s world position, before drawing it.
Do not treat horizontal sprite flipping as the lateral offset. Flipping is optional and visual only.
Each emitted stamp is one footprint, not both feet at once.
Keep the footprint rotated along the local tangent.
Use a clearly visible default side offset, approximately 6.0 world pixels, exported for tuning.
Consecutive left/right footprint centers must be separated by exactly 2.0 * footstep_side_offset across a straight path.
2. Strongly reduce footprint density

Current problem: walkers continuously leave footprints, producing an almost solid line.

Change the gait to sparse footprint pairs:

Stamp one foot.
After a short travelled distance, stamp the opposite foot.
Emit nothing until that pair has fully faded.
Then begin the next pair farther along the route.

Use exported tuning values:

footstep_pair_spacing_distance: float = 10.0
footstep_side_offset: float = 6.0
footstep_lifetime: float

Critical rule:

One invisible walker may have at most one visible two-foot pair at any time.
It must not begin another pair until both previous footprints have expired.
Walkers continue moving while waiting.
Do not restore a regularly spaced footprint trail.
Keep the existing dynamic walker count based on path length and the approximately three-second walker departure spacing.

The expected result is a few moving/fading pairs distributed along the route, with large empty spaces between them.

3. Deduplicate overlapping route sections

When multiple active Starpath routes use the same consecutive tile-center segments, render only one walking animation on the shared section.

Implement this once when the active route set is prepared or refreshed:

Inspect every consecutive point pair of every active line.
Build a canonical, direction-independent edge key from the two tile-center coordinates:
(A, B) and (B, A) must produce the same key.
Assign each unique edge to one deterministic route owner.
Give each runner an ownership mask/set for its path segments.
Walkers still travel through the complete route, but may stamp only while located on a segment owned by that runner.
When the route leaves the shared section, its own stamping resumes normally.

Requirements:

No per-frame rebuilding of the ownership map.
No flow-field or navigation queries.
Identical routes must produce only one visible footprint animation.
Partially overlapping routes must merge visually only on their shared edges and remain separate after divergence.
Single-tile crossings without a shared edge do not need merging.
Clear and rebuild ownership whenever active route signatures change.

Use deterministic ownership, such as the existing stable route order. Do not create a new manager or graph framework.

Preserve

Do not change:

client/monster texture-frame selection
route calculation
tile-center paths
phase activation
route invalidation/signatures
runner pooling and cleanup
distributed walker initialization
procedural _draw() rendering

Remove no feature outside this patch.

Acceptance criteria
Straight routes visibly alternate left/right around the path center.
Footprints look like pairs of walking steps, not a centered symbol.
Large empty gaps exist between successive pairs.
A walker never leaves several simultaneous pairs behind it.
Two routes sharing a corridor show exactly one footprint animation in that corridor.
Both routes render independently before joining and after splitting.
No duplicate nodes, stale ownership data, or growing footprint arrays remain after refreshes.

At completion, report only:

files changed
how lateral offset was corrected
how pair density is bounded
how shared segments are deduplicated
exported visual tuning values