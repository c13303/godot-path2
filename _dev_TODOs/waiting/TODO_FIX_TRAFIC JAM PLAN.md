# Task: generic traffic right-of-way with physical jam breaking — revised for the current codebase

## Working rules

For every task: do not guess. Ask if unsure.

Use dedicated ownership for files and systems.

Prefer simple, readable, production-oriented code.

The goal is not maximum abstraction. The goal is code that is easy to understand, easy to modify, hard to break, and unlikely to grow into huge tangled files.

Priorities:

1. Clean, production-ready and optimized code.
2. The C++ add-on must remain maximally generic.
3. Game-specific agent types, garden phases and route policies may remain in GDScript.
4. Do not overengineer.
5. Traffic can look messy. The essential requirement is that conflicting crowds eventually dissolve instead of remaining permanently jammed.

Do not run:

* Godot;
* tests;
* compilation;
* SCons;
* exports;
* build commands.

The user performs runtime testing manually.

Do not modify generated or compiled files:

* `.o`
* `.dll`
* `.a`
* `.lib`
* `.exp`
* temporary DLL copies

Use explicit GDScript types. Avoid unsafe `:=` inference for dynamic values, calls, dictionaries, arrays, nullable values or mixed numeric expressions.

Before editing, inspect the named files and verify that the current implementation still matches this prompt. Ask before proceeding if an important method, state transition or ownership boundary differs materially.

## Current-codebase constraints already verified

The current codebase has several navigation paths that must be covered explicitly:

* normal A* entry calls `AgentNavigationPhaseController.start_astar_in()`;
* local garden retarget assigns a path directly, then calls `AgentNavigationPhaseController.set_astar_in_agent()`;
* temporary suspension recovery can restore a path directly, then calls the same `set_astar_in_agent()` registration method;
* `AgentSuspendService` directly detaches and restores entry-flow, A*, escape and captured-agent navigation;
* native lazy-flow freezing applies both to agents stamped with `waiting_flow_group` and to already-attached flow agents whose group is queued or computing;
* the native smash implementation has one mutable pending impulse slot.

The implementation must cover all of these paths. Do not assume that every A* transition passes through `start_astar_in()` or that every navigation detach/restore is owned only by `AgentNavigationPhaseController`.

---

# Problem

Large monster crowds can form permanent traffic jams when different navigation streams meet around gardens.

Typical conflicts include:

```text
Spawner 1 -> Garden A
Spawner 2 -> Garden A
agents following different A* paths inside Garden A
Garden A -> exit
```

The existing soft steering system is not reliable enough to make one stream yield to another.

A previous attempt to create a player bulldozer by tuning steering and neighbour forces failed.

The existing smash/contact propulsion system did work.

Therefore, implement traffic right-of-way as a separate physical-contact arbitration layer using the existing smash propulsion pipeline.

Do not attempt to solve this by retuning general steering.

---

# Desired result

When two agents from conflicting traffic streams overlap:

1. Their traffic priorities are compared.
2. The higher-priority agent continues its existing navigation normally.
3. The lower-priority agent receives a short, non-damaging physical shove.
4. The lower-priority agent keeps its existing path or flow assignment.
5. After being displaced, it automatically continues navigating.
6. Repeated contacts may look chaotic, but the conflict must progressively clear.

The traffic system must not attempt to make crowds perfectly smooth.

Visible shoving, displacement and local disorder are acceptable.

Permanent symmetric deadlocks are not acceptable.

---

# Critical non-goals

Do not implement:

* a steering-system rewrite;
* changes to `force_voisine()`;
* changes to `movement_priority()`;
* new crowd-force tuning;
* target reservation;
* rose reservation;
* garden admission limits;
* traffic lights;
* fairness timers;
* rotating stream priority;
* starvation prevention;
* congestion prediction;
* global traffic graph analysis;
* path recomputation;
* flow-field recomputation;
* A* recomputation;
* special duck or monster logic in C++;
* damage from traffic contact.

This task is a deliberately simple static hierarchy with physical enforcement.

---

# Generic native model

The C++ extension must not know about:

* monsters;
* ducks;
* clients;
* merchants;
* gardens;
* roses;
* spawners;
* inbound routes;
* outbound routes;
* eating;
* game-specific agent kinds.

The native system only receives two opaque values per agent:

```cpp
int64_t traffic_group_id = 0;
int traffic_priority = 0;
```

Meaning:

```text
traffic_group_id == 0:
    traffic arbitration disabled for this agent

same non-zero traffic_group_id:
    same traffic stream; no traffic shove between them

different non-zero traffic_group_id:
    potentially conflicting traffic streams

higher traffic_priority:
    has right of way

equal traffic_priority:
    lower traffic_group_id has right of way
```

The group ID is only an opaque identity and deterministic tie-breaker.

The priority is only an opaque ordering value.

C++ must not interpret either value as a phase, route, spawner or gameplay type.

---

# Game-side hierarchy

GDScript owns the current game-specific traffic policy.

Use these initial priorities:

```gdscript
const TRAFFIC_PRIORITY_NONE: int = 0
const TRAFFIC_PRIORITY_INBOUND: int = 100
const TRAFFIC_PRIORITY_ASTAR_INSIDE: int = 200
const TRAFFIC_PRIORITY_OUTBOUND: int = 300
```

Therefore:

```text
outbound traffic
    beats A* traffic inside gardens

A* traffic inside gardens
    beats inbound traffic approaching gardens

inbound traffic
    has the lowest active priority
```

