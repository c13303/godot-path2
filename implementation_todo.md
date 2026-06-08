You are working on the current Godot + C++ GDExtension codebase.

Goal:
Improve crowd physicality while preserving bottleneck/door traversal.

User intent:
- Agents must visibly push / bounce against each other in bottlenecks.
- Agents must not look like they pass through each other.
- Bottlenecks must remain enabled because they are required for agents to pass through doors.
- Incoming / forward-progressing agents should be stronger than blocked / sideways / hesitating agents.
- This priority can apply globally, not only in bottlenecks.

Important:
Do not compile.
Do not run tests.
Do not remove bottlenecks.
Do not disable flowfields.
Do not add hard dynamic overlap depenetration for now.
Do not register turrets/buildings/static obstacles as agents.
Do not make blocking_buildings affect FF / A* / wall topology.
Keep C++ generic and reusable.
No game-specific terms like turret, plant, monster, building inside generic C++ logic.

Current issue:
In bottleneck areas, agent-agent separation is too suppressed:
- backward separation is currently removed or nearly removed
- lateral separation is capped too low
- agents can visually overlap/compress
- disabling bottlenecks is not acceptable because door traversal breaks

Desired behavior:
Inside bottlenecks:
- agents still follow the bottleneck/flow direction
- agents keep moving through doors
- agents visibly push sideways against each other
- agents may have a small backward bump
- agents should not bounce face-to-face forever
- forward-moving agents should win over agents that are stopped, sideways, or blocking

Outside bottlenecks:
- agent-agent push should remain normal
- forward-progressing agents can still have slight priority if the implementation is clean and generic

Task 1 — keep pure separation explicit:
In SteeringSystem, keep these concepts separate:

Vec2 agent_separation = force_voisine(a);
Vec2 static_obstacle_repel = static_obstacle_repulsion_force(a);
Vec2 local_avoidance = agent_separation + static_obstacle_repel;

Do not use misleading code like:

Vec2 separation = local_avoidance_force(a);

because separation must mean moving-agent-to-moving-agent separation only.

Debug:
- debug_separation must represent agent_separation only
- static obstacle force must not pollute crowd separation debug
- wall-stuck logic must use pure agent_separation when relevant

Task 2 — expose bottleneck separation tuning:
Replace hardcoded bottleneck suppression values in desired_velocity_for_flow() with config values.

Current logic likely has something like:
- negative forward correction clamped to 0
- lateral correction capped at flow_weight * 0.6

Add generic config fields:

double bottleneck_backward_push_ratio = 0.15;
double bottleneck_lateral_push_ratio = 1.0;

Use them like:

double min_forward = -cfg.flow_weight * cfg.bottleneck_backward_push_ratio;
if (forward < min_forward)
    forward = min_forward;

double max_lateral = cfg.flow_weight * cfg.bottleneck_lateral_push_ratio;

Expected defaults:
- bottleneck_backward_push_ratio = 0.15
- bottleneck_lateral_push_ratio = 1.0

Meaning:
- agents can recoil slightly backward in bottlenecks
- sideways spacing is much more visible
- flow still wins overall

Do not fully restore unlimited backward separation inside bottlenecks.
That risks door deadlocks.

Task 3 — add soft movement priority bias:
Add generic movement-priority weighting to agent-agent separation.

Do not implement as raw stronger force for “incoming agents”.
Implement as:

- agents aligned with their intended movement direction yield less
- stopped / sideways / badly aligned agents yield more

Generic naming only:
Good names:
- movement_priority
- intent_alignment
- priority_separation_bias
- flow_alignment_priority

Bad names:
- incoming_monster_strength
- turret_priority
- garden_push
- plant_attack_priority

Suggested config:

double priority_separation_bias = 0.30;

Default:
- priority_separation_bias = 0.30

Task 4 — define movement priority generically:
For each moving agent, compute a priority value in 0..1.

Preferred:
Use the agent’s current desired movement direction / nav direction if available.

Fallback:
Use current velocity direction.

Suggested concept:

priority = dot(normalized_velocity_or_intent, normalized_desired_or_nav_dir)
priority = clamp(priority, 0.0, 1.0)

Interpretation:
- 1.0 = agent is moving clearly toward intended direction
- 0.0 = agent is stopped, sideways, or moving against intent

