You are working on the cleaned Godot codebase.

Read `AGENTS.md` and `ARCHITECTURE.md` first.

# Feature: new house villager — Inventor

Implement a new ordinary house resident using the generic house-villager infrastructure created by the previous cleanup.

This feature should act as a practical validation that a new ordinary villager can now be added mostly through configuration and isolated role-specific code.

Do not reintroduce resident-specific branches into central systems.

---

# Identity and localization

Internal resident type:

```gdscript
&"inventor"
```

House item ID:

```gdscript
&"house_inventor"
```

Displayed villager name:

```text
FR: Inventeur
EN: Inventor
```

Use translation keys following the project’s existing naming conventions.

---

# Assets

## Villager sprite

Use:

```text
inventor.png
```

This is a character spritesheet using the same frame layout, directional frames, animation rules, offsets, scale, and z-index behavior as the other ordinary villagers.

Do not create custom animation code if the existing villager visual definition supports it through configuration.

## House sprite

Use:

```text
house_inventor.png
```

The Inventor House uses the same:

* footprint;
* entrance layout;
* WIP construction behavior;
* sprite alignment;
* preview alignment;
* z-index rules;
* durability;
* destruction behavior;
* night building restriction;
* save/load behavior;

as the Merchant House.

## Quickslot/catalog icon

Use `items.png`:

```text
frame index: 31
```

This is the 32nd frame using zero-based indexing.

Use the same icon extraction and presentation rules as existing buildable houses.

---

# Inventor House configuration

The Inventor House must use the same build conditions as the Merchant House:

* price: `20` gems;
* unlocked only after the required completed Builder House condition used by the Merchant House;
* unique: only one Inventor House may exist;
* unavailable while another Inventor House exists, including the states already considered by the generic unique-house system;
* cannot be built at night;
* starts as a WIP house;
* completed by Builders using the existing generic house construction workflow.

Do not duplicate Merchant House availability code.

Use the cleaned catalog-driven fields, including the generic completed-house prerequisite field and unique-house configuration.

The house must declare:

```gdscript
house_resident_type = &"inventor"
```

or the cleaned codebase’s equivalent configuration.

---

# Resident lifecycle

Register the Inventor as an ordinary single-house villager through the cleaned generic resident registry.

The Inventor must automatically inherit the same shared lifecycle as the Seed Merchant:

1. A WIP Inventor House does not spawn an Inventor.
2. Completing the house creates exactly one Inventor.
3. The Inventor uses the shared villager arrival/navigation behavior.
4. It remains associated with its owning house.
5. At night, it returns inside its house using the generic resident lifecycle.
6. It returns during the next applicable daytime phase.
7. If the house is destroyed, it uses the existing generic evacuation/removal behavior.
8. It repaths through the generic resident navigation hooks.
9. It is reconstructed from completed house state after loading.
10. It is not independently serialized as an agent.
11. Repeated reconciliation must never create duplicates.
12. Removing and rebuilding the house must produce exactly one valid Inventor.

The Inventor must receive the generic house-resident identity established by the cleanup:

```text
house resident group/category
resident_type = inventor
owning house ID
home entrance information
```

It must also automatically receive the same appropriate shared person/contact classifications as the Seed Merchant and Builders, without adding `inventor` to scattered hardcoded arrays.

---

# Interaction

The Inventor is interactable using the cleaned generic nearby-interaction routing.

Do not add a new explicit Inventor branch to `PlayerController`.

Use the same:

* interaction distance;
* interaction tooltip behavior;
* input handling;
* nearest-target selection;
* dialog ownership and closing behavior;

as the other villagers.

Create only the small Inventor-specific interaction/dialog controller required by the generic contract.

---

# Dialog

When the player interacts with the Inventor, open the generic dialog UI.

## Speaker

```text
FR: Inventeur
EN: Inventor
```

## Portrait

Use `inventor.png`, following the same portrait-frame convention as the other villager dialogs.

## Text

French:

```text
Salut Rose, en échange de [money icon], je peux te donner des nouvelles idées !
```

English:

```text
Hi Rose! In exchange for [money icon], I can give you new ideas!
```

Use the project’s existing inline icon syntax for the money/gem icon. Do not write the literal text `[money icon]` if the dialog system already provides an icon token or BBCode-style placeholder.

## Choice

For now, provide only one choice:

```text
FR: OK
EN: OK
```

Selecting it closes the dialog.

There is currently:

* no payment;
* no currency validation;
* no currency deduction;
* no idea-generation feature;
* no inventory reward;
* no unlock;
* no persistent Inventor-specific state.

The money icon is informational dialogue content only.

Do not create placeholder economy logic or speculative future invention systems.

---

# Architecture constraints

This addition must use the cleaned generic infrastructure.

Adding the Inventor should not require role-specific edits to:

* central runtime ticking;
* generic save/load logic;
* generic resident reconciliation;
* night lifecycle orchestration;
* house-destruction evacuation;
* generic agent-removal routing;
* `PlayerController` interaction branches;
* generic contact-category arrays.

Acceptable changes should be limited approximately to:

1. house/item catalog configuration;
2. agent visual/definition configuration;
3. ordinary resident registration;
4. Inventor-specific dialog/interaction code;
5. translations;
6. asset references.

If implementing the Inventor still requires substantial hardcoded edits to central systems, stop and correct the generic infrastructure rather than adding another special case.

Do not copy `SeedMerchantController` wholesale.

Reuse its shared lifecycle through the generic resident system. Only the Inventor-specific dialog behavior should be separate.

---

# Save/load

Houses remain the source of truth.

Required behavior:

* WIP Inventor House loads as WIP and has no resident.
* Completed Inventor House loads with exactly one Inventor.
* The Inventor is associated with the correct house.
* No duplicate Inventor appears after load or repeated reconciliation.
* Destroyed/nonexistent Inventor House produces no Inventor.
* No new save-format version should be required unless the catalog item ID itself necessitates existing generic house serialization behavior.

---

# Validation

Verify all of the following:

## Build menu

* Inventor House appears with `items.png` frame `31`.
* It is hidden or disabled according to the same prerequisite rule as the Merchant House.
* It costs `20` gems.
* It is unique.
* It cannot be built at night.
* Its disabled-state tooltip/reason follows existing generic UI behavior.

## Construction

* Placement preview uses the correct footprint.
* `house_inventor.png` is aligned identically to the Merchant House.
* The house begins as WIP.
* Builders can complete it normally.
* Completing it spawns exactly one Inventor.

## Villager

* `inventor.png` uses the correct directional frames.
* Movement, z-index, arrival, waiting, night return, next-day return, repathing, and evacuation work through the shared implementation.
* Destroying the house does not leave an orphaned Inventor.
* Rebuilding it does not create duplicates.

## Dialog

* The interaction prompt appears at the correct distance.
* The generic interaction router selects the Inventor correctly.
* The French and English speaker names are correct.
* The French and English dialog strings are correct.
* The money icon renders inline.
* Only the `OK` choice appears.
* `OK`, close button, and standard cancel controls close the dialog correctly.
* No money is deducted and no reward is granted.

## Regression

Confirm that adding the Inventor did not change:

* Seed Merchant behavior;
* Merchant House behavior;
* Builder behavior;
* Fundamental Builder behavior;
* existing house save/load;
* existing interaction target priority;
* night lifecycle processing;
* generic contact/trampling behavior.

---

# Delivery

Provide:

* the implementation;
* a concise list of changed files;
* the exact Inventor registration/configuration added;
* the translation keys introduced;
* confirmation that no Inventor-specific central runtime or save/load branch was added;
* validation results.