Within the same priority, lower traffic group ID wins deterministically.

There is deliberately no fairness rotation in this task.

Waves are finite. A lower-priority stream may temporarily suffer significant displacement.

---

# Game-side traffic group IDs

Use `int` in GDScript, which maps to a 64-bit integer.

Keep the game-side namespaces clearly separated:

```gdscript
const TRAFFIC_GROUP_INBOUND_BASE: int = 1_000_000_000_000
const TRAFFIC_GROUP_ASTAR_BASE: int = 2_000_000_000_000
const TRAFFIC_GROUP_OUTBOUND_BASE: int = 3_000_000_000_000
```

## Inbound flow

For an agent attached to a garden-entry flow:

```gdscript
traffic_group_id = TRAFFIC_GROUP_INBOUND_BASE + plant_group
traffic_priority = TRAFFIC_PRIORITY_INBOUND
```

Agents following the same `plant_group` are one stream and do not traffic-shove each other.

Different spawner/garden route groups compete deterministically.

## A* inside a garden

For an agent following its individual A* path toward a plant:

```gdscript
traffic_group_id = TRAFFIC_GROUP_ASTAR_BASE + nav_id
traffic_priority = TRAFFIC_PRIORITY_ASTAR_INSIDE
```

Use one traffic group per A* agent in this first implementation.

This is intentional.

There is currently no exclusive plant reservation system. Keeping the inbound route group through A* would allow agents from the same spawner route, but travelling in opposite directions toward different plants, to remain mutually deadlocked.

Using `nav_id` gives A* agents a deterministic total hierarchy and ensures that internal garden conflicts can be physically broken.

Do not create a target-cell registry or target reservation system in this task.

## Outbound flow

For an agent attached to an escape flow:

```gdscript
traffic_group_id = TRAFFIC_GROUP_OUTBOUND_BASE + escape_group
traffic_priority = TRAFFIC_PRIORITY_OUTBOUND
```

Agents using the same escape group are one stream.

Different outbound route groups compete deterministically.

## Disabled state

Use:

```gdscript
traffic_group_id = 0
traffic_priority = 0
```

for agents that must not participate.

---

# Current game-side participation rule

For this task, enable stream traffic only for:

```gdscript
_agent_kind(agent) == &"monster"
```

Disable it for:

* player;
* clients;
* merchants;
* sheep;
* hostile/tantrum clients;
* other agent kinds.

Keep this check centralized in one helper.

For example:

```gdscript
func _agent_uses_stream_traffic(agent: Node2D) -> bool:
    return _agent_kind(agent) == SPAWNER_KIND_MONSTER
```

It is acceptable that adding a future type such as `&"duck"` requires changing this one GDScript helper.

Adding ducks must not require modifications to:

* `TrafficRightOfWayResolver`;
* `SteeringSystem` traffic logic;
* `AgentManagerNative`;
* the generic native traffic state;
* native impulse arbitration.

Do not build an abstract capability/resource system merely for future ducks in this task.

---

# Native state

Modify:

```text
extensions/flowfield/steering/agent.h
```

Add to `AgentData`:

```cpp
std::int64_t traffic_group_id = 0;
int traffic_priority = 0;
int pending_smash_priority = 0;
```

Include `<cstdint>` where appropriate.

Traffic state is runtime-derived and must not be serialized.

## Pending-smash consistency requirement

The current code has one pending smash slot composed of:

```cpp
pending_smash
smash_pending
smash_delay
pending_smash_friction
pending_smash_control_suppression
pending_smash_control_suppression_duration
pending_smash_priority
```

These fields must remain one coherent state.

Use this invariant:

```text
smash_pending == false:
    pending_smash_priority == ImpulseQueuePriority::None

smash_pending == true:
    pending_smash_priority identifies the source currently stored in the pending slot
```

In `AgentData::reset()`, reset the traffic fields and clear the complete pending-smash slot together. Do not reset only `pending_smash_priority` while leaving a pending impulse alive.

Also reset `pending_smash_priority` to `None` everywhere the current pending slot is cleared, applied or cancelled, including:

* `set_agent_position(..., clear_velocity = true)`;
* `set_agent_phase(..., AgentPhase::Drowning, ...)`;
* drowning cancellation in `SteeringSystem::update_all()`;
* the branch that applies a pending smash;
* `AgentData::reset()`;
* any other existing explicit pending-smash cancellation found during inspection.

Do not change public smash signatures.

---

# Generic native traffic setter

Add to `SteeringSystem`:

```cpp
void set_agent_traffic_state(
    int agent_id,
    std::int64_t traffic_group_id,
    int traffic_priority);
```

Rules:

```text
traffic_group_id <= 0:
    store group 0 and priority 0

traffic_group_id > 0:
    store the group
    clamp priority to >= 0
```

The setter must not modify:

* flow pointer;
* route group;
* waiting flow group;
* path;
* velocity;
* active state;
* phase;
* smash state.

Expose it through `AgentManagerNative`:

```cpp
void set_agent_traffic_state(
    int agent_id,
    std::int64_t traffic_group_id,
    int traffic_priority);
```

Bind it to Godot as:

```text
set_agent_traffic_state(agent_id, traffic_group_id, traffic_priority)
```

Files:

```text
extensions/flowfield/steering/steering_system.h
extensions/flowfield/steering/steering_system.cpp
extensions/flowfield/godot/agent_manager_native.h
extensions/flowfield/godot/agent_manager_native.cpp
```

---

# Dedicated native ownership

Create:

```text
extensions/flowfield/steering/traffic_right_of_way_resolver.h
extensions/flowfield/steering/traffic_right_of_way_resolver.cpp
```

The SCons script recursively includes `.cpp` files, so do not manually maintain a source list unless the current build file has changed.

The new resolver owns:

* traffic-contact candidate detection;
* comparison of opaque traffic priorities and group IDs;
* deterministic winner selection;
* one traffic shove candidate per target;
* per-target traffic cooldowns;
* removal of cooldown state on unregistration.

It does not own:

* navigation assignment;
* flow fields;
* paths;
* group-flow loading state;
* agent gameplay phases;
* damage;
* Godot bindings;
* game-specific traffic policy;
* general steering;
* normal contact-push profiles;
* smash movement integration.

`SteeringSystem` remains responsible for determining the current generic lazy-flow-wait state because that information comes from `AgentManager` group state. Supply that state to the resolver through a narrow, allocation-safe mechanism.

Do not place the full traffic algorithm directly in the already-large `steering_system.cpp`.

---

# Suggested native API

A narrow API equivalent to this is appropriate:

```cpp
struct TrafficPushRequest
{
    int target_agent_id = -1;
    Vec2 direction{};
    double force = 0.0;
};

class TrafficRightOfWayResolver
{
public:
    void update_cooldowns(double delta);
    void remove_agent(int agent_id);

    void collect_push_requests(
        const std::vector<AgentData> &agents,
        const std::unordered_map<int, int> &id_to_index,
        SpatialGrid *grid,
        const std::vector<std::uint8_t> &flow_waiting_by_agent_index,
        double max_world_radius,
        double base_push_force,
        std::vector<TrafficPushRequest> &out_requests);

    void mark_target_pushed(int agent_id, double cooldown_seconds);

private:
    std::unordered_map<int, double> cooldown_by_target_agent;
};
```

Exact private helper names may differ.

`SteeringSystem` should own reusable scratch storage for `flow_waiting_by_agent_index`; resize/reuse it rather than allocating a new container for every pair or query.

Add a generic helper equivalent to:

```cpp
bool is_agent_waiting_for_flow(const AgentData &agent) const;
```

It must reproduce the current native freeze rule:

```text
wait_group = waiting_flow_group when present, otherwise current group

flow-driven =
    waiting_flow_group is present
    OR
    no active path and phase is FlowIn or FlowOut

waiting =
    flow-driven
    AND valid wait group
    AND AgentManager reports GROUP_FLOW_WAIT_QUEUED or GROUP_FLOW_WAIT_COMPUTING
```

Use this same helper for:

* the existing movement freeze branch;
* filling the resolver’s flow-waiting mask.

Do not maintain two subtly different lazy-flow-wait predicates.

An equivalent no-allocation callback design is acceptable, but do not perform dynamic allocation or `std::function` construction inside the neighbour-pair loop.

Keep the resolver public responsibility narrow.

---

# Eligible traffic contacts

A pair is eligible only when:

* both agent IDs still exist;
* both `traffic_group_id` values are positive;
* their traffic group IDs differ;
* both have a positive world radius;
* their world-radius circles overlap;
* neither is drowning;
* neither is paused;
* neither is already being propelled;
* neither has a pending smash;
* neither is currently waiting for a lazy flow field;
* both are active;
* the winning agent has a meaningful navigation intent.

The lazy-flow-wait exclusion must cover both current native cases:

1. a spawned agent stamped with `waiting_flow_group` while it has not yet joined the route group;
2. an already-attached `FlowIn` or `FlowOut` agent whose current group flow is queued or computing.

A frozen flow-waiting agent must neither shove nor be selected as the winner. It may be displaced only by existing non-traffic systems if those systems already permit it.

Do not require the losing agent to currently move toward the winner. A stationary lower-priority blocker must still be movable.

Process each unordered pair once:

```cpp
agent.id < neighbor.id
```

Use the existing `SpatialGrid`.

Do not introduce an all-agents-against-all-agents loop.

---

# Selecting the winner

For different traffic groups:

```text
higher traffic_priority wins
```

If priorities are equal:

```text
lower traffic_group_id wins
```

If the traffic group IDs are equal:

```text
no traffic push
```

If all ordering values are equal due to invalid duplicate state:

```text
no traffic push
```

Do not use force differences or body strength to determine traffic hierarchy.

Existing `smash_resist` still determines how much the loser is physically displaced.

---

# Winner movement intent

A high-priority agent must not shove another stream merely because it is standing nearby.

Resolve its intended direction in this order:

```text
debug_desired_dir
debug_nav_dir
velocity
```

Use the first non-zero normalized vector.

If all are zero, skip the pair.

Also require that the winning agent still has meaningful navigation ownership, such as:

```text
flow != nullptr
or
path_active
```

Do not allow an agent with no flow and no active path to become a traffic bulldozer because of stale debug direction.

The debug direction may come from the previous native frame. That is acceptable.

---

# Forward-contact check

Compute:

```text
winner_to_loser = normalize(loser_foot - winner_foot)
```

Only permit a shove when the loser is broadly in front of or beside the winner:

```cpp
winner_intent.dot(winner_to_loser) >= -0.10
```

Use a named local constant.

The slightly negative threshold is intentional:

* head-on blockers are pushed;
* crossing agents near the winner’s side may be pushed;
* agents clearly behind the winner are not pushed.

