You are working on the attached Godot project.

Read `AGENTS.md` and `ARCHITECTURE.md` first. Follow their architecture, typing, file-size, ownership, and performance rules.

# Task: clean and genericize house-resident villager infrastructure

Refactor the existing house/villager system so future ordinary villagers can be added with minimal configuration and without duplicating the Seed Merchant implementation.

This is a **behavior-preserving architectural cleanup**.

Do **not** implement the Inventor yet.

Do not change gameplay, timing, visuals, dialogs, prices, unlock rules, save format, or existing Builder/Seed Merchant behavior except where strictly necessary to make the shared infrastructure generic.

## Current problem

The housing implementation is partly generic, but the resident lifecycle remains hardcoded around:

* `builder`
* `fundamental_builder`
* `seed_merchant`

In particular, `AllyHousingController`, runtime processing, removal routing, player interaction routing, and several contact/group checks explicitly know individual villager types.

The code suggests that adding a new `house_resident_type` should be generic, but in practice adding one would require touching many unrelated systems.

The goal is to make that claim true for normal one-house/one-resident villagers.

---

# Architectural boundary

There are two categories.

## A. Ordinary house villagers

Examples:

* Seed Merchant
* future Inventor
* future similar villagers

They share this lifecycle:

1. One completed house owns one resident.
2. The resident is reconstructed from house state rather than saved independently.
3. It appears during the day.
4. It walks from the common villager arrival route to its house.
5. It remains associated with that house.
6. At night, it returns to its house and becomes hidden/removed as currently implemented.
7. If the house is destroyed, it evacuates using the existing escape behavior.
8. Loading a save reconciles completed houses and residents.
9. It may expose a role-specific interaction/dialog.

## B. Special residents

These remain specialized:

* normal Builders, because they construct houses and have work queues;
* Fundamental Builder, because it has onboarding, tutorial, cutscene, first-house ownership, and fallback behavior.

Do not force Builder-specific behavior into the ordinary-villager abstraction.

The Fundamental Builder may remain an explicit special case where justified.

---

# Required refactor

## 1. Introduce one reusable ordinary-house-villager lifecycle component

Create a focused component with a clear name, such as:

```text
SingleHouseVillagerController
```

The exact name may differ if the codebase already has a more appropriate naming convention.

It must own only shared ordinary resident behavior:

* mapping one resident to one completed house;
* spawning/reconciling residents from completed houses;
* arrival movement;
* association with a house;
* daytime waiting/idle state;
* night return/departure;
* house-destruction evacuation;
* repathing when navigation changes;
* agent removal cleanup;
* exposing position/proximity needed by interactions;
* preventing duplicate residents during reconciliation.

Reuse `DayVisitorMovementController` or the existing shared visitor movement implementation rather than cloning movement logic.

Do not put shop logic, dialog text, purchases, invention logic, Builder work, tutorials, or role-specific gameplay inside this component.

## 2. Make ordinary resident types configuration-driven

Adding a normal resident must not require another large branch in `AllyHousingController`.

Introduce a small resident registration/configuration mechanism.

A registration should identify at least:

```text
resident_type
agent definition / agent kind
agent group or category
house association
role-specific interaction handler, when present
```

Use the smallest clean design appropriate for the codebase:

* registered controller instances;
* configuration resources;
* dictionaries with strict validation;
* or small adapters implementing a documented contract.

Do not create an oversized inheritance hierarchy or a universal NPC framework.

## 3. Replace resident-type condition chains in `AllyHousingController`

Remove ordinary-villager branches resembling:

```gdscript
if resident_type == builder:
elif resident_type == seed_merchant:
```

`AllyHousingController` should orchestrate registered resident handlers through a narrow contract.

The contract should cover only lifecycle operations actually needed, such as:

```text
reconcile_houses(...)
process(delta)
on_night_started(...)
start_pending_departures(...)
repath(...)
on_house_removed(...)
on_agent_removed(...)
owns_agent(...)
```

Names may follow existing conventions.

Builder handling may use a dedicated adapter or remain specialized, but ordinary villagers must no longer require new branches here.

## 4. Consolidate runtime ticking

Inspect `BuildingManager`, `BuildingRuntimeTickController`, and any other runtime owner that explicitly processes the Seed Merchant.

Remove role-specific per-frame calls where they only exist because the merchant lifecycle is separately wired.

Prefer consolidated calls such as:

```text
ally_housing_controller.process(delta)
ally_housing_controller.on_night_started()
ally_housing_controller.start_pending_departures()
ally_housing_controller.repath_residents()
```

The housing controller may dispatch internally to registered handlers.

After this cleanup, adding an ordinary villager must not require editing the central runtime tick controller.

Do not add new per-frame scans, scene-tree searches, polling watchers, or duplicated processing loops.

## 5. Introduce canonical house-resident identity

Every agent reconstructed from a house must receive generic identity information.

Use project-appropriate groups, metadata, or explicit registry state equivalent to:

```text
group: house_residents
resident_type
resident_house_id
home_entrance_cell
```

Prefer stable house IDs if the current house system already exposes them. Do not invent fragile node-path identity when a stable identifier exists.

This identity must allow generic systems to determine:

* whether an agent is house-owned;
* which house owns it;
* its resident role;
* whether it should be reconstructed instead of serialized;
* which handler owns its removal;
* how to evacuate it when its house is destroyed.

Validate missing or inconsistent metadata in debug builds without spamming production logs.

## 6. Generic agent-removal routing

Find code that explicitly routes removed agents to the Merchant or Builder controller.

Refactor it so ordinary house residents are routed through the housing/resident registry.

Required cases:

* agent reaches its night destination;
* agent finishes evacuation;
* agent is forcibly removed;
* house is destroyed;
* scene resets;
* save is loaded;
* duplicate reconciliation is prevented.

Existing Builder-specific removal behavior must remain correct.

## 7. Clean generic contact classifications

Inspect systems such as:

* `AgentTileInteractionController`;
* turret contact/target classification;
* trampling or crushing rules;
* actor displacement;
* death/removal categorization;
* any system listing merchant/builder/client categories manually.

Do not blindly replace all gameplay categories with `house_residents`.

Instead, introduce accurately named generic classifications for the actual behavior.

For example, if clients and villagers share plant-stomping behavior, use a behavior-oriented category such as:

```text
crushing_people
```

or the project’s equivalent.

Avoid misleading names such as `VILLAGER_CATEGORIES` when clients are included.

A future ordinary villager should automatically receive the intended shared person/contact behavior through its definition or registration, without adding its name to multiple arrays.

Preserve all current contact behavior exactly.

## 8. Catalog-driven ordinary-house prerequisites

Inspect house availability logic and `ItemCatalog`.

Keep these generic rules generic:

* cannot build houses at night;
* unique house types cannot be duplicated;
* a house may require another completed house type.

Introduce or use a generic catalog field equivalent to:

```gdscript
"requires_completed_house_type": &"house_builder"
```

Configure the existing Merchant House through this field if that matches its current rule.

Do not change the first Builder House onboarding rule. It may remain specialized because it depends on the Fundamental Builder/tutorial flow.

The prerequisite check must use completed houses, not merely placed WIP houses, unless existing gameplay explicitly behaves otherwise.

## 9. Generic interaction routing

Inspect `PlayerController` and its explicit interaction attempts for:

* Seed Merchant;
* Fundamental Builder;
* any other villager.

Introduce a small generic interaction-target contract or router so adding an ordinary villager does not require another `PlayerController` branch.

The contract may expose methods equivalent to:

```text
can_interact()
get_interaction_world_position()
request_interaction()
is_interaction_open()
```

Use existing interaction range, prompt, input, and priority behavior.

Requirements:

* choose the nearest valid interaction target according to current behavior;
* preserve Fundamental Builder interaction;
* preserve Seed Merchant dialog/shop behavior;
* do not create a broad entity-component interaction framework;
* do not perform scene-tree searches every frame if registration can be used.

Role-specific dialog controllers remain separate.

## 10. Preserve save/load architecture

Houses remain the persisted source of truth.

Do not start serializing ordinary resident agents independently.

On load:

1. houses are restored;
2. completed houses are reconciled;
3. exactly one appropriate resident is recreated for each eligible house;
4. no duplicate resident is spawned;
5. WIP houses do not spawn residents;
6. unique-house semantics remain intact.

Do not unnecessarily break or version the save format.

## 11. Documentation and truthful naming

Update comments and architecture notes around the housing controller.

Comments must accurately state:

* which behavior is generic;
* which resident types use the ordinary lifecycle;
* why Builders and the Fundamental Builder remain specialized;
* how a future ordinary resident should be registered.

Remove stale comments implying all resident types are automatically supported when they are not.

Do not add speculative abstractions for unrequested NPC categories.

---

# Seed Merchant migration

Migrate the existing Seed Merchant onto the new ordinary-house-villager lifecycle.

Its role-specific controller must retain only merchant-specific concerns:

* dialog/shop interaction;
* purchase logic;
* stock or offer state;
* merchant-specific text and visuals;
* any genuinely merchant-specific phase rules.

Shared concerns must move out:

* house ownership;
* spawn/reconciliation;
* arrival;
* night return;
* evacuation;
* repathing;
* generic removal handling.

Do not duplicate the merchant controller and do not introduce temporary compatibility code that leaves both old and new lifecycle implementations active.

---

# Performance constraints

This cleanup must not introduce:

* new global per-frame agent scans;
* repeated `get_nodes_in_group()` calls in hot paths;
* repeated house scans per resident;
* duplicate movement processing;
* extra flow-field recomputations;
* new watchers that continuously correct state;
* resident polling from `PlayerController`;
* synchronous navigation rebuilds.

Use indexed mappings such as:

```text
house_id -> resident
agent_id -> resident handler
resident_type -> handler/configuration
```

Update those mappings when houses or agents are created/removed.

Reconciliation may scan houses at controlled lifecycle points such as load, Dawn, or explicit house completion/removal events.

---

# File organization

Respect `AGENTS.md`.

Keep responsibilities separated. Likely ownership should resemble:

```text
AllyHousingController
    overall orchestration and handler registry

SingleHouseVillagerController
    reusable ordinary resident lifecycle

SeedMerchantController
    merchant-specific interaction and gameplay only

Builder controller(s)
    builder work and specialized lifecycle

Interaction router/service
    generic nearby interaction selection
```

These names are illustrative. Reuse existing modules where appropriate.

Do not grow `BuildingManager`, `PlayerController`, or `AllyHousingController` into larger monoliths.

If a touched file is already oversized, extract the new responsibility instead of adding more code to it.

Use strict typing. Avoid unsafe dynamic access when a typed interface or validated adapter is practical.

---

# Required validation

Test all existing behavior before considering the refactor complete.

## Merchant House

* Merchant House remains locked until its existing prerequisite is completed.
* It still costs the same amount.
* It remains unique.
* It cannot be built at night.
* WIP construction behaves unchanged.
* Completing the house creates exactly one Seed Merchant.
* Removing and rebuilding the house does not create duplicates.

## Seed Merchant

* Arrives and navigates as before.
* Uses the same visuals and directional animation.
* Interaction prompt appears at the same range.
* Existing dialog/shop still opens.
* Purchases remain unchanged.
* It returns inside at night.
* It returns correctly on the next applicable day.
* Destroying the house triggers the current evacuation/removal behavior.
* It repaths correctly after navigation changes.

## Builder systems

* Fundamental Builder tutorial and dialog remain unchanged.
* Fundamental Builder still uses the first Builder House according to current rules.
* Normal Builders still start from the second Builder House.
* Builder work queues, WIP progress, hammer behavior, night behavior, and house destruction behavior remain unchanged.
* No Builder is accidentally processed by both the specialized and ordinary lifecycle systems.

## Save/load

Test saves with:

* no houses;
* Merchant House as WIP;
* completed Merchant House during the day;
* completed Merchant House while merchant is inside at night;
* Merchant House removed;
* multiple Builder Houses plus Merchant House.

After load:

* house state is correct;
* resident count is correct;
* no duplicate agent exists;
* dialogs remain functional;
* residents are associated with the correct house.

## Interaction routing

* Seed Merchant remains interactable.
* Fundamental Builder remains interactable.
* When two interaction targets are nearby, current nearest/priority behavior is preserved.
* Closing one dialog correctly clears interaction state.
* No interaction prompt remains after an agent leaves or is removed.

## Contact behavior

* Clients, Merchant, and Builders retain their current plant/building contact behavior.
* Turrets and other systems still classify them correctly.
* No future-role-specific hardcoded list remains where registration/configuration can express the same behavior.

---

# Automated checks

Add focused regression tests where the project’s current testing infrastructure supports them.

At minimum cover:

1. completed ordinary resident house creates one resident;
2. repeated reconciliation does not create duplicates;
3. removing the house evacuates/removes its resident;
4. WIP house creates no resident;
5. save/load reconstruction creates one resident;
6. unique-house rule remains generic;
7. prerequisite-completed-house rule works from catalog data;
8. unknown `resident_type` fails clearly rather than silently spawning the wrong agent;
9. Builder roles are not accidentally routed through the ordinary resident handler;
10. removed agent mappings are cleaned correctly.

If automated scene tests are not established, add deterministic test helpers or document exact manual reproduction steps.

---

# Acceptance criteria

The cleanup is complete only when adding a future ordinary villager requires approximately:

1. one house catalog entry;
2. one agent/visual definition;
3. one registration/configuration entry for the ordinary resident lifecycle;
4. one role-specific interaction/dialog controller;
5. assets and translations.

It must not require editing:

* central runtime tick code;
* save/load resident logic;
* house-destruction evacuation logic;
* generic night lifecycle logic;
* `PlayerController` interaction branches;
* generic agent-removal routing;
* contact-category arrays in several files.

Before finishing, search the project for all references to:

```text
seed_merchant
merchant
builder
resident_type
house_resident
VILLAGER_CATEGORIES
```

Review each result and ensure remaining role-specific references are genuinely role-specific rather than leftover lifecycle hardcoding.

Deliver:

* the implementation;
* a concise list of changed files;
* a description of the resulting resident registration contract;
* confirmation that no gameplay behavior was intentionally changed;
* test results and any remaining justified special cases.
