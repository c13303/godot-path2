Implement **WIP houses and Builder construction work**.

Read and follow `AGENTS.md` before editing.

Do not run Godot, tests, compilation, export, or build commands. The user performs runtime testing.

# Context

The following systems have already been implemented:

* Generic multi-cell houses.
* Player-built and authored houses.
* House placement preview.
* House inventory, rewards, merchant purchase, and Rose Level Editor integration.
* House unbuild/refund.
* House durability and save/load.
* Dedicated `buildhouse` quickbar submenu.
* Multiple persistent Builder agents.
* Builders enter during daytime from `seedmerchent`.
* Builders claim separate idle cells near `builder_spot`.
* Builders leave through `seedmerchent_exit` at night.
* Builder roster count persists across days and saves.
* Developer key `K` adds persistent Builders.

Inspect and extend the actual implementation.

Do not recreate any of those systems.

# Objective

Newly player-built houses must begin in a:

```text
WIP
```

state.

A WIP house uses:

```text
wiphouse.png
```

The completed house continues to use:

```text
house1.png
```

Both sprites have exactly the same dimensions, alignment, footprint, and bottom-edge positioning.

During daytime, after a Builder has entered and reached an idle state, it can claim a WIP house construction task.

The Builder must:

1. Travel to a walkable cell near the WIP house.
2. Perform a simple busy-work loop around the house.
3. Alternate short local movements with short pauses.
4. Advance one visible construction progress bar.
5. Complete the house after 20 seconds of active work.
6. Replace `wiphouse.png` with the completed house sprite.
7. Take the next queued WIP house, or return to the Builder idle area.

When night begins:

* Builder work stops immediately.
* Runtime construction progress is preserved.
* Builders leave through their existing night-departure system.
* WIP houses remain WIP.
* Work resumes the next day once Builders have entered and become available.

For save/load:

* Save whether each house is WIP or completed.
* Preserve deterministic WIP task order.
* Do not save Builder positions or work assignments.
* Do not save partial work progress.
* After loading, every WIP house restarts at zero seconds of work.

---

# Fixed behavior decisions

## One Builder per house

A WIP house can have at most one assigned Builder.

Do not allow several Builders to accelerate the same house.

With multiple Builders and multiple WIP houses:

* Each available Builder receives a different house.
* Builders can work concurrently.
* Tasks are assigned in deterministic WIP queue order.

Example:

```text
Builders: B1, B2
WIP queue: H1, H2, H3

B1 -> H1
B2 -> H2

When H1 completes:
B1 -> H3
```

## Active work duration

A house requires:

```gdscript
20.0 seconds
```

of active Builder work.

Travel from `builder_spot` to the house does not count.

Progress counts only after the Builder has reached a valid work area near the house and entered its busy-work state.

Short movement between nearby work cells and intentional work pauses both count as active work.

Progress does not count while:

* The Builder is entering the map.
* The Builder is travelling from its idle area to the house.
* No Builder is assigned.
* The Builder cannot reach the house.
* The game is in night.
* The Builder is leaving.
* The assigned house no longer exists.
* The task is otherwise suspended.

## Night interruption

Night interruption does not reset runtime progress.

Example:

```text
Day 1:
Builder completes 12 / 20 seconds.

Night:
Progress remains 12 seconds.

Day 2:
A Builder resumes from 12 seconds.
House completes after 8 more active seconds.
```

The same physical Builder does not need to resume the task. Builders respawn each day, so task identity belongs to the house, not to an individual Builder.

## Save/load exception

Partial work progress is deliberately not saved.

Example:

```text
House is WIP at 12 / 20 seconds.
Player saves and reloads.
House remains WIP, but work restarts at 0 / 20 seconds.
```

Completed houses remain completed.

---

# Required ownership

Create a focused controller:

```text
scripts/map/house_builder_work_controller.gd
```

with:

```gdscript
class_name HouseBuilderWorkController
```

This controller owns:

* WIP task assignment.
* One-Builder-per-house assignment state.
* Unsaved runtime work progress.
* Deterministic task selection.
* Work-cell selection near houses.
* Busy-work movement state.
* Work/pause timing.
* Day interruption and resumption.
* Cancelling invalid tasks.
* Requesting house completion.
* Construction progress-bar coordination.

It does not own:

* House registry.
* House footprint geometry.
* House durability.
* House save records.
* Builder roster count.
* Builder spawning.
* Builder night departure.
* Generic A* implementation.
* General building placement.
* UI build selection.

## Existing owners remain authoritative

### `HouseManager`

Continues to own:

* House records.
* House status.
* House sprites.
* House item/type data.
* Entrance cells.
* Presence cells.
* Blocking cells.
* Placement order.
* Removal and destruction.
* Save serialization data.
* Completing a house and swapping its visual.

### `BuilderController`

Continues to own:

* Persistent Builder count.
* Active Builder instances.
* Builder lifecycle.
* Builder movement state.
* Idle-area claims near `builder_spot`.
* Current per-Builder destination claims.
* Day arrival.
* Night departure.
* Builder cleanup.

Extend it with focused public work APIs, but do not move the Builder roster or lifecycle into the new work controller.

### `HouseBuilderWorkController`

Coordinates the two existing owners.

It should ask:

* `HouseManager` for WIP houses and house geometry.
* `BuilderController` for available idle Builders and movement operations.

Do not let it reach through arbitrary private fields.

---

# House status model

Add stable house status constants to the existing house owner:

```gdscript
const HOUSE_STATUS_WIP: StringName = &"wip"
const HOUSE_STATUS_COMPLETED: StringName = &"completed"
```

Every logical house record must have one authoritative status.

Do not infer status from the currently assigned texture.

Provide focused queries such as:

```gdscript
func house_status(house_id: StringName) -> StringName
func is_house_wip(house_id: StringName) -> bool
func is_house_completed(house_id: StringName) -> bool
func get_wip_house_ids_in_build_order() -> Array[StringName]
func complete_house(house_id: StringName) -> bool
```

Use the actual stable house-ID type already implemented.

Do not duplicate status in both `HouseManager` and `HouseBuilderWorkController`.

## Initial status

### Newly placed player house

Every newly placed player-built house starts as:

```text
WIP
```

It immediately uses `wiphouse.png`.

### Authored houses

Authored houses such as:

```text
house_seedmerchant
```

start as:

```text
COMPLETED
```

They continue using their authored completed visuals.

They must not enter the Builder work queue.

### Existing older saves

A runtime house loaded from an older save without a status field must default to:

```text
COMPLETED
```

Do not unexpectedly convert existing saved houses into WIP houses.

### Restored current saves

A current save explicitly restores:

```text
wip
```

or:

```text
completed
```

A restored WIP house uses `wiphouse.png`.

A restored completed house uses its completed texture.

---

# Generic house visual definition

Do not hardcode texture paths throughout the house logic.

Extend the existing house item/type definition with focused visual fields following current catalog conventions.

The current house type should conceptually define:

```gdscript
"house_completed_texture": preload("res://assets/sprites/house/house1.png"),
"house_wip_texture": preload("res://assets/sprites/house/wiphouse.png"),
"builder_work_seconds": 20.0
```

Locate the actual assets in the repository.

Do not invent duplicate assets or alternate paths.

Future house types should be able to provide their own:

* WIP texture.
* Completed texture.
* Work duration.

Do not implement additional house types now.

Keep the existing placement preview behavior. The preview may continue showing the completed house appearance so the player sees the intended final result.

Only the committed runtime house begins with the WIP visual.

## Visual swap

When work completes:

* Keep the same `Sprite2D`.
* Replace its texture with the completed texture.
* Preserve:

  * Global position.
  * Bottom alignment.
  * Scale.
  * Offset.
  * Z-index.
  * Modulation.
  * Visibility.
  * House registry identity.
  * Durability identity.
  * Current health.

Do not destroy and recreate the logical house merely to change its texture.

Do not trigger navigation invalidation when the texture changes.

WIP and completed houses have identical map presence.

---

# Placement and technical navigation readiness

The existing house-placement path may have a technical construction state while:

* Blocking cells are registered.
* Walkability is rebuilt.
* Lazy flow fields finish.

This technical navigation readiness is different from the new 20-second Builder gameplay construction.

A WIP house may appear immediately with `wiphouse.png`, but it is not eligible for Builder work until its normal placement/navigation registration is fully ready.

Provide a focused readiness query through the current house/construction owner, for example:

```gdscript
func is_house_navigation_ready(house_id: StringName) -> bool
```

Do not make the Builder approach a house while its placement topology is still pending.

## Avoid duplicate progress bars

The player must not see two similar house construction bars:

1. A technical navigation-rebuild bar.
2. A Builder work bar.

Reserve the visible house construction progress bar for the 20-second Builder work.

For houses:

* Preserve internal navigation-readiness tracking.
* Do not show a separate technical topology progress bar.
* Do not affect the technical construction overlay for walls, fences, turrets, or other existing buildings.
* Builder work begins only after technical readiness is complete.

If the current implementation can cleanly hand one existing indicator from technical readiness into gameplay work, that is acceptable, but it must display only the 20-second Builder progress to the player.

Do not merge the navigation state machine with Builder work progress.

---

# WIP task order

Every newly placed WIP house receives a deterministic monotonic construction order.

Use an existing stable placement sequence if one already exists.

Otherwise add a focused field such as:

```gdscript
construction_order: int
```

The first WIP house placed has the lowest order.

Later houses receive increasing order values.

The WIP queue is always sorted by:

```text
construction_order ascending
```

Do not use:

* Dictionary iteration order.
* World position.
* Distance from Builder.
* Random ordering.
* Nearest-house ordering.

## Stable queue behavior

Once created, a WIP house retains its construction order until:

* It completes.
* It is unbuilt.
* It is destroyed.

Night does not reorder the queue.

Builder removal does not reorder the queue.

Temporary path failure does not reorder the queue.

Save/load must preserve construction order.

If the existing runtime-house save array already guarantees placement order, it may remain the source of truth, but make this guarantee explicit and reliable.

Do not rely accidentally on unspecified dictionary order.

## Assignment with multiple Builders

Assignment is deterministic:

1. Get available Builders in stable Builder runtime order.
2. Get WIP houses in construction order.
3. Assign each Builder the earliest unassigned eligible WIP house.
4. Never assign two Builders to one house.

If a WIP house is temporarily unreachable:

* Keep it in its original queue position.
* Do not permanently move it behind other houses.
* It may be skipped for the current assignment attempt so another reachable task can proceed.
* Retry it after:

  * A topology change.
  * A new day.
  * A Builder becomes available.
  * Another task completes.

The queue itself must never be rewritten because of reachability.

---

# Builder availability

A Builder is available for work only when it:

* Is active.
* Has completed its daytime entrance.
* Has reached an idle destination near `builder_spot`.
* Is not leaving.
* Has no existing house assignment.
* Has not been removed.
* Is not waiting for night departure.

A Builder that has only spawned but has not yet reached its idle area is not available.

Add focused Builder queries, for example:

```gdscript
func available_idle_builder_ids() -> Array[int]
func is_builder_available_for_work(builder_id: int) -> bool
func is_builder_active(builder_id: int) -> bool
func is_builder_leaving(builder_id: int) -> bool
```

Use the actual stable Builder runtime identifier already implemented.

Do not expose or mutate the Builder controller’s internal arrays directly.

## Transition from idle to work

When assigned:

1. Release the Builder’s idle-area claim near `builder_spot`.
2. Claim a valid work cell near the WIP house.
3. Change the Builder’s state from idle to work travel.
4. Assign an A* path to the work cell.

If assignment fails:

* Restore or reacquire an idle-area claim.
* Leave the Builder available for another task.
* Do not lose the Builder.
* Do not create a partial assignment.

## After task completion

After completing a house:

* Immediately attempt the next WIP task.
* If no task is available, return the Builder to a unique idle cell near `builder_spot`.
* Reuse the existing Builder idle-claim logic.

The Builder does not need to return to `builder_spot` between consecutive houses.

---

# Work cells near a house

A Builder must stand on a walkable cell outside the house’s six-cell presence.

Do not hardcode the current `3 × 2` offsets again inside the work controller.

Ask `HouseManager` for the complete presence cells.

Generate nearby candidate cells from that authoritative footprint.

## Candidate generation

Search deterministically around the house footprint:

1. Cells immediately adjacent to the footprint.
2. Then cells one additional ring farther away if necessary.
3. Continue only to a small bounded radius.

Use one named constant, for example:

```gdscript
const HOUSE_WORK_CELL_SEARCH_RADIUS: int = 3
```

Do not search the entire map.

Prefer immediate neighbouring cells.

A candidate is valid only when:

* It exists on the floor.
* It is walkable.
* It is outside the house presence.
* It is not one of the house’s five blocker cells.
* It is not the house entrance.
* It is not already claimed by another Builder.
* It is not reserved by another stationary daytime visitor.
* It is not currently occupied by an incompatible stationary agent.
* It is reachable from the Builder’s current cell.

Check path reachability before committing the claim.

Do not let two Builders claim the same work cell.

## Claim ownership

`BuilderController` already owns Builder destination claims.

Extend that claim system so a Builder may own either:

* An idle claim near `builder_spot`.
* A work claim near a house.

Do not create a second independent cell-claim dictionary in the work controller.

The work controller owns the house assignment.

The Builder controller owns the Builder’s current destination-cell claim.

---

# Busy-work behavior