Do not add this threshold to global configuration unless the current architecture strongly requires it.

---

# Foot positions and overlap

Use the same foot-point convention as the steering code:

```cpp
agent.position + Vec2(0, agent.profile.foot_offset_y)
```

Compute:

```text
sum_radius = winner.world_radius + loser.world_radius
overlap = sum_radius - distance
```

Skip when:

```text
overlap <= 0
```

Push direction:

```text
normalize(loser_foot - winner_foot)
```

If the two foot points are identical, use a deterministic direction derived from both agent IDs.

Do not use runtime randomness.

---

# Push force

Add focused configuration to:

```text
extensions/flowfield/core/global_config.h
```

Defaults:

```cpp
bool traffic_right_of_way_enabled = true;
double traffic_push_force = 216.0;
double traffic_push_cooldown = 0.18;
double traffic_control_lock_seconds = 0.18;
```

Expose all four through:

```text
extensions/flowfield/godot/global_config_native.h
extensions/flowfield/godot/global_config_native.cpp
```

Godot property names:

```text
traffic_right_of_way_enabled
traffic_push_force
traffic_push_cooldown
traffic_control_lock_seconds
```

Sanitize:

```text
force >= 0
cooldown >= 0
control lock >= 0
```

Scale force by overlap:

```cpp
double overlap_ratio = std::clamp(overlap / sum_radius, 0.0, 1.0);
double force_scale = 0.5 + 0.5 * overlap_ratio;
double final_force = traffic_push_force * force_scale;
```

This produces between 50% and 100% of the configured traffic force.

Use the existing player contact-push value of `216.0` as the initial reference scale.

The initial control lock is deliberately `0.18` seconds, not `0.10`. The current update order can decrement a newly applied suppression timer during the same frame; a severe frame spike near 100 ms could otherwise consume a `0.10` lock before useful displacement occurs.

Do not alter the global propulsion implementation in this task.

Do not introduce more traffic tuning parameters in this pass.

---

# One shove per target per pass

A lower-priority agent may overlap several higher-priority agents.

Do not queue several traffic impulses onto the same target during one update.

For each target, retain only the best candidate.

Order candidates by:

1. highest winner `traffic_priority`;
2. lowest winner `traffic_group_id`;
3. deepest overlap;
4. lowest winner agent ID.

Produce at most one `TrafficPushRequest` per target.

Sort the final request list by `target_agent_id` before applying it so update order is deterministic.

---

# Traffic cooldown

Cooldown ownership belongs to `TrafficRightOfWayResolver`.

Track:

```cpp
std::unordered_map<int, double> cooldown_by_target_agent;
```

The key is the displaced target agent ID.

While its cooldown is active, that target cannot receive another traffic shove.

Cooldown is per target, not per pair.

This prevents rapid machine-gun shaking while still allowing repeated shoves until a jam clears.

Expired entries must be erased.

When an agent is unregistered:

```cpp
traffic_right_of_way_resolver.remove_agent(agent_id);
```

Do not create a permanent pair matrix.

---

# Generic pending-impulse arbitration

The current native smash queue has one mutable pending slot.

A traffic shove must never overwrite a stronger pending gameplay or contact impulse.

Implement minimal generic pending-impulse arbitration.

Add an internal enum or constants equivalent to:

```cpp
enum class ImpulseQueuePriority : int
{
    None = 0,
    Traffic = 10,
    Contact = 50,
    Gameplay = 100,
};
```

Use:

```text
Traffic:
    traffic right-of-way pushes

Contact:
    existing apply_contact_pushes()

Gameplay:
    public weapon, explosion, AoE and externally requested smash impulses
```

Change the private queue function to accept a queue priority:

```cpp
void queue_smash_impulse(
    int id,
    const Vec2 &direction,
    double force,
    double friction_loss,
    double delay,
    bool detach_flow,
    double control_suppression,
    double control_suppression_duration,
    bool respect_weapon_immune,
    int impulse_priority);
```

Behaviour:

```text
if a pending smash exists and the new priority is lower:
    reject the new impulse

if priorities are equal or the new one is higher:
    preserve the existing overwrite behaviour
```

Do not redesign smash accumulation.

Do not combine vectors.

Do not create an impulse queue container.

This is only a priority guard around the existing single pending slot.

Assign:

```text
apply_smash_impulse and every gameplay/AoE/explosion path:
    Gameplay

existing apply_contact_pushes:
    Contact

new traffic pushes:
    Traffic
```

Do not miss internal callers that eventually write to the same pending slot.

Whenever an accepted impulse overwrites the pending slot, update `pending_smash_priority` at the same time.

Whenever the pending slot is applied, cleared, reset or cancelled, reset `pending_smash_priority` to `None` at the same time.

Existing public Godot smash method signatures must remain unchanged.

---

# Why traffic needs a short control lock

The current navigation code cancels propulsion when:

* control suppression is no longer active;
* the propelled velocity opposes the navigation target velocity.

A traffic shove frequently moves an agent opposite its desired route.

Using zero control suppression can therefore cause navigation to cancel the traffic shove before it creates useful displacement.

For traffic pushes, call the existing smash queue with:

```text
friction loss:
    0.65

delay:
    0.0

detach flow:
    false

control suppression:
    1.0

control suppression duration:
    traffic_control_lock_seconds
    default 0.18 seconds

respect weapon immune:
    false

impulse queue priority:
    Traffic
```

The lock exists only to let the physical displacement occur. Navigation regains control automatically afterward.

