# TASK — Fix and complete shared basic agent/villager behavior

Read `AGENTS.md` first.

Do not run Godot, tests, builds, exports, or compilation. The user will test manually.

## Objective

Investigate and fix the inconsistent basic behavior between:

* Fundamental Builder
* normal Builders
* Seed Merchant
* Inventor
* clients
* monsters
* player, where applicable

The current problems suggest that shared agent behavior is only partially generic and that several systems still rely on hardcoded role names.

Fix the architecture cleanly without creating one giant agent controller.

---

# Core health rule — must be preserved exactly

## Every agent has health

All agents retain a health/life model:

* player
* clients
* villagers
* builders
* Merchant
* Inventor
* monsters
* future agent types

Do not remove health from peaceful agents.

## Generic health-bar visibility

The health bar must follow one universal rule:

```gdscript
visible only when health < max_health
```

Therefore:

* a full-health monster shows no health bar;
* a full-health villager shows no health bar;
* a full-health client shows no health bar;
* a full-health player shows no health bar;
* a damaged agent shows its health bar;
* if restored to full health, the bar hides again.

Health-bar visibility must not depend on `agent_kind`, role groups, damage immunity, hostility, or whether the agent is peaceful.

Remove any role-specific health-bar visibility whitelist.

## Current gameplay consequence

In the current game, there is no normal way to damage:

* clients;
* villagers;
* Builders;
* Merchant;
* Inventor;
* player.

Therefore, their health bars should never appear during current gameplay because their health remains full.

This is a consequence of the generic full-health rule—not a special rule that permanently hides their bars.

Do not remove their health fields and do not make their health bars role-disabled.

## Buildings

Buildings use their separate building durability and health overlay.

The same visibility principle applies:

* full-health building: no health bar;
* damaged building: health bar visible.

The bar currently seen around the Inventor house must be investigated precisely:

* determine whether it belongs to the Inventor agent or the house;
* fix the underlying owner/visibility issue;
* do not merely hide the symptom.

---

# Reported problems

## 1. Dialog tooltip missing on non-Fundamental villagers

Agents with a valid dialog should use the same basic interaction-tooltip behavior.

Currently, the Fundamental Builder receives an interaction tooltip, while other dialog villagers may not.

Known relevant scripts may include:

* `fundamental_builder_prompt.gd`
* `merchant_prompt.gd`
* `inventor_prompt.gd`
* `InteractionRouter`
* the corresponding dialog controllers

Investigate whether prompts are:

* duplicated per villager;
* wired to different controllers;
* checking role-specific BuildingManager state;
* missing scene references;
* using inconsistent interaction eligibility methods.

## 2. Villagers cannot be pushed by the player

Merchant, Inventor, and other villagers appear physically immovable compared with the Fundamental Builder.

Investigate:

* native contact/push profiles;
* agent registration metadata;
* role-specific `agent_kind` handling;
* paused-agent behavior;
* steering pause;
* contact displacement;
* collision groups;
* push resistance;
* player-to-agent contact;
* whether ordinary villagers are omitted from a shared group.

Villagers must not behave like static walls.

## 3. Unexpected full health bar

All agents have health, but no agent health bar should appear at full health.

The Inventor likely exposes a role-specific health-bar exclusion bug because it was not added to an old hardcoded agent-kind list.

Do not solve this by adding `"inventor"` to another whitelist.

Replace the underlying visibility logic with the universal `health < max_health` rule.

---

# Required architecture

## A. Introduce an explicit shared villager identity

Create or standardize one canonical group:

```gdscript
const VILLAGERS_GROUP: StringName = &"villagers"
```

This group represents peaceful villager/person identity.

It should include:

* Fundamental Builder
* normal Builders
* Seed Merchant
* Inventor
* future villagers

Keep other semantic groups separately:

* `house_residents` still means agents associated with a house;
* `builders` still means Builder-specific behavior;
* `merchants` still means Merchant-specific behavior;
* `inventors` may remain for Inventor-specific behavior.

Fundamental Builder must belong to `villagers` even when it is not currently assigned to a house.

Do not replace every specialized group with `villagers`. Use the canonical group only where the intended concept is genuinely “all villagers.”

---

## B. Add one shared villager-trait setup path

In the appropriate agent-definition/configuration service, create one focused shared helper, for example:

```gdscript
func _apply_villager_traits(agent: Node) -> void:
```

Call it from the setup paths for:

* normal Builder;
* Fundamental Builder;
* Merchant;
* Inventor.

Shared traits should include only behavior genuinely shared by all villagers:

* canonical `villagers` group;
* common player-contact push profile;
* peaceful-agent damage policy, if such a policy already exists;
* common native contact metadata;
* any common person-agent defaults currently duplicated.

Do not put these into the shared helper:

* dialog content;
* Merchant shop logic;
* Inventor logic;
* Builder construction;
* house ownership;
* tutorials;
* cutscenes;
* hammer animation.

Normal and Fundamental Builders must share the same base villager traits before applying their Builder-specific behavior.

---

# Health and health-bar implementation

## C. Make agent health-bar rendering fully generic

Find the agent health-bar rendering path, likely in or around `character.gd`.

Refactor it so visibility is determined only by health state:

```gdscript
func should_show_health_bar() -> bool:
    return max_health > 0 and health < max_health
```

Use the project’s actual typed conventions and existing naming.

Required behavior:

```gdscript
health >= max_health
```

means hidden.

```gdscript
health < max_health
```

means visible.

Clamp health safely if necessary:

```gdscript
health = clampi(health, 0, max_health)
```

Do not use:

* `agent_kind` checks;
* `villagers` checks;
* `monsters` checks;
* damage-immunity checks;
* hostility checks;
* role whitelists.

Health-bar rendering and damage eligibility are separate concerns.

## D. Preserve health for all agents

Do not remove:

* health;
* maximum health;
* damage API;
* healing compatibility;
* future ability to damage peaceful agents.

Clients, villagers, and player still possess health even though current gameplay does not damage them.

## E. Audit all health-bar implementations

Search for every agent health-bar path:

* custom `_draw()` health bars;
* child health-bar controls;
* overlays;
* scripts toggling bar visibility;
* role-specific exceptions;
* initialization code showing full bars;
* bars attached to agents but positioned over nearby houses.

Ensure there is exactly one authoritative rule for agent health-bar visibility.

If multiple agent bar implementations exist, either unify them or make them consume one shared predicate.

## F. Preserve separate building health bars

Do not merge agent and building health systems.

Buildings should continue using their existing durability and overlay system.

Confirm:

* full-health houses show no bar;
* damaged houses show a bar;
* the bar is positioned relative to the building;
* removing a building removes its bar;
* an agent bar cannot visually appear attached to a nearby house.

---

# Generic interaction prompt

## G. Replace role-specific prompt behavior with one reusable implementation

The dialog controllers already appear to implement a common interaction contract such as:

```gdscript
can_interact() -> bool
get_interaction_world_position() -> Vector2
request_interaction() -> bool
is_interaction_open() -> bool
```

Use that existing contract.

Create one reusable interaction prompt script or scene, for example:

```txt
scripts/ui/interaction_prompt.gd
```

Each prompt instance should receive a target controller through a configured `NodePath` or another clean dependency.

The reusable prompt owns only:

* displaying the E/Y interaction glyph;
* keyboard/gamepad glyph switching;
* icon size and shadow;
* world-to-screen positioning;
* hiding when the target cannot interact;
* hiding while the target dialog is open;
* hiding while the shared Dialog UI is occupied;
* following the target interaction position.

The prompt must not know about:

* Merchant;
* Inventor;
* Fundamental Builder;
* Builder work state;
* house residence;
* tutorials;
* cutscenes;
* role-specific BuildingManager queries.

Those rules belong in each dialog controller’s `can_interact()` implementation.

Wire the existing prompt nodes to:

* Fundamental Builder → `FundamentalBuilderDialogController`
* Merchant → `MerchantDialogController`
* Inventor → `InventorDialogController`

Delete obsolete duplicated prompt scripts only after verifying there are no remaining references.

Do not alter the generic `InteractionRouter` unless a real defect is found.

---

# Player push/contact behavior

## H. Make every villager pushable through the same base contact profile

Expected behavior:

* player contact can visibly displace every villager;
* Merchant and Inventor do not behave like immovable objects;
* normal Builders and Fundamental Builder use the same underlying response;
* dialog or idle pausing does not create infinite push resistance;
* no role-specific push string checks are introduced.

Use the Fundamental Builder’s current physical response as the reference behavior.

Do not invent arbitrary push values before inspecting the existing effective configuration.

Trace:

* native registration defaults;
* contact push power;
* contact resistance;
* contact cooldown;
* weight/mass equivalents;
* movement integration;
* external displacement;
* player collision/contact handling;
* agent paused state.

## I. Inspect native paused-agent semantics

Merchant or other villagers may be paused while available for dialog.

Determine whether `set_agent_paused()` currently:

1. pauses only autonomous navigation/steering; or
2. skips all movement integration, including external contact displacement.

If pause currently blocks player push, separate these concepts cleanly:

* autonomous movement can remain paused;
* valid external contact displacement should still be applied.

Do not solve it by:

* teleporting the villager from GDScript;
* moving it manually every frame;
* disabling dialog pause without understanding its purpose;
* adding Merchant/Inventor special cases in C++.

The native implementation must remain generic and profile/capability-driven.

## J. Apply the shared profile before native registration

If native registration reads metadata or properties during `spawn_agent()`, ensure shared villager contact traits are applied before registration.

Inspect actual spawn order.

Do not add a post-registration correction unless the native API requires it.

---

# Audit hardcoded role lists

## K. Search for incomplete villager enumeration

Search the project for hardcoded combinations involving:

```gdscript
builders
merchants
inventors
house_residents
fundamental_builder
```

Where the actual intended concept is “all villagers,” replace role enumeration with the canonical `villagers` group.

Inspect at minimum:

* build-placement actor displacement;
* occupied-cell queries;
* spawn-cell validation;
* player-contact eligibility;
* native registration consistency watchers;
* debug watchers;
* cleanup/unregister logic;
* agent-cell tracking;
* house destruction displacement;
* any generic scene-tree group scan.

Known likely files include:

* `build_actor_displacement_service.gd`
* `building_manager.gd`
* `agent_registration_consistency_watcher.gd`

Do not replace a specialized list where specialized role behavior is intentional.

## L. Avoid per-frame scene-tree scans

The fix must not introduce repeated `get_nodes_in_group()` scans inside per-frame agent movement.

Use:

* existing registries;
* cached agent trackers;
* spawn/despawn registration;
* event-driven updates.

Scene-tree group queries are acceptable for infrequent setup, reconciliation, or explicit build-placement operations where already appropriate.

---

# Responsibility boundaries

Maintain the existing modular ownership.

## Agent definition/configuration service

Owns:

* common villager traits;
* role-specific visual/stat configuration;
* shared native contact metadata.

## `HouseResidentController`

Owns:

* ordinary resident lifecycle;
* house association;
* arrival;
* night return;
* evacuation;
* removal.

## `BuilderController`

Owns:

* construction work;
* Builder claims;
* hammer behavior;
* Fundamental Builder special lifecycle;
* Builder-specific idle correction.

## Dialog controllers

Own:

* role-specific interaction eligibility;
* role-specific dialog content;
* role-specific dialog actions.

## Generic interaction prompt

Owns only shared prompt presentation.

## Native movement/contact extension

Owns:

* player/agent physical contact;
* push response;
* paused movement integration;
* contact profiles.

## Agent health system

Owns:

* health;
* maximum health;
* damage;
* healing compatibility;
* generic health-bar state.

## Building health system

Remains separate from agent health.

Do not create a large `VillagerManager` or general-purpose agent god object.

---

# Static verification requirements

Because Godot must not be run, verify by code inspection that:

1. Every agent type still has health and maximum health.
2. Agent health-bar visibility uses only `health < max_health`.
3. Full-health monsters show no bar.
4. Full-health villagers show no bar.
5. Full-health clients show no bar.
6. Full-health player shows no bar.
7. Damaged agents would show their bar regardless of role.
8. No agent-kind health-bar whitelist remains.
9. Health-bar visibility is independent from damage immunity.
10. Full-health houses show no building bar.
11. Damaged houses show their building bar.
12. The Inventor’s unexpected bar owner is identified precisely.
13. Fundamental Builder, Builders, Merchant, and Inventor all receive the same shared villager traits.
14. Merchant and Inventor receive the same base player-contact response as the Fundamental Builder.
15. Paused villagers can still receive valid external player displacement.
16. All dialog villagers use the reusable interaction prompt.
17. The prompt consumes the generic interaction contract.
18. Generic villager systems no longer require editing for every future villager role.
19. No new per-frame group scan was introduced.
20. Houses remain the saved source of truth for ordinary resident spawning.

---

# Manual acceptance tests

## Health bars

### Full health

Test:

* monster;
* client;
* Fundamental Builder;
* normal Builder;
* Merchant;
* Inventor;
* player.

Expected:

* no health bar is visible while health is full.

### Damaged health

Using an existing debug or controlled damage path where available:

* damage a monster;
* optionally damage another agent through debug tooling if supported.

Expected:

* bar appears immediately when health becomes lower than maximum;
* bar updates as health changes;
* bar hides again if health is restored to maximum.

Do not add a new gameplay damage source for peaceful agents solely for this test.

### Buildings

Expected:

* full-health Inventor house shows no bar;
* damaged Inventor house shows its building bar;
* bar is visually attached to the house, not the resident.

## Dialog prompts

For Fundamental Builder, Merchant, and Inventor:

1. Enter interaction range.
2. Correct E/Y prompt appears.
3. Switch input device; glyph updates.
4. Open dialog; prompt hides.
5. Close dialog; prompt returns if still interactable.
6. Leave range; prompt hides.
7. During unavailable states, prompt stays hidden.

## Push behavior

For Fundamental Builder, normal Builder, Merchant, and Inventor:

1. Walk directly into the agent.
2. Agent is visibly displaced.
3. Response is approximately consistent between villager roles.
4. Agent does not behave like a static wall.
5. Dialog-paused Merchant can still be displaced.
6. No jitter loop, teleporting, or unstable contact occurs.

## Lifecycle regression

Verify manually that:

* residents still spawn correctly;
* residents associate with the correct houses;
* residents still return home or leave at night;
* destroyed houses evacuate residents;
* native navigation unregistering still occurs;
* `AgentCellTracker` cleanup still occurs;
* no duplicate residents spawn during reconciliation;
* Builder-specific behavior remains unchanged.

---

# Final report

Report precisely:

* why the non-Fundamental dialog prompts were missing;
* why Merchant/Inventor could not be pushed;
* whether native pause semantics caused or contributed to the push bug;
* whether the unexpected bar belonged to the Inventor or the house;
* where the full-health bar was being shown incorrectly;
* the final universal health-bar visibility rule;
* the shared villager identity/profile introduced;
* duplicated prompt scripts removed;
* hardcoded villager lists corrected;
* every file changed;
* any remaining role-specific hardcoding and why it is intentional.

Do not claim runtime verification because Godot was not run.