If the code already has nav_dir / desired direction in the update branch, store the current agent movement intent in AgentData before calling force_voisine(), or pass it cleanly.

Do not make force_voisine depend on game-specific state.

Task 5 — apply priority inside force_voisine:
When computing separation between current agent and neighbor:

- compute normal separation force as before
- compare self_priority and neighbor_priority
- if self_priority > neighbor_priority:
    current agent should be less pushed backward by that neighbor
- if self_priority < neighbor_priority:
    current agent should yield more
- keep the effect soft, bounded, and stable

Suggested soft multiplier:

double delta = self_priority - neighbor_priority;
double bias = cfg.priority_separation_bias;

double yield_multiplier = 1.0 - delta * bias;
yield_multiplier = clamp(yield_multiplier, 0.65, 1.35);

force += base_separation * yield_multiplier;

This means:
- high-priority moving agents are less disturbed
- low-priority blocking agents receive stronger separation during their own update
- no one becomes an unstoppable bulldozer

Alternative implementation is acceptable if it preserves the same behavior:
- priority affects only backward/opposing separation
- lateral spacing remains strong
- effect is bounded

Task 6 — bottleneck-specific projection:
Inside bottleneck areas, keep the existing projection of correction into:

- forward part along nav direction
- lateral part perpendicular to nav direction

But update it:

- allow limited negative forward correction using bottleneck_backward_push_ratio
- allow stronger lateral correction using bottleneck_lateral_push_ratio
- preserve flow direction priority

Expected bottleneck visual result:
- agents shoulder-check each other
- agents spread laterally more
- agents recoil slightly when compressed
- crowd still moves through the door
- no symmetrical face-to-face deadlock

Task 7 — expose tuning in Godot debug/options:
Expose the new generic tuning values through the existing options bridge, probably cpp_debug_options.gd or the native debug/options node.

Add exposed properties near existing bottleneck / movement options:

- Bottleneck Backward Push Ratio
  default 0.15

- Bottleneck Lateral Push Ratio
  default 1.0

- Priority Separation Bias
  default 0.30

If the project uses snake_case exported names:

@export var bottleneck_backward_push_ratio: float = 0.15
@export var bottleneck_lateral_push_ratio: float = 1.0
@export var priority_separation_bias: float = 0.30

Wire them to C++ config cleanly.

Important:
These are movement tuning options, not debug draw options.
Do not gate them behind debug_enabled.

Task 8 — preserve static obstacle/turret behavior:
Do not touch the static obstacle architecture except if needed to keep variable names clean.

Static obstacles:
- remain generic
- remain separate from agents
- remain ignored by FF / A*
- remain local steering blockers only

blocking_buildings:
- still ignored by flowfields
- still ignored by wall signatures
- still no FF rebuild on add/remove

Task 9 — no hard dynamic resolver:
Do not re-add hard dynamic agent overlap resolver in this task.

Reason:
We want visible soft bounce/pressure first.
Hard depenetration can create jitter, shove chains, and frame-order artifacts in bottlenecks.

Acceptance criteria:
- Bottlenecks remain enabled and functional.
- Agents still pass through doors.
- Agents visibly push/bounce against each other inside bottlenecks.
- Agents look less ghost-like / less overlapping in door crowds.
- Small backward recoil is visible but does not cause endless face-to-face bouncing.
- Sideways spacing in bottlenecks is stronger than before.
- Forward-progressing agents keep momentum better than stopped/sideways agents.
- Blocked or hesitating agents yield more.
- Existing monster flowfield movement still works.
- Existing A* movement still works.
- Player/turret static obstacle behavior remains unchanged.
- turret1/static obstacles are still not agents.
- blocking_buildings still do not affect FF / A* / wall topology.
- No hard dynamic overlap depenetration is added.
- New tuning values are exposed and not gated by debug_enabled.

Suggested starting values for human tuning:
- bottleneck_backward_push_ratio = 0.15
- bottleneck_lateral_push_ratio = 1.0
- priority_separation_bias = 0.30

Tuning notes:
If agents still look ghost-like:
- increase bottleneck_lateral_push_ratio first

If doors jam:
- reduce bottleneck_backward_push_ratio

If agents bulldoze too much:
- reduce priority_separation_bias

If traffic face-blocks:
- slightly increase priority_separation_bias, but stay below 0.45