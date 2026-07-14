# Fix PathPreview early arrival, remove outbound preview, and correct misleading garden entry/exit debug display

Work from the attached updated codebase and follow `AGENTS.md`.

Do not run Godot, tests, compilation, export, or build commands. The user will test manually.

## Confirmed problems from static inspection

There are three related but distinct issues.

### 1. PathPreview stops many tiles before the garden entrance

In:

```text
scripts/map/path_preview_runner.gd
```

the runner currently contains:

```gdscript
var cost: float = float(
    _flow.call("group_route_cost_at_world", _group_id, _world_position)
)

if cost <= _arrival_radius:
    _finish("arrival_cost")
    return
```

This is invalid because the units do not match.

`_arrival_radius` is a world-space pixel distance:

```gdscript
@export var arrival_radius: float = 12.0
```

But `group_route_cost_at_world()` returns the native Dijkstra route cost:

```text
cardinal step = 1.0
diagonal step = 1.414213...
```

It is therefore measured approximately in tile steps, not pixels.

With an arrival radius of `12.0`, the star can terminate around 12 tiles before its actual goal.

This is the primary reason the star path currently stops far before the selected garden entrance.

### 2. Flow direction becomes zero inside the goal tile

The native flow field deliberately assigns a zero direction to its goal cell.

Therefore, after removing the invalid cost/radius comparison, a runner entering the goal tile may receive:

```gdscript
direction == Vector2.ZERO
```

while still being several pixels from the exact cell center.

The runner currently treats sustained zero flow as a failure and recycles after:

```gdscript
_max_zero_flow_seconds
```

For the final goal cell, zero flow is expected and must not be treated as an error.

### 3. The garden “exit” debug tile is not a real runtime exit

Garden topology stores one common set of garden boundary/access cells:

```gdscript
garden["entry_cells"]
```

There is no independently authored or stored entrance set and exit set.

The debug overlay derives:

```text
entrance = nearest/scored boundary cell relative to the spawner
exit     = scored boundary cell relative to the despawner
```

However, runtime agents no longer navigate to a selected garden exit after eating.

Current runtime escape behavior in:

```text
scripts/map/agent_navigation_phase_controller.gd
```

assigns the agent directly to the global escape flow field from its current position:

```gdscript
assign_agent_to_escape(agent)
```

Therefore, the green debug “garden exit” is hypothetical legacy information. It does not represent a cell that the monster actually visits.

This makes the overlay look reversed or incorrect even when the inbound entry selection itself is valid.

---

# Required change 1: remove the outbound PathPreview leg completely

The current attached code still creates two legs in:

```text
scripts/map/path_preview_controller.gd
```

Current code:

```gdscript
_append_leg_plan(
    legs,
    spawner_cell,
    spawner_cell,
    entry_cell,
    block_fences,
    route_color,
    &"inbound"
)

_append_leg_plan(
    legs,
    spawner_cell,
    entry_cell,
    escape_cell,
    block_fences,
    route_color,
    &"outbound"
)
```

Remove the second leg entirely.

Monster PathPreview must only compute and display:

```text
active monster spawner -> selected real garden entry
```

It must not compute or display:

```text
garden entry -> despawner
```

This means removing all preview-only outbound work:

* outbound leg descriptor;
* outbound preview flow group;
* outbound route signature data;
* outbound star runner;
* preview escape-target resolution;
* outbound-specific direction values;
* outbound-specific counters or logs.

Do not merely hide the outbound runner after computing its flow field.

The unnecessary flow group must not be created at all.

## Updated route signature

The signature for one selected route needs only:

```text
spawner cell
garden ID
selected entry cell
navigation revision
preview kind
```

Do not include `escape_cell`.

Conceptually:

```gdscript
signature_parts.append(
    "%s:%d:%s" % [
        str(spawner_cell),
        garden_id,
        str(entry_cell),
    ]
)
```

Preserve whatever stable formatting best fits the existing implementation.

## Expected route count

For two active monster spawners:

```text
selected gardens: 2
preview legs:     2 total
preview groups:   2 total
```

Not four.

Do not modify actual monster escape navigation.

---

# Required change 2: fix PathPreview arrival units

In:

```text
scripts/map/path_preview_runner.gd
```

remove this arrival condition completely:

```gdscript
if cost <= _arrival_radius:
    _finish("arrival_cost")
    return
```

Do not replace it with:

```gdscript
cost <= arrival_radius / tile_size
```

Do not invent a conversion between route cost and pixels.

Route cost can include:

* cardinal steps;
* diagonal steps;
* potentially future weighted navigation costs.

It is not an authoritative world-space distance.

## Correct arrival condition

Normal arrival must use only world-space distance:

```gdscript
_world_position.distance_to(_goal_world) <= _arrival_radius
```

This check already exists before and after movement. Preserve it.

Route cost may continue to be used for:

* detecting an unreachable position;
* gradient fallback sampling;
* detecting that the runner is inside the exact goal cell.

It must not be compared to a pixel radius.

---

# Required change 3: complete movement to the center of the goal cell

When the runner is inside the native flow field’s goal cell:

```gdscript
group_route_cost_at_world(...) == 0.0
```

the native flow direction is intentionally zero.

In that specific state, move directly toward `_goal_world` instead of starting the zero-flow timeout.

## Required behavior

At each movement substep:

1. Sample the flow direction normally.
2. If it is nonzero, follow it normally.
3. If it is zero:

   * read the current route cost;
   * if the cost is finite and approximately zero, use direct final steering:

```gdscript
var goal_delta: Vector2 = _goal_world - _world_position
direction = goal_delta.normalized()
```

* otherwise preserve the existing zero-flow timeout behavior.

Use a small exact-goal-cell epsilon, for example:

```gdscript
cost <= 0.001
```

This is valid because route cost `0.0` specifically identifies the native goal cell.

Do not use the arrival radius in this comparison.

## Prevent overshoot

When direct final steering is active, do not move farther than the remaining distance to the goal.

Use a clamped movement amount:

```gdscript
var distance_to_goal: float = _world_position.distance_to(_goal_world)
var actual_step: float = minf(step_distance, distance_to_goal)
_world_position += direction * actual_step
```

The existing world-distance arrival check should then recycle the runner when it reaches the configured pixel radius.

The star should visibly reach the actual selected garden-entry tile instead of disappearing at the beginning of the goal tile.

## Preserve real zero-flow failure handling

A zero direction outside the goal cell can still indicate:

* an invalid field;
* an isolated cell;
* a transient sampling issue.

Keep `_zero_flow_seconds` and `_max_zero_flow_seconds` for those cases.

Do not globally convert all zero-flow states into direct movement toward the goal, because that would let the preview visually cross walls or bypass invalid navigation.

Only use direct goal steering when the native route cost confirms:

```text
current cell is the goal cell
```

---

# Required change 4: remove the misleading garden exit overlay

Relevant files:

```text
scripts/map/building_debug_query_service.gd
scripts/map/plant_zone_overlay.gd
scripts/map/building_manager.gd
```

The current debug overlay exposes:

```gdscript
get_garden_enter_tiles()
get_garden_exit_tiles()
```

and draws:

```text
yellow = enter
green  = exit
```

The green exit marker is misleading because runtime monsters do not use that selected border cell when escaping.

## Required debug behavior

When “show enters/exits” debug display is enabled:

* continue showing the actual selected inbound garden entry;
* stop calculating and drawing the hypothetical garden exit;
* do not show a green exit tile.

The debug display should clearly represent:

```text
selected inbound garden entry for each relevant spawner/garden pair
```

not an unused theoretical egress point.

## Naming cleanup

Because only entries remain, clean up misleading names where safe.

Preferred direction:

```gdscript
get_garden_enter_tiles()
```

may remain as a compatibility wrapper if scene or dynamic usage is uncertain.

The overlay comment should be updated from:

```text
Enter / exit garden border tiles
```

to something accurate, such as:

```text
Selected inbound garden-entry tiles
```

Remove:

```gdscript
EXIT_COLOR
get_garden_exit_tiles()
```

only if search proves they are not dynamically referenced.

If `BuildingManager.get_garden_exit_tiles()` may be externally referenced, retain it as a compatibility wrapper temporarily but stop calling it from the overlay. Mention this in the final report.

Do not remove:

```gdscript
GardenAccessResolver.nearest_garden_entry_to_exit()
```

unless repository-wide search proves it has no runtime or dynamic users.

This task is not a broad cleanup of garden-access scoring.

## Spawner filtering

The debug entrance overlay currently iterates all registered spawners.

Do not redesign this unless necessary.

The critical requirement is that the debug marker displayed as an entrance corresponds to the same resolver used by the remaining inbound PathPreview:

```gdscript
nearest_garden_entry(garden_id, spawner_cell)
```

The PathPreview itself must continue selecting through:

```gdscript
select_garden_entry_for_preview(spawner_cell, preview_kind)
```

---

# Required change 5: keep lazy flow-field scheduling

The current controller submits preview flow work through:

```gdscript
_manager.request_group_flow_rebuild_with_policy(...)
```

This delegates to:

```text
SpawnerRouteService.request_group_flow_rebuild_with_policy()
```

which queues requests in:

```gdscript
_flow_request_queue
```

and drains them through:

```gdscript
process_queued_flow_requests()
```

Preserve this lazy scheduling.

Do not replace it with a synchronous call to:

```gdscript
assign_flow_to_group()
```

Do not call the native async request directly from PathPreview.

Removing the outbound leg should halve the number of preview flow groups and reduce planting-time preview work.

One inbound preview request per active spawner is sufficient.

---

# No-garden behavior

Preserve:

```text
no garden = no PathPreview
```

When the garden count is zero:

* no preview flow groups;
* no queued preview jobs;
* no star runners;
* no direct spawner-to-despawner fallback;
* no warning;
* no routine log.

When the first valid garden appears, enqueue only the inbound route.

---

# Logging

PathPreview should remain silent during expected gameplay.

Do not add logs for:

* no garden;
* runner arrival;
* goal-cell final steering;
* route allocation;
* lazy waiting;
* route replacement;
* zero-flow timeout;
* runner recycling.

Retain restrained warnings only for actual invalid configuration, such as failure to allocate a preview group or an invalid goal cell.

---

# Do not change

Do not modify:

* native C++ route-cost units;
* actual monster entry navigation;
* actual monster escape navigation;
* garden topology generation;
* plant-zone margin size;
* selected garden scoring;
* client target selection;
* camera transforms;
* star rendering coordinates;
* map cell/world conversion;
* wall invalidation;
* the lazy FF scheduler architecture.

Do not add a visual offset or camera correction.

The observed premature stop is not a parallax problem.

---

# Manual validation

The user will test manually.

## Test A — No garden

During day 1 afternoon before planting:

* no red star;
* no queued preview group;
* no console spam.

## Test B — First garden

Plant the first rose:

* one inbound flow request is queued per active monster spawner;
* no outbound group is allocated;
* no noticeable synchronous hitch from an additional outbound field.

## Test C — Early-stop regression

For a garden far from its spawner:

* star follows the full route;
* star does not disappear 12 tiles before the entry;
* star enters the actual selected garden-entry tile;
* star reaches close to the tile center before recycling.

## Test D — Goal cell

Observe the final section:

* runner does not freeze at the edge of the goal tile;
* runner moves directly to `goal_world` only after reaching the native goal cell;
* it does not cross obstacles to shortcut the route.

## Test E — Debug overlay

With garden debug entry display enabled:

* selected inbound entries are shown;
* no green hypothetical garden-exit tiles are shown;
* entry markers correspond to the goals reached by the red stars.

## Test F — Actual monster navigation

At night:

* monsters still follow their runtime flow to the garden;
* monsters switch to internal garden targeting normally;
* after eating, monsters still use the existing direct escape FF;
* no runtime escape behavior was removed with the visual outbound preview.

## Test G — Multiple spawners

With two active spawners:

* exactly two inbound preview groups;
* each spawner targets its selected garden entry;
* no duplicate outbound stars;
* each star reaches its own selected entry.

---

# Final report

Report:

1. Exact files changed.
2. Confirmation that route cost was incorrectly compared with a pixel radius.
3. Confirmation that the `cost <= arrival_radius` condition was removed.
4. How zero native flow inside the goal cell is now finalized toward `goal_world`.
5. Confirmation that direct final steering is allowed only at route cost zero.
6. Confirmation that outbound preview computation and rendering were removed.
7. Confirmation that the green hypothetical garden-exit overlay was removed or disabled.
8. Any compatibility wrapper retained and why.
9. Confirmation that lazy preview flow scheduling was preserved.
10. Confirmation that runtime monster entry and escape navigation were untouched.
11. Confirmation that Godot/tests/builds were not run.

Do not claim runtime success. State the manual validation cases required.
