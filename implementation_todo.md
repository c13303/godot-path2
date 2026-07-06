# Task: Let `AstarIn` agents cut through a `FlowIn` crowd

## Goal (behavior, not mechanism)
Agents that have committed to a garden and are pathing to their plant (phase `AstarIn`)
must be able to push their way through the milling crowd of agents still riding the flow
field toward gardens (phase `FlowIn`). Today an `AstarIn` agent gets jostled off its A*
line by the surrounding flow crowd and stalls. After this change:

- An `AstarIn` agent holds its A* line and makes headway through a dense `FlowIn` crowd.
- `FlowIn` agents visibly step aside for an `AstarIn` agent crossing them.
- All other pairings (AstarIn↔AstarIn, FlowIn↔FlowIn, and every other phase combination)
  behave exactly as they do today. The rule is asymmetric and must degrade gracefully.

This is a crowd-steering feel change only. Do NOT touch pathfinding, flow-field
generation, garden assignment, or the eating/exit phases.

## Where to work
`extensions/flowfield/steering/steering_system.cpp`, function
`SteeringSystem::force_voisine(const AgentData &agent)` (~line 596). This function computes
the crowd-separation force applied to `agent` from its neighbors.

## Why this is the right lever (read before editing)
Inside the neighbor loop, each neighbor's `weight` is scaled by `yield_multiplier`
(~lines 667-670). That multiplier is the correct hook because it feeds BOTH:
- the per-neighbor `weight` (which direction the agent escapes), AND
- `priority_scale_sum` → `priority_scale`, which is the ONLY factor that scales the final
  separation-force **magnitude** (~lines 682-683, after `safe_normalize`).

Do NOT try to key this off `crowd_push_strength`: that term is normalized out of the
magnitude and only affects direction blend — it will not make an agent "push harder."

## The rule to implement
Add a phase-based bias to `yield_multiplier`, applied alongside the existing
velocity-alignment (`priority_delta`) bias, inside the loop:

- self (`agent`) is `AstarIn` and neighbor `n` is `FlowIn`
    → LOWER yield_multiplier (AstarIn's separation shrinks → it barges through, keeps its line).
- self is `FlowIn` and neighbor `n` is `AstarIn`
    → RAISE yield_multiplier (the flow agent yields / steps aside).
- any other pairing → no phase adjustment (leave as today).

Agent phase is on `AgentData` as `agent.phase` / `n.phase`
(`AgentPhase::AstarIn`, `AgentPhase::FlowIn`; see `agent.h`).

## Decisions to honor
1. Config-gated, matching the existing tunable style in
   `extensions/flowfield/core/global_config.h` (near `priority_separation_bias = 0.30`,
   `separation_strength = 600.0`, ~lines 76-79). Add ONE new tunable, e.g.
   `astar_flow_yield_bias` (default 0.0 so behavior is unchanged until tuned), and expose it
   through the native config binding the same way the neighbors of `priority_separation_bias`
   are exposed (`extensions/flowfield/godot/global_config_native.*`). Follow the existing
   getter/setter + property-registration pattern exactly; don't invent a new mechanism.
2. Clamp: keep the existing `[0.65, 1.35]` clamp on `yield_multiplier` for the first pass.
   Only widen it (or exempt this phase pair) if manual testing shows AstarIn still bogs down
   in a thick crowd — and if so, do it as a clearly separated, commented follow-up, not
   silently.

## Constraints
- Match surrounding C++ style (naming, brace placement, comment density) in this file.
- No allocations or grid queries added to the hot loop; this is a couple of comparisons and
  a multiply per neighbor.
- Keep the change minimal and self-contained to `force_voisine` + the one config tunable.
- Preserve the existing velocity-alignment yield behavior; the phase bias is ADDITIVE to it,
  not a replacement.

## Build & verify
- Rebuild the flowfield GDExtension (same toolchain/command the project already uses for
  `extensions/flowfield`; check for an existing build script before inventing one).
- Sanity: with `astar_flow_yield_bias = 0.0`, behavior must be byte-for-byte the same feel as
  before (regression guard).
- Then set it to a small positive value and confirm in-game: spawn a dense flow crowd near a
  garden mouth and watch an AstarIn agent thread through to its plant instead of stalling.
  Confirm two AstarIn agents meeting still separate normally.

## Out of scope
Fences/walls (separate systems), static-obstacle repulsion, smash/knockback, priority tuning
for other phases, and any GDScript gameplay logic beyond wiring the one config value.