After reaching its first work cell, the Builder enters a simple busy-work loop.

Do not add new art or a complex animation system.

Reuse:

* Existing Builder movement.
* Existing directional frames.
* Existing movement bounce.
* Existing idle breathing.
* Existing path arrival.

The movement itself creates the work animation.

## Simple state loop

Each assigned Builder uses states equivalent to:

```text
TRAVELLING_TO_WORK
WORK_PAUSE
WORK_MOVE
```

### `TRAVELLING_TO_WORK`

The Builder walks from its idle position to the first claimed work cell.

Work progress remains frozen.

### `WORK_PAUSE`

The Builder remains near the house for a short pause.

During the pause:

* Existing idle animation continues.
* Face toward the house when a current facing API already supports this cleanly.
* Do not add a special Builder tool animation.
* Work progress advances.

Use small named pause durations.

For example, deterministic variation may cycle through values around:

```text
0.8 to 1.5 seconds
```

Do not use unpredictable global random state.

A fixed or locally deterministic sequence is sufficient.

### `WORK_MOVE`

After a pause:

1. Choose another valid work cell near the same house.
2. Prefer a different nearby cell when available.
3. Atomically change the Builder destination claim.
4. Assign a short A* path.
5. Walk there.
6. Enter another pause after arrival.

Work progress continues during this local movement because the Builder is already actively working around the house.

If no second work cell is available:

* Keep the Builder on the current valid work cell.
* Continue alternating work pauses.
* Allow progress to continue.
* Do not fail the task merely because only one approach tile is usable.

## No fake orbit

Do not:

* Tween the Builder manually around the house.
* Teleport it.
* Rotate it around the sprite.
* Disable normal navigation.
* Move it through blocker cells.
* Make it circle every frame.

Use real short navigation paths between valid nearby cells.

## Progress validity

Work progresses only while:

* It is daytime.
* The assigned Builder exists.
* The Builder is in `WORK_PAUSE` or local `WORK_MOVE`.
* The house still exists.
* The house is still WIP.
* The Builder remains assigned to that house.
* The Builder is not leaving.

If the Builder becomes unable to remain near the house, freeze progress until it reacquires a valid work cell.

---

# Work progress state

`HouseBuilderWorkController` owns unsaved runtime progress keyed by house ID.

Conceptually:

```gdscript
var _work_seconds_by_house_id: Dictionary = {}
```

Use explicit typing compatible with the current GDScript version and project conventions.

Do not add partial progress to `HouseManager` save records.

For every new WIP house:

```text
runtime progress = 0.0
```

During the same running session:

* Progress survives Builder reassignment.
* Progress survives night.
* Progress survives a temporary unreachable state.
* Progress survives all Builders being unavailable.

Progress is discarded when:

* The house completes.
* The house is normally unbuilt.
* The house is destroyed.
* A save is reloaded.

Clamp runtime progress to:

```text
0.0 ... required work seconds
```

Do not use wall-clock timestamps.

Advance using frame `delta` only while work is valid.

---

# Progress-bar presentation

Show exactly one Builder work progress bar per actively worked WIP house.

Create a focused owner such as:

```text
scripts/map/house_work_progress_overlay.gd
```

with:

```gdscript
class_name HouseWorkProgressOverlay
```

Reuse an existing generic construction-indicator visual component if one was already extracted, but do not reuse the topology progress state machine.

The overlay owns:

* Creating one progress bar for a house.
* Positioning it above the WIP house sprite.
* Updating normalized progress.
* Hiding/removing it when work is suspended or completed.
* Cleaning it when the house is removed.

It does not own progress calculations.

## Display rules

While a Builder is actively working:

* Show the bar.
* Display linear progress from `0.0` to `1.0`.
* Anchor it above the actual house sprite bounds.
* Keep it correctly sorted with the house.
* Do not create one bar per Builder movement target.

When work is interrupted at night:

* Hide the bar.
* Preserve runtime progress internally.
* Show the same progress again when work resumes.

When no Builder is available:

* Hide the bar.
* Preserve progress.

When the house completes:

* Remove the bar.

When a WIP house is removed or destroyed:

* Remove the bar immediately.

## Health-bar compatibility

A damaged WIP house may also have a durability health bar.

Ensure the two overlays do not occupy exactly the same position.

Use the existing overlay-positioning convention or a small stable vertical offset.

Do not merge construction progress with health.

---

# Completion

When progress reaches the house type’s required duration:

1. Validate that the house still exists.
2. Validate that it is still WIP.
3. Mark it completed through `HouseManager`.
4. Swap to the completed texture.
5. Remove its work progress state.
6. Remove its progress bar.
7. Clear the Builder-to-house assignment.
8. Release the current work-cell claim.
9. Request the next queued WIP task for that Builder.
10. If none exists, send the Builder back to the idle area.

Completion must not:

* Change the house footprint.
* Clear or restamp wall cells.
* Trigger navigation invalidation.
* Re-register durability.
* Reset current house health.
* Refund inventory.
* Play placement currency effects.
* Create another house record.
* Replace the house’s stable logical identity.

A completed house retains all existing:

* Unbuild behavior.
* Destructibility.
* Save identity.
* Entrance.
* Occupancy.
* Navigation blocking.
* Z-index.

---

# Night transition

At the beginning of night, before Builders begin leaving:

1. Freeze all active house-work progress.
2. Hide all work progress bars.
3. Cancel local work movement loops.
4. Clear Builder-to-house assignments.
5. Release work-cell claims.
6. Preserve each WIP house’s runtime progress.
7. Hand every Builder back to the existing night-departure lifecycle.

Do not make Builders return to `builder_spot` before leaving.

They should leave from their current valid location through the existing `seedmerchent` escape route.

Do not delay night preparation for Builder work.

Do not reset house progress.

Do not complete a house after night has started because a frame timer crossed 20 seconds.

Night interruption must take precedence.

## Next day

When Builders return and reach idle state:

* Re-evaluate the WIP queue in the same construction order.
* Assign available Builders.
* Reuse preserved runtime progress.
* Show the progress bar again from the preserved fraction.
* Resume work.

The same physical Builder does not need to receive the same house.

---

# New WIP house during daytime

When a new player-built WIP house is successfully committed:

1. Register its WIP status and construction order.
2. Display `wiphouse.png`.
3. Wait for existing technical navigation readiness.
4. Notify the work controller that task availability changed.
5. If an idle Builder is available, assign according to queue order.
6. Otherwise leave it queued.

Do not scan every house every frame to notice the addition.

Use a focused event, signal, or direct notification from the authoritative house-registration path.

A direct typed call is acceptable.

Do not let placement UI assign a Builder.

---

# House removal and hostile destruction

WIP and completed houses remain fully removable and destructible through the already implemented systems.

## WIP unbuild

When a WIP house is normally unbuilt:

* Cancel any active Builder assignment.
* Freeze no remaining progress; discard it.
* Remove its progress bar.
* Release the Builder’s work-cell claim.
* Remove it from the effective WIP queue.
* Preserve the existing one-house inventory refund.
* Send the Builder to the next task or idle area.

Do not make the Builder continue working on a removed house.

## WIP hostile destruction

When a WIP house is destroyed:

* Cancel the task.
* Discard progress.
* Remove the bar.
* Release the work-cell claim.
* Preserve the existing no-refund destruction behavior.
* Send the Builder to the next task or idle area.

## Completed house removal

Completed-house removal remains unchanged.

Do not involve the work controller when a completed house has no task.

## Removal race safety

A house may disappear while the Builder is:

* Travelling to it.
* Pausing.
* Moving locally.
* Being interrupted by night.
* Completing it.

Validate house existence before every authoritative state transition.

Cancellation must be idempotent.

Do not produce stale node references, orphaned bars, or permanently busy Builders.

---

# Walkability changes

Builder work must use the existing hard-topology invalidation seam.

Do not perform per-frame path validation across all houses.

When topology changes:

## Builder travelling to a WIP house

* Validate its current work destination.
* Repath to it if still valid.
* Otherwise find another valid work cell near the same house.
* Preserve the house assignment and progress.

## Builder actively working

* Validate its current claimed work cell.
* If still valid, preserve the task.
* If blocked, claim a replacement work cell.
* Freeze progress until the Builder reaches a valid work area again.

## House becomes unreachable

If no reachable work cell exists:

* Suspend the assignment.
* Release invalid cell claims.
* Preserve runtime progress.
* Make the Builder available for another reachable WIP task or return it to idle.
* Keep the unreachable house in its original queue position.
* Retry it on future topology changes and day starts.
* Log one concise warning for the failed assignment event.

Do not reorder the queue.

Do not retry every frame.

---

# Task assignment processing

Task assignment must be event-driven or dirty-flag driven.

Re-run assignment when:

* A Builder reaches idle state.
* A new WIP house becomes navigation-ready.
* A house completes.
* A task is cancelled.
* A Builder is removed.
* A topology change may make a house reachable.
* A new day begins.
* A new Builder is added with the developer key and reaches idle.