Do not alter the global propulsion implementation.

Do not add a new movement mode.

---

# SteeringSystem integration

Add one member:

```cpp
TrafficRightOfWayResolver traffic_right_of_way_resolver;
```

Add reusable scratch state for the generic flow-wait mask and request list if this avoids per-frame allocations.

Add focused private methods equivalent to:

```cpp
bool is_agent_waiting_for_flow(const AgentData &agent) const;
void apply_traffic_right_of_way(double delta);
```

In `update_all()`, keep the passes close to the existing contact-push logic:

```cpp
update_contact_push_cooldowns(delta);
traffic_right_of_way_resolver.update_cooldowns(delta);

apply_contact_pushes(delta);
apply_traffic_right_of_way(delta);
```

Traffic runs after existing contact pushes.

Therefore:

* existing player/big-monster contact has first opportunity;
* targets with a pending contact push are skipped by traffic;
* impulse priority still protects against accidental overwrites.

Traffic resolution must happen before the pending-smash application loop.

Before collecting traffic candidates:

1. resolve the current `AgentManager` exactly as the existing lazy-flow freeze code does;
2. fill the reusable `flow_waiting_by_agent_index` mask through the shared helper;
3. pass that mask to the resolver.

Replace the existing inline lazy-flow freeze predicate with the same shared helper so movement freezing and traffic eligibility cannot diverge.

Do not integrate the traffic resolver into:

* `force_voisine()`;
* `movement_priority()`;
* flow steering;
* A* steering;
* bottleneck steering.

---

# Existing systems must remain unchanged

Do not remove or reinterpret:

```text
crowd_push_strength
crowd_resist_strength
contact_push_power
contact_push_resist
contact_push_cooldown
smash_resist
weapon_immune
```

Expected coexistence:

* player contact pushing remains unchanged;
* big-monster contact pushing remains unchanged;
* combat smash remains unchanged;
* explosions remain unchanged;
* AoE propulsion remains unchanged;
* traffic adds a lower-priority physical impulse source;
* existing `smash_resist` reduces traffic displacement naturally.

Do not add big-monster-specific branches to the traffic resolver.

---

# GDScript manager forwarding

In:

```text
scripts/map/building_manager.gd
```

Add only a thin native-forwarding wrapper:

```gdscript
func set_agent_traffic_state(nav_id: int, traffic_group_id: int, traffic_priority: int) -> void:
    if agent_manager != null and agent_manager.has_method("set_agent_traffic_state"):
        agent_manager.call(
            "set_agent_traffic_state",
            nav_id,
            traffic_group_id,
            traffic_priority
        )
```

Do not add:

* traffic dictionaries;
* cooldown state;
* route hierarchy state;
* traffic algorithms

to `BuildingManager`.

---

# GDScript phase ownership

Primary game-policy owner:

```text
scripts/map/agent_navigation_phase_controller.gd
```

This controller owns the game-specific traffic hierarchy and the public helper methods used by other navigation services.

Add:

```gdscript
const SPAWNER_KIND_MONSTER: StringName = &"monster"

const TRAFFIC_PRIORITY_NONE: int = 0
const TRAFFIC_PRIORITY_INBOUND: int = 100
const TRAFFIC_PRIORITY_ASTAR_INSIDE: int = 200
const TRAFFIC_PRIORITY_OUTBOUND: int = 300

const TRAFFIC_GROUP_INBOUND_BASE: int = 1_000_000_000_000
const TRAFFIC_GROUP_ASTAR_BASE: int = 2_000_000_000_000
const TRAFFIC_GROUP_OUTBOUND_BASE: int = 3_000_000_000_000
```

Add focused helpers equivalent to:

```gdscript
func _agent_uses_stream_traffic(agent: Node2D) -> bool

func set_inbound_traffic(
    agent: Node2D,
    plant_group: int
) -> void

func set_astar_inside_traffic(
    agent: Node2D,
    nav_id: int
) -> void

func set_outbound_traffic(
    agent: Node2D,
    escape_group: int
) -> void

func clear_agent_traffic(nav_id: int) -> void
```

The three assignment helpers must be callable by `AgentSuspendService`, so do not make them inaccessible private-only helpers unless a clean narrow forwarding method already exists.

For a non-participating agent, every assignment helper must resolve to:

```gdscript
_manager.set_agent_traffic_state(
    nav_id,
    0,
    TRAFFIC_PRIORITY_NONE
)
```

Do not store a game-side mirror dictionary of native traffic state.

The native agent state is the source of truth.

Secondary transition owner:

```text
scripts/map/agent_suspend_service.gd
```

`AgentSuspendService` already directly detaches and restores entry-flow, A*, escape and captured-agent navigation. It must therefore clear traffic while navigation is suspended and restore the correct traffic state only after navigation is restored.

Do not move suspension logic into `BuildingManager`.

---

# Required phase transitions

## Waiting for initial lazy entry flow

In:

```gdscript
assign_agent_to_garden_entry_flow()
```

when the route has a valid pending group but its flow is not ready:

* clear traffic state before or while stamping `waiting_flow_group`;
* keep the existing waiting-flow freeze and label behaviour;
* do not allow a frozen waiting agent to shove traffic.

## Entry flow attached

In:

```gdscript
_attach_agent_to_entry_route()
```

after validating the route and completing the native group assignment call for `plant_group`:

```text
group:
    TRAFFIC_GROUP_INBOUND_BASE + plant_group

priority:
    TRAFFIC_PRIORITY_INBOUND
```

