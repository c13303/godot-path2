# Task: Replace the counter’s vertical rose pile with a compact 10-rose bouquet layout

Read `AGENTS.md` and `ARCHITECTURE.md` first.

Do not run Godot, tests, compilation, export, or build commands. The user will test manually.

## Objective

Roses stored on a `rose_shop_counter` must no longer form a vertical stack.

Display up to the existing maximum of **10 roses** as a compact, strongly overlapping bouquet inspired by the provided reference image:

```text
      ●  ●  ●
   ●  ●  ●  ●
      ●  ●
        ●
```

This is an approximate silhouette, not a strict grid:

* compact and roughly rounded/triangular;
* strong overlap;
* slightly irregular/staggered placement;
* wider near the upper/middle section;
* narrower toward the bottom;
* lower/front roses render above higher/back roses;
* deterministic positions: no random offsets.

Do not change counter stock capacity, inventory, sales, navigation, or save data.

---

## Confirmed current implementation

Counter rose visuals are owned by:

```text
scripts/map/counter_stock_manager.gd
```

The current vertical pile is generated through:

```gdscript
func _pile_offset(index: int) -> Vector2
```

That offset is used consistently by:

* `rebuild_pile()`;
* `animate_harvested_rose()`;
* `animate_counter_rose_to_client()`.

This consistency must be preserved so flying roses arrive at and leave from the exact visible bouquet slot.

---

## Required implementation

### 1. Replace procedural vertical stacking with 10 fixed bouquet slots

Replace the vertical `_pile_offset()` calculation with a predefined layout of exactly 10 local offsets.

Use one authoritative method, for example:

```gdscript
func _bouquet_offset(index: int) -> Vector2:
```

Back it with a fixed slot array.

Use a compact layout approximately like this, relative to the counter center:

```text
slot 0: central anchor
slot 1: upper-left
slot 2: upper-right
slot 3: middle-left
slot 4: middle-right
slot 5: far-left
slot 6: far-right
slot 7: lower-left
slot 8: lower-right
slot 9: bottom-center
```

The exact fill order may be adjusted so partial stocks of 1–9 roses still look coherent, but:

* existing roses must never change position when another rose is added;
* removing the last rose must remove the corresponding last-filled slot;
* a full stock of 10 must closely resemble the compact bouquet reference.

Use the current scaled rose size as the basis:

```gdscript
COUNTER_PILE_ROSE_SCALE = 0.56
```

The center-to-center spacing should be substantially smaller than the rendered rose width, approximately **12–20 pixels**, to create heavy overlap.

Do not spread the bouquet across the full counter width.

### 2. Keep a single source of truth for slot positions

Update all current `_pile_offset()` callers to use the new bouquet slot lookup:

```gdscript
rebuild_pile()
animate_harvested_rose()
animate_counter_rose_to_client()
```

This is mandatory:

* a harvested rose must fly to its exact future bouquet slot;
* a sold rose must start its flight from the exact slot it occupied;
* pile rebuilding after stock/save restoration must produce the same layout.

Do not duplicate the slot coordinates in multiple methods.

### 3. Correct bouquet draw order

Do not rely blindly on:

```gdscript
counter_world.y + index
```

unless the slot ordering is explicitly designed back-to-front.

Roses visually lower in the bouquet must render in front of roses above them.

Add a small deterministic depth value per slot, or derive it safely from the slot’s local Y position.

The order must remain stable when two slots share similar Y coordinates. Use the slot index as a deterministic tie-breaker where necessary.

Keep the whole bouquet correctly layered relative to the counter and nearby world objects.

### 4. Preserve stock and removal semantics

Keep:

```gdscript
MAX_STOCK_PER_COUNTER = 10
```

Do not change:

* stock dictionaries;
* save/load format;
* counter capacity;
* client purchasing;
* harvested-rose flight duration;
* rose refund logic;
* counter access/navigation;
* nightfall dissolve duration.

`pile_index = stock - 1` must still identify the correct visual slot for a rose leaving toward a client.

`dissolve_all_piles()` may continue removing roses in reverse fill order. Update misleading “top of pile” comments to refer to bouquet slots rather than a vertical pile.

### 5. Keep the implementation local and economical

This is a focused visual-layout change.

Prefer modifying only:

```text
scripts/map/counter_stock_manager.gd
```

Do not create:

* a bouquet manager;
* a new scene;
* a resource type;
* procedural packing;
* runtime geometry calculations;
* random placement;
* per-frame updates.

A fixed 10-slot layout is the correct solution because counter capacity is fixed at 10.

### 6. Naming cleanup

Rename purely visual vertical-stack concepts where appropriate:

```text
_pile_offset → _bouquet_offset
COUNTER_PILE_BASE_Y → COUNTER_BOUQUET_BASE_OFFSET or equivalent
```

It is acceptable to retain broader “pile” terminology for stock-node collections if renaming it would create unnecessary churn.

Remove constants that become unused, especially:

```gdscript
COUNTER_PILE_ROSE_FRAME_HEIGHT
COUNTER_PILE_OVERLAP
```

Do not leave dead layout math.

---

## Visual requirements

At full stock, the result should read as one bouquet rather than ten individual stacked icons:

* approximately three roses across at the upper area;
* a dense middle cluster;
* two overlapping lower roses;
* one bottom/front rose forming the bouquet tip;
* no straight vertical column;
* no obvious rectangular grid;
* no large empty gap between flowers.

The bouquet should remain centered visually over the counter. Keep its lowest point high enough that it still appears placed **on** the counter rather than floating below or in front of the counter base.

Do not alter the rose texture or create new art.

---

## Manual verification

The user must test counters containing:

* 1 rose;
* 2 roses;
* 3 roses;
* 5 roses;
* 7 roses;
* 10 roses.

Verify:

1. Every partial count forms a coherent compact cluster.
2. Existing roses do not move when stock increases.
3. The 10-rose layout resembles the provided bouquet reference.
4. Lower roses correctly render in front of upper roses.
5. Harvested roses land exactly in the slot that appears.
6. Sold roses depart from their exact visible slot.
7. Rebuilding or loading stock recreates the identical bouquet.
8. Nightfall dissolution removes every visible rose correctly.
9. The bouquet remains correctly positioned on counters in all map locations.
10. No stock, client-sale, save/load, or navigation behavior changes.

## Final report

Report:

1. files changed;
2. the final 10 slot offsets;
3. the chosen fill order;
4. how depth ordering is determined;
5. confirmation that incoming/outgoing flight animations use the same slot lookup;
6. exact manual checks still required.

Do not claim runtime success because Godot was not run.