Do not scan all houses and all Builders every frame.

The runtime tick may process:

* Active assignment timers.
* Active short movement/pause states.
* A small dirty assignment queue.

The number of active Builders is expected to remain small.

Use direct owned collections, not scene-tree group scans each frame.

---

# BuilderController integration

Extend `BuilderController` with focused task-aware states.

Use existing state conventions when available.

Conceptually, a Builder can be:

```text
ENTERING
IDLE
TRAVELLING_TO_WORK
WORKING
LEAVING
```

Do not create a second conflicting state field in `HouseBuilderWorkController`.

One owner must remain authoritative for each Builder’s movement/lifecycle state.

A clean split is:

* `BuilderController` owns each Builder’s movement/lifecycle state.
* `HouseBuilderWorkController` owns house assignment and work progress.

Provide focused methods such as:

```gdscript
func assign_builder_to_work_cell(
    builder_id: int,
    house_id: StringName,
    target_cell: Vector2i
) -> bool

func request_builder_local_work_move(
    builder_id: int,
    target_cell: Vector2i
) -> bool

func release_builder_from_work(builder_id: int) -> void

func return_builder_to_idle_area(builder_id: int) -> void

func builder_reached_current_target(builder_id: int) -> bool
```

Use actual implemented ID types and naming conventions.

Do not expose mutable visitor records.

Do not let the work controller directly manipulate the shared day-visitor helper’s private fields.

---

# Multiple Builder behavior

The implementation must correctly handle:

* One Builder and many WIP houses.
* Many Builders and one WIP house.
* Many Builders and many WIP houses.
* More Builders than available work cells.
* More Builders than WIP houses.
* Builders added during the day with `K`.
* Builders added during night with `K`.

## One house, many Builders

Only one Builder works on the house.

Other Builders remain idle.

They do not reduce the 20-second duration.

## New Builder during day

A Builder added with the development key:

1. Uses the existing roster/spawn behavior.
2. Enters normally.
3. Claims an idle tile near `builder_spot`.
4. Becomes eligible for work after reaching idle.
5. Takes the earliest unassigned eligible WIP task.

Do not assign it before it has completed entrance.

## New Builder during night

It remains part of the persistent roster and appears next day.

No WIP work starts during night.

---

# Save/load

Extend the existing explicit runtime-house serialization.

Each player-built house save record must preserve:

```text
house status: wip or completed
construction order
```

Use stable serialized values such as:

```gdscript
"status": "wip"
```

and:

```gdscript
"status": "completed"
```

Do not serialize raw `StringName` implementation details when the existing save format uses strings.

## Deliberately not saved

Do not save:

* Partial work seconds.
* Assigned Builder ID.
* Builder work cell.
* Busy-work movement state.
* Pause timer.
* Progress-bar state.
* Builder position.

## Load behavior

When restoring houses:

### Completed

* Restore completed status.
* Use completed texture.
* Do not enter the WIP queue.

### WIP

* Restore WIP status.
* Use WIP texture.
* Restore construction order.
* Initialize runtime progress to `0.0`.
* Add it to the effective WIP queue.
* Do not show a bar until a Builder starts working.
* Do not restore any assignment.

Builders are restored through their already implemented roster system.

After daytime Builders reach idle, normal task assignment begins.

During a night load:

* WIP houses remain queued.
* No Builders spawn immediately.
* Work starts next day.

## Compatibility

Older saves without house status:

```text
default to completed
```

Older saves without construction order:

* Preserve their existing house list order when possible.
* Assign normalized deterministic order values only if needed.
* Do not make completed houses WIP.

Bump save version only if required by current project conventions.

Preserve all previous save compatibility.

---

# Technical placement progress migration

The previous house implementation may currently treat a runtime house as “under construction” only while navigation topology is rebuilding.

Audit the actual implementation carefully.

Do not confuse these concepts:

```text
Technical placement readiness
Gameplay WIP status
Builder work progress
```

Required final semantics:

## Technical placement readiness

* Internal.
* Short-lived.
* Controls when navigation is safe.
* Not saved.
* Does not complete the house visually.
* Does not use the 20-second Builder timer.

## Gameplay WIP status

* Persistent.
* Saved.
* Uses `wiphouse.png`.
* Requires Builder work.
* Can survive several days.

## Builder work progress

* Runtime only.
* Preserved through night.
* Reset on save/load.
* Drives the visible progress bar.
* Completes the WIP house.

Rename ambiguous fields or methods locally when necessary.

Preserve compatibility wrappers when dynamic callers may exist.

Do not perform an unrelated broad refactor.

---

# BuildingManager integration

Instantiate and set up the new focused controller through `BuildingManager`.

Keep the manager as a façade.

Allowed thin responsibilities:

* Controller construction and setup.
* Day-start forwarding.
* Night-start forwarding.
* Runtime tick forwarding.
* Topology-change forwarding.
* House-added/removed forwarding where needed.
* Typed getter.
* Save façade calls delegated to `HouseManager`.

Provide a typed getter such as:

```gdscript
func get_house_builder_work_controller() -> HouseBuilderWorkController
```

Do not add to `BuildingManager`:

* WIP queue arrays.
* Work timers.
* Builder assignment dictionaries.
* Work-cell search.
* Busy-work state machines.
* Progress-bar creation.
* Texture swapping algorithms.
* Save-record transformations.

---

# Runtime tick integration

Extend the existing runtime tick controller with one focused call such as:

```gdscript
_house_builder_work.process(delta)
```

The work controller may iterate only over active house assignments.

Do not iterate over:

* Every map cell.
* Every house when no task state changed.
* Every agent in the scene tree.
* Every Builder group node through `get_nodes_in_group()` each frame.

Assignment discovery remains event/dirty driven.

Per-frame processing is limited to:

* Work timers.
* Short pause timers.
* Active local movement state.
* Completion checks.

---

# Architecture documentation

Update:

```text
scripts/map/ARCHITECTURE.md
```

Document:

* `HouseManager` owns house status and construction order.
* `HouseBuilderWorkController` owns task assignment and unsaved runtime progress.
* `BuilderController` owns Builder lifecycle, movement state, and destination claims.
* The work progress overlay owns only presentation.
* WIP status is saved.
* Runtime progress is preserved through night but intentionally not saved.
* House completion swaps only visual/status and does not affect topology.

---

# Explicitly forbidden implementations

Do not:

* Represent WIP as a second house object.
* Replace a WIP house by removing and rebuilding it.
* Infer WIP status from texture equality.
* Store house status only in the sprite.
* Let authored houses enter the WIP queue.
* Turn old saved houses into WIP houses.
* Assign several Builders to one house.
* Make multiple Builders reduce the 20-second duration.
* Reset progress every night.
* Save partial work progress.
* Save Builder work positions.
* Let Builders work during night.
* Count travel from `builder_spot` as work time.
* Use global random task ordering.
* Use nearest-house ordering instead of construction order.
* Reorder the queue when a house is unreachable.
* Let two Builders claim the same work cell.
* Teleport or tween Builders around houses.
* Make Builders walk through house blockers.
* Duplicate house footprint offsets in the work controller.
* Trigger navigation rebuilding on completion.
* Reset durability or health on completion.
* Refund inventory on completion.
* Leave a Builder assigned to a removed house.
* Display two confusing house construction bars.
* Add WIP logic to `BuildingManager`.
* Scan all houses every frame.
* Modify the C++ extension.
* Run Godot or tests.

---

# Likely files

New:

```text
scripts/map/house_builder_work_controller.gd
scripts/map/house_work_progress_overlay.gd
```

Modify only as required:

```text
scripts/map/house_manager.gd
scripts/map/builder_controller.gd
scripts/map/day_visitor_movement_controller.gd
scripts/map/building_manager.gd
scripts/map/building_runtime_tick_controller.gd
scripts/map/building_invalidation_controller.gd
scripts/map/building_construction_overlay.gd
scripts/map/build_removal_service.gd
scripts/map/player_placeable_durability_service.gd
scripts/items/item_catalog.gd
scripts/gameState/progression.gd
scripts/map/ARCHITECTURE.md
```

The exact files depend on the post-Builder implementation.

Inspect current ownership before editing.

Do not modify unrelated systems.

---

# Acceptance criteria

## New house placement

* Placing a house creates one normal logical house.
* It begins with status `wip`.
* It uses `wiphouse.png`.
* Its footprint, collision, entrance, durability, and unbuild behavior remain correct.
* It receives deterministic construction order.
* It is not eligible for Builder work until technical navigation readiness completes.
* No duplicate technical progress bar is displayed.

## Builder assignment

* A Builder must first enter and reach idle state.
* The earliest eligible WIP house is assigned.
* The Builder releases its idle claim.
* It claims a reachable walkable tile near the house.
* It walks there normally.
* Travel time does not increase house progress.

## Busy work

* After reaching the house, the progress bar appears.
* The Builder alternates local movement and pauses.
* Movement uses normal navigation.
* Existing Builder animation makes it visibly busy.
* Progress advances during local work movement and pauses.
* One house completes after approximately 20 seconds of active work.
* Only one Builder can work on each house.