Set only for participating agents.

The current native/GDScript assignment APIs return `void`; do not redesign them solely to manufacture a success return. Treat the assignment boundary as reached only after all route data has been validated and the native call has completed.

## Starting or restoring A* toward a plant

Assign A* traffic in:

```gdscript
AgentNavigationPhaseController.set_astar_in_agent(nav_id, data)
```

Do not assign it only in `start_astar_in()`.

This registration method is the current common path for:

* normal `start_astar_in()` assignment;
* `GardenRetargetController._try_local_retarget_agent()` direct local retarget;
* `AgentSuspendService` A* restoration.

After validating that `data["node"]` is a live `Node2D` and registering the A* record/target:

```text
group:
    TRAFFIC_GROUP_ASTAR_BASE + nav_id

priority:
    TRAFFIC_PRIORITY_ASTAR_INSIDE
```

Do not retain the inbound group through A*.

Do not derive the A* traffic group from the target cell.

Do not create target-cell traffic registries.

Using one group per A* agent is intentional for this first implementation. It can also cause occasional arbitration between nearby same-direction A* agents; this is accepted provisionally and must be covered by a manual regression test.

## Eating

In both:

```gdscript
start_agent_eating()
restore_agent_eating()
```

clear traffic state before or while detaching navigation.

An eating agent must not shove passing agents.

## Escape flow attached

In:

```gdscript
attach_agent_to_escape()
```

after validating the escape route and completing the native group assignment call for `escape_group`:

```text
group:
    TRAFFIC_GROUP_OUTBOUND_BASE + escape_group

priority:
    TRAFFIC_PRIORITY_OUTBOUND
```

Set only for participating agents.

A failed `assign_agent_to_escape()` or invalid escape route must not invent outbound traffic state.

## Retarget waiting

In:

```text
scripts/map/garden_retarget_controller.gd
queue_agent_for_garden_retarget()
```

after detaching path/flow and before entering `WaitingNewStatus`:

```gdscript
_agent_navigation_phases.clear_agent_traffic(nav_id)
```

A waiting agent must not retain stale right-of-way.

## Temporary suspension and capture

In:

```text
scripts/map/agent_suspend_service.gd
```

clear traffic state in all suspension entry points before or while navigation is detached:

```gdscript
suspend_agent_for_drowning()
suspend_agent_for_turret_eating()
suspend_agent_for_external_capture()
```

This is required even when the native phase changes to `Eating` or `Drowning`: native phase alone must not be relied on to clean game-side traffic assignment.

Restore traffic only after the corresponding navigation restoration has succeeded:

```text
_resume_agent_entry_flow() succeeds:
    restore inbound traffic from data["plant_group"]

_resume_agent_path() succeeds for kind == "astar":
    set_astar_in_agent() restores per-agent A* traffic centrally

kind == "escape":
    assign_agent_to_escape()/attach_agent_to_escape() restores outbound traffic centrally

client_counter or other non-participating path:
    traffic remains disabled
```

If restoration falls back to retarget/waiting status, traffic must remain cleared.

## Generic navigation cleanup

In:

```gdscript
AgentNavigationPhaseController.clear_agent_navigation_records()
```

also clear traffic state.

Native unregistration removes the agent and its resolver cooldown automatically, but explicit game-side navigation cleanup must still leave correct state.

---

# Failure-path correctness

Traffic state must never survive a transition where the associated navigation assignment failed or was suspended.

Ensure:

* waiting for an initial entry flow has no traffic state;
* an already-attached flow agent whose group is queued/computing is excluded natively from traffic arbitration;
* failed entry-route validation does not leave an old stream active;
* local retarget A* receives A* traffic through `set_astar_in_agent()`;
* resumed A* receives A* traffic through the same registration method;
* retarget waiting clears the stream;
* normal eating clears the stream;
* restored eating clears the stream;
* turret-eating suspension clears the stream;
* drowning suspension clears the stream;
* external capture clears the stream;
* failed suspension recovery leaves traffic disabled;
* native unregistration removes resolver cooldown state;
* a failed escape assignment does not invent an outbound stream.

Do not assign traffic state before the associated route/path data has been validated and the corresponding native assignment call has completed.

Do not add return-value redesign to the existing `void` native assignment APIs unless an actual existing failure channel is discovered during inspection.

---

# Debug visibility

In:

```text
extensions/flowfield/godot/steering_system_native.cpp
SteeringSystemNative::get_agent_debug_snapshot()
```

add:

```cpp
d["traffic_group_id"] = static_cast<int64_t>(a->traffic_group_id);
d["traffic_priority"] = a->traffic_priority;
d["pending_smash_priority"] = a->pending_smash_priority;
```

Do not add per-contact logging.

Do not add always-visible labels unless this is trivial and does not clutter the existing overlay.

The debug snapshot is sufficient.

---

# Architecture documentation

Update:

```text
scripts/map/ARCHITECTURE.md
```

Add a concise section explaining:

```text
AgentNavigationPhaseController owns game-specific traffic groups,
priorities and the central assignment/clear helpers used by navigation
phase transitions.

AgentSuspendService clears traffic while navigation is temporarily
suspended and restores it only after entry-flow, A* or escape navigation
has been restored.

TrafficRightOfWayResolver owns generic native arbitration between
agents with opaque traffic groups and priorities.

SteeringSystem supplies generic lazy-flow-wait eligibility and submits
accepted traffic requests to the existing smash propulsion pipeline.

BuildingManager exposes only a thin native forwarding method and owns
no traffic state or algorithm.
```

Also state:

```text
Future agent kinds such as ducks are integrated game-side by assigning
traffic state during their navigation phases. The native resolver does
not require species-specific changes.
```

Do not write a large design document.

---

# Expected files to change

Native:

```text
extensions/flowfield/steering/agent.h
extensions/flowfield/steering/agent.cpp
extensions/flowfield/steering/steering_system.h
extensions/flowfield/steering/steering_system.cpp
extensions/flowfield/steering/traffic_right_of_way_resolver.h       NEW
extensions/flowfield/steering/traffic_right_of_way_resolver.cpp     NEW
extensions/flowfield/core/global_config.h
extensions/flowfield/godot/global_config_native.h
extensions/flowfield/godot/global_config_native.cpp
extensions/flowfield/godot/agent_manager_native.h
extensions/flowfield/godot/agent_manager_native.cpp
extensions/flowfield/godot/steering_system_native.cpp
```

Game-side:

```text
scripts/map/agent_navigation_phase_controller.gd
scripts/map/agent_suspend_service.gd
scripts/map/garden_retarget_controller.gd
scripts/map/building_manager.gd
scripts/map/ARCHITECTURE.md
```

Do not modify unrelated files without a narrow, explicit reason.

If implementing this would add more than approximately 150 lines to an existing large file, move the cohesive logic into the dedicated resolver instead of expanding that file.

---

# Required invariants

Preserve every invariant below:

1. C++ contains no monster, duck, garden, rose or spawner-specific traffic logic.
2. `force_voisine()` is unchanged.
3. `movement_priority()` is unchanged.
4. Existing separation parameters are unchanged.
5. Traffic contact never rebuilds a flow field.
6. Traffic contact never requests lazy flow loading.
7. Traffic contact never recomputes A*.
8. Traffic contact never rebuilds garden topology.
9. Traffic contact causes no damage.
10. Traffic contact does not detach a flow.
11. Traffic contact does not detach a path.
12. Traffic contact does not change gameplay phase.
13. Same traffic group never traffic-shoves itself.
14. Higher traffic priority always wins.
15. Equal priorities use lower group ID as deterministic winner.
16. Outbound beats A* inside.
17. A* inside beats inbound.
18. Traffic-disabled agents are unaffected.
19. Existing contact pushes beat pending traffic pushes.
20. Existing gameplay/combat pushes beat pending contact and traffic pushes.
21. One target receives at most one traffic shove per resolver pass.
22. Traffic cooldown storage is bounded by recently displaced agents, not pairs.
23. Native resolution uses the spatial grid and is not O(total agents²).
24. Normal eating agents have no active traffic state.
25. Restored eating agents have no active traffic state.
26. Turret-eating suspended agents have no active traffic state.
27. Drowning suspended agents have no active traffic state.
28. Externally captured agents have no active traffic state.
29. Retarget-waiting agents have no active traffic state.
30. Initial lazy-entry-flow-waiting agents have no active traffic state.
31. Already-attached agents whose flow group is queued/computing cannot act as traffic winners.
32. Local-retarget A* agents receive per-agent A* traffic state.
33. Resumed A* agents receive per-agent A* traffic state.
34. Existing player bulldozer/contact behaviour remains unchanged.
35. Existing big-monster `smash_resist` remains effective.
36. Pending smash state and `pending_smash_priority` are always cleared together.
37. Future ordinary agent kinds can be integrated game-side without modifying the native resolver.

---

# Manual tests for the user

Do not run these tests yourself.

Include this checklist in the final report.

## Test 1: traffic disabled globally

Set:

```text
traffic_right_of_way_enabled = false
```

Expected:

* behaviour matches the current code;
* no traffic shoves;
* existing contact pushes still work.

## Test 2: one inbound stream

Spawn a dense crowd from one spawner toward one garden.

Expected:

* all agents share the same inbound traffic group;
* no traffic shoves occur within that stream;
* existing normal separation remains responsible.

## Test 3: two inbound streams

Spawn dense crowds from two different spawner routes toward the same garden.

Expected:

* both have priority `100`;
* the stream with the lower traffic group ID wins;
* losing agents are physically displaced;
* neither route is detached;
* the conflict eventually clears.

## Test 4: internal A* crossing

Have several monsters follow conflicting A* paths inside the same garden.

Expected:

* every A* agent has priority `200`;
* every A* agent has its own group based on `nav_id`;
* lower group IDs win deterministic contacts;
* internal opposing movement eventually clears;
* agents retain their paths after displacement.

## Test 5: same-direction A* convoy regression

Have a dense set of monsters follow broadly similar A* paths in the same direction.

Expected:

* occasional physical arbitration is acceptable because groups are per-agent;
* agents retain their paths;
* the convoy does not become materially less stable than the current behaviour;
* agents are not continuously thrown sideways by repeated traffic shoves.

If this fails badly, report it as a tuning/design issue. Do not silently add target reservations or a new traffic graph.

## Test 6: local-retarget A* assignment

Trigger `GardenRetargetController._try_local_retarget_agent()`.

Expected debug snapshot after the local path is assigned:

```text
traffic_group_id == TRAFFIC_GROUP_ASTAR_BASE + nav_id
traffic_priority == 200
```

## Test 7: resumed A* assignment

Suspend an A* monster through turret eating or external capture, then resume it.

Expected:

* traffic is `0/0` during suspension;
* after path restoration and `set_astar_in_agent()`, per-agent A* traffic is restored;
* the path remains attached.

## Test 8: inbound against A*

Have incoming agents conflict with agents already navigating inside the garden.

Expected:

* A* agents win;
* inbound agents are displaced;
* the internal agents can continue toward plants.

## Test 9: outbound against inbound

Have fed agents leave while new agents enter.

Expected:

* outbound agents win;
* inbound agents are displaced;
* the exit stream clears.

## Test 10: outbound against A*

Create a conflict between exiting agents and internal A* agents.

Expected:

* outbound agents win;
* clearing the constrained exit remains the highest priority.

## Test 11: normal and restored eating

Inspect both a newly eating agent and an eating agent restored from save/runtime restoration.

Expected:

```text
traffic_group_id == 0
traffic_priority == 0
```

## Test 12: initial lazy entry-flow wait

Inspect an agent waiting for a queued/computing entry flow before it has joined the route group.

Expected:

```text
traffic_group_id == 0
traffic_priority == 0
```

It remains frozen and cannot shove anyone.

## Test 13: attached flow rebuild wait

Force a currently attached inbound or outbound group into `GROUP_FLOW_WAIT_QUEUED` or `GROUP_FLOW_WAIT_COMPUTING`.

Expected:

* the agent remains frozen by the existing native flow-wait behaviour;
* it cannot become a traffic winner from stale `debug_desired_dir` or `debug_nav_dir`;
* traffic does not make the frozen stream bulldoze another stream.

## Test 14: retarget waiting

Invalidate a garden while agents are queued for budgeted retargeting.

Expected:

```text
traffic_group_id == 0
traffic_priority == 0
```

## Test 15: turret-eating suspension

Suspend an inbound, A* and outbound monster for turret eating.

Expected during suspension for each:

```text
traffic_group_id == 0
traffic_priority == 0
```

After resume, the correct inbound/A*/outbound state is restored only when navigation restoration succeeds.

## Test 16: drowning and external capture

Suspend agents through drowning and external capture.

Expected:

* traffic clears immediately;
* failed recovery leaves traffic disabled;
* successful recovery restores only the navigation-derived state appropriate to the recovered phase.

## Test 17: player contact precedence

Push agents with the player while traffic contact is also occurring.

Expected:

* player contact behaviour remains unchanged;
* an already-pending player/contact impulse is not replaced by traffic.

## Test 18: combat precedence

Hit an agent with a weapon or explosion during a traffic conflict.

Expected:

* combat smash wins;
* traffic never replaces the stronger pending gameplay impulse;
* after the pending impulse is applied, `pending_smash_priority` returns to `None`.

## Test 19: pending-smash reset consistency

Exercise:

* teleport/set position with `clear_velocity = true`;
* drowning phase entry;
* drowning update cancellation;
* normal pending-smash application;
* agent reset/unregistration-reuse paths.

Expected:

```text
smash_pending == false
pending_smash_priority == None
```

No stale priority and no live pending impulse with priority `None`.

## Test 20: big monster

Place a big monster in a losing traffic stream.

Expected:

* hierarchy still identifies it as the loser;
* its existing higher `smash_resist` reduces physical displacement;
* no big-monster-specific traffic rule exists.

## Test 21: walls

Create a jam beside walls.

Expected:

* agents may be shoved messily;
* existing wall-safe smash integration prevents passage through walls;
* paths and flows remain attached.

## Test 22: largest crowd

Run the largest practical crowd.

Expected:

* jams dissolve more often instead of remaining symmetric;
* visible shoving is acceptable;
* no flow rebuilds occur from traffic contact;
* no A* recomputations are triggered by contact;
* no continuous console spam;
* no unbounded pair cooldown map;
* no all-pairs scan;
* no per-pair dynamic allocation;
* no obvious frame-time regression from rebuilding temporary eligibility containers.

## Test 23: future duck integration expectation

Do not implement ducks now.

Confirm from the architecture that adding ducks later should require only:

* spawning/configuring them game-side;
* adding their agent kind to the centralized GDScript participation helper;
* assigning/clearing traffic state during their game-side navigation phases.

Expected native changes:

```text
none
```

---

# Final report

After implementation, report:

1. Every changed and newly created file.
2. The exact generic native traffic state added to `AgentData`.
3. Confirmation that C++ contains no game-specific agent or garden concepts.
4. The exact GDScript priorities and group namespaces.
5. Every phase transition where traffic state is assigned.
6. Every phase transition where traffic state is cleared.
7. How local-retarget and suspension-restored A* agents reach the centralized `set_astar_in_agent()` assignment point.
8. How A* agents receive per-agent traffic groups.
9. How winner selection is made.
10. How one shove per target is enforced.
11. Where traffic cooldowns are owned and cleaned.
12. How attached and unattached lazy-flow-waiting agents are excluded from arbitration.
13. How pending impulse priority prevents traffic from replacing contact/combat pushes.
14. Every place where the complete pending-smash slot and `pending_smash_priority` are cleared together.
15. The exact traffic smash parameters used, including the `0.18` second default control lock.
16. Confirmation that flow/path assignments are preserved.
17. Confirmation that `force_voisine()` and `movement_priority()` were not changed.
18. Confirmation that no Godot, tests, compilation, SCons, export or build command was run.
19. The complete manual test checklist above.
20. Any uncertainty or codebase mismatch encountered.

Do not claim runtime correctness because runtime testing is performed manually by the user.
