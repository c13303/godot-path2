# Task: Add Greenmonster as a clean data-driven monster variant

Read `AGENTS.md` and `ARCHITECTURE.md` first and follow all project conventions.

Implement a new monster type:

* Internal ID: `greenmonster`
* Display name: `Greenmonster`
* Sprite: `speedmonster.png`
* Behaviour: exactly the same as the normal/basic monster
* Movement speed: `2.0 ×` the basic monster speed
* Maximum health: `50%` of the basic monster maximum health
* No unique AI, state, scene, controller, navigation logic, combat logic, or special-case runtime behaviour

## Architectural expectation

This must remain a simple data-defined monster variant.

The current codebase defines monsters through `MonsterCatalog` rather than external `.tres` resources because of the documented export reliability issue with scripted resources. Respect that existing decision.

Do not introduce a new monster scene.

Greenmonster must use the same shared character scene, behaviours, animation system, spawning pipeline, navigation, targeting, eating, tantrum, drowning, stomp interactions, save/load handling, planificator UI, and wave system as the basic monster.

The only intentional differences are:

* Texture
* Speed multiplier
* Maximum health
* Monster ID and display name

## Implementation

Add `speedmonster.png` to the same appropriate monster sprite asset location used by the existing monster definitions.

Register Greenmonster cleanly in `monster_catalog.gd`.

The definition should inherit or copy all ordinary monster properties from the basic monster while changing only:

```gdscript
id = &"greenmonster"
display_name = "Greenmonster"
texture = preload(".../speedmonster.png")
speed_scale = 2.0
max_health = basic_monster_max_health * 0.5
```

Do not duplicate a large block of basic-monster configuration unnecessarily.

Prefer a small shared factory/helper if it makes the relationship explicit and avoids property drift between Basic Monster and Greenmonster. For example, ordinary monster defaults may be created in one place and selectively overridden.

However:

* Do not perform a broad speculative refactor.
* Do not introduce inheritance or abstraction solely for two lines of reuse.
* Keep the implementation proportional to the task.
* Preserve strict typing.
* Avoid `:=` where the project guidelines prohibit or discourage it for numeric or dynamically inferred values.

## Health relationship

Greenmonster health must remain logically defined as 50% of the normal monster health.

Do not silently hardcode a duplicated value such as `250` unless the existing monster architecture makes a derived relationship impractical.

Prefer deriving it from the same basic-monster health constant or shared defaults so that changing normal monster health later does not leave Greenmonster incorrectly balanced.

Handle the conversion to the expected health type explicitly.

## Catalog integrity

Ensure every catalog API recognizes Greenmonster consistently:

* Lookup by ID
* ID enumeration
* Full definition enumeration
* Validation or `has_monster`
* Any editor-facing enumeration exposed by the game project

Avoid maintaining several manually duplicated ID lists when a single source of truth can be used cleanly.

A small local cleanup is acceptable if it removes obvious catalog duplication and lowers the chance that future monster types are only partially registered.

Do not change the external behaviour of existing Basic Monster or Bigmonster.

## Behaviour expectations

Greenmonster must inherit normal/basic-monster behaviour, including:

* Standard small-monster classification
* Normal pathfinding and flow-field group behaviour
* Standard targeting and eating
* Standard tantrum behaviour
* Standard crowd steering
* Standard player weapon interactions
* Standard knockback and push resistance
* Standard drowning rules
* Standard Kraken compatibility
* Standard plant-stomp damage
* Standard spawn and exit behaviour

Do not add checks such as:

```gdscript
if monster_type == &"greenmonster":
```

outside the central monster definition/catalog layer.

No gameplay subsystem should need to know specifically about Greenmonster.

## Wave and Rose Level Editor integration

Greenmonster must be usable as a normal wave monster type.

Verify that:

* Spawn playlist validation accepts `greenmonster`.
* Runtime spawning resolves it through the generic monster catalog.
* Existing wave count and pending count systems distinguish it correctly by type.
* The planificator displays it automatically with the correct sprite/icon.
* Save/reload preserves living Greenmonsters correctly.
* The Rose Level Editor includes Greenmonster in its available monster types for waves.

First determine how the Rose Level Editor gets its list:

1. If it consumes the game catalog or a shared authoritative list, Greenmonster should appear automatically after registration. Verify this.
2. If the editor has a separate hardcoded list, update that list minimally.
3. If the editor source is not present or cannot be verified, do not guess. State exactly what could and could not be confirmed.

Do not create parallel metadata solely for the editor unless the existing architecture requires it.

## Asset and animation verification

Confirm that `speedmonster.png` matches the normal monster sprite contract:

* Correct frame count
* Correct horizontal/vertical layout
* Correct directional order
* Correct dimensions
* Correct pivot, scale and offset expectations

Use the same animation metadata as Basic Monster unless the asset objectively requires different metadata.

Do not alter the sprite globally to compensate for a malformed asset without reporting it.

## Validation

Run the relevant project validation and tests available in the repository.

At minimum verify:

1. Catalog lookup returns Greenmonster.
2. Catalog enumeration includes it exactly once.
3. Invalid monster IDs still fail validation.
4. A playlist containing `greenmonster` validates.
5. A Greenmonster spawns through the normal spawn pipeline.
6. Its texture is `speedmonster.png`.
7. Its effective speed is exactly twice the basic monster speed.
8. Its max health is exactly half the basic monster max health.
9. Basic Monster and Bigmonster retain their previous values and behaviour.
10. Planificator rendering does not require Greenmonster-specific code.
11. Save/reload restores its correct type, current health and maximum health.
12. No new errors, warnings, parser failures, invalid resources, or export-validation failures appear.

Where practical, add focused automated coverage for the catalog and definition relationships rather than relying only on manual inspection.

## Required architecture/performance audit

While implementing this, inspect the directly touched paths for obvious problems such as:

* Monster types hardcoded in unrelated gameplay systems
* Repeated manual monster ID lists
* Per-frame catalog recreation or resource allocation
* Repeated texture loading
* Repeated construction of immutable monster definitions in hot paths
* Spawn systems branching on concrete monster names
* UI systems maintaining separate monster metadata
* Save/load code that only supports Basic Monster and Bigmonster
* Non-generic planificator or wave validation logic
* Unnecessary per-agent work caused by adding another monster type
* Any code that would require several unrelated edits for every future ordinary monster variant

Do not broaden the task into unrelated refactoring.

If you find a problem:

* Fix it only when the correction is small, safe, directly relevant, and covered by validation.
* Otherwise leave the behaviour unchanged and report it clearly.

## Final report

Return a concise implementation report containing:

### Changed

* Files modified
* Greenmonster registration details
* How health and speed are derived
* How it becomes available in waves and the Rose Level Editor
* Tests and validation performed

### Architecture findings

Explicitly state whether any non-generic, fragile, duplicated, or unoptimized code was found.

For each finding, include:

* File and relevant symbol
* Why it is problematic
* Runtime, maintenance, or performance impact
* Whether it was fixed during this task
* Recommended follow-up if it was not fixed

Do not claim the architecture is generic merely because Greenmonster spawns. Confirm the complete route from catalog definition through editor selection, playlist validation, spawning, runtime behaviour, UI display, and save/reload.