## Completion

* The WIP sprite changes to the completed house sprite.
* Position and z-index do not change.
* Footprint does not change.
* Navigation is not recomputed.
* Current durability and health remain unchanged.
* The progress bar disappears.
* The Builder takes the next task or returns to idle.

## Multiple houses

With one Builder:

* Houses are processed in placement order.
* Progress on the current task is retained through night.
* The next task begins only after completion or cancellation.

With multiple Builders:

* Different Builders receive different houses.
* Houses are assigned in queue order.
* No house receives two Builders.
* Tasks can progress concurrently.
* A free Builder takes the next unassigned WIP house.

## Night

* Work freezes immediately when night begins.
* No progress occurs during night.
* Bars are hidden.
* Builders leave normally from their current locations.
* Runtime progress is preserved.
* WIP sprites remain.
* Next day, work resumes from preserved runtime progress.

## Save/load

* WIP/completed status is saved.
* Construction order is saved.
* Partial work seconds are not saved.
* Builder assignments are not saved.
* Builder positions are not saved.
* Loading a WIP house shows `wiphouse.png`.
* Loaded WIP progress starts at zero.
* Loading a completed house shows the completed texture.
* Old saves without status treat houses as completed.
* Loading during night does not spawn working Builders.
* Work begins next day through the normal Builder lifecycle.

## Removal and destruction

* Unbuilding a WIP house cancels its task.
* Destroying a WIP house cancels its task.
* Progress bars and work claims are cleaned.
* The Builder takes another task or returns idle.
* Refund and no-refund semantics remain unchanged.
* No stale assignment remains.

## Regression safety

Verify no regressions in:

* Authored `house_seedmerchant`.
* House preview.
* House placement.
* House blocking footprint.
* House entrance walkability.
* House unbuild/refund.
* House durability.
* House health bars.
* Completed-house save/load.
* Builder roster persistence.
* Multiple Builder idle claims.
* K development key.
* Builder day arrival.
* Builder night departure.
* Seed merchant lifecycle.
* Wall and other building construction overlays.
* Navigation invalidation.

---

# Manual test plan

Do not run these tests. Include them in the final report.

1. Place one house during daytime.
2. Verify it uses `wiphouse.png`.
3. Verify its footprint and entrance remain correct.
4. Wait for a Builder to reach idle.
5. Verify it claims the WIP task.
6. Verify travel to the house does not advance progress.
7. Verify the progress bar appears after work begins.
8. Verify the Builder alternates movement and pauses.
9. Verify completion takes about 20 seconds of active work.
10. Verify the sprite changes to `house1.png`.
11. Verify no navigation rebuild occurs on completion.
12. Place three WIP houses with one Builder.
13. Verify placement-order processing.
14. Start night halfway through a task.
15. Verify progress freezes and the Builder leaves.
16. Start the next day and verify runtime progress resumes.
17. Add a second Builder with K.
18. Place several WIP houses.
19. Verify two houses are worked concurrently.
20. Verify no house receives two Builders.
21. Unbuild a house while a Builder travels to it.
22. Unbuild a house while it is actively worked.
23. Destroy a WIP house while it is actively worked.
24. Block all nearby work cells and verify safe suspension.
25. Reopen a work cell and verify retry.
26. Save with a partially worked WIP house.
27. Reload and verify status remains WIP but progress restarts at zero.
28. Save and reload a completed house.
29. Load an older save with existing houses and verify they remain completed.
30. Verify authored houses never receive Builder tasks.

---

# Final report

Report:

1. Every created and modified file.
2. Final ownership of:

   * House status.
   * Construction order.
   * Task assignment.
   * Runtime progress.
   * Builder movement state.
   * Work-cell claims.
   * Progress-bar presentation.
3. How new player houses enter WIP status.
4. How authored and legacy houses remain completed.
5. How WIP and completed textures are configured generically.
6. How deterministic task order is preserved.
7. How multiple Builders receive separate houses.
8. How nearby work cells are generated from authoritative house geometry.
9. How busy-work movement and pauses function.
10. Exactly when the 20-second timer advances.
11. How night interruption preserves runtime progress.
12. How save/load resets only partial progress.
13. How task cancellation handles removal and destruction.
14. How technical topology readiness remains separate from gameplay construction.
15. How duplicate visible progress bars were prevented.
16. Any compatibility wrappers retained.
17. Any private coupling retained.
18. Any production-quality concern discovered.
19. Manual tests without claiming they were run.
