## Task: Fix incorrect “Not enough counters!” tutorial at day-2 dawn

Read `AGENTS.md` first and follow it strictly.

Do not run Godot, tests, compilation, export, or build commands. The user will test manually.

### Bug

Very rarely, at day-2 dawn, the tutorial displays:

```text
Not enough counters!
```

when it should display:

```text
Place counters
```

### Confirmed root cause

In:

```text
scripts/misc/tutorial.gd
```

the tutorial uses:

```gdscript
_has_placed_rose_shop_counter
```

This is a historical latch meaning that a counter existed at some point.

It becomes `true`:

* during `_resolve_nodes()` if a counter is found;
* in `_on_building_added()` when a counter is placed.

It never returns to `false` if that counter is removed, destroyed, replaced, or disappears through another runtime transition.

As a result, the tutorial can reach this invalid state:

```text
current counter count == 0
_has_placed_rose_shop_counter == true
```

At dawn, with grown roses and no counter capacity, `_current_key()` then selects:

```gdscript
KEY_ADD_COUNTERS_TO_SELL_ROSES
```

instead of:

```gdscript
KEY_PLACE_SHOP
```

The tutorial is using historical state where it needs authoritative live gameplay state.

---

# Required behavior

Tutorial selection must use the **current number of existing rose-shop counters**.

The invariant is:

```text
Current counter count == 0
    → “Place counters”

Current counter count > 0 and at least one counter has room
    → “Harvest roses”

Current counter count > 0 and every counter is full
    → “Not enough counters!”
```

This must remain true regardless of whether a counter existed earlier in the run.

In particular:

```text
The player placed a counter, then removed or lost it
    → the game must return to “Place counters”
```

Do not add special-case logic only for day 2. Fix the incorrect state ownership so the rule remains correct on every dawn.

---

# Implementation requirements

## 1. Remove the historical counter-presence latch

In `scripts/misc/tutorial.gd`, remove:

```gdscript
var _has_placed_rose_shop_counter: bool = false
```

Remove the counter-specific initialization that sets it during `_resolve_nodes()`.

Remove the counter-specific mutation that sets it in `_on_building_added()`.

Do not replace it with another cached boolean.

Do not add a `building_removed` handler that tries to maintain a duplicate counter count or presence flag.

The existing building/counter system already owns the authoritative current state.

## 2. Query the live counter count

Use the existing authoritative API:

```gdscript
BuildingManager.rose_shop_counter_count()
```

This delegates to `CounterStockManager`, which queries the current registered `rose_shop_counter` buildings.

Add a small, explicitly typed helper in `tutorial.gd` if it keeps the tutorial decision readable, for example:

```gdscript
func _rose_shop_counter_count() -> int:
	...
```

Prefer the `BuildingManager` public method.

Only add a narrow fallback through `BuildingObjectManager.count_buildings_by_item_id()` if initialization ordering genuinely requires it.

Do not inspect TileMap atlas coordinates directly from the tutorial.

Do not duplicate counter-discovery logic.

## 3. Rewrite the shop-prompt condition

`_should_prompt_place_shop()` must reflect current state rather than historical state.

Its meaning should become equivalent to:

```gdscript
return _rose_shop_counter_count() <= 0
```

However, handle unresolved initialization safely.

If the authoritative manager is temporarily unavailable, do not incorrectly emit `"Not enough counters!"`. Suppress the economy tutorial until the nodes are resolved rather than guessing that counters exist.

Update the function comment: it is no longer a permanently consumed “one-time” historical step. It represents the current requirement to build the first available counter.

## 4. Preserve immediate tutorial refreshes

When a `rose_shop_counter` is added, the tutorial must still refresh immediately.

Therefore, keep counter handling in `_on_building_added()`, but only for refreshing:

```gdscript
elif item_id == COUNTER_ITEM_ID:
	_refresh()
```

Also connect to `BuildingObjectManager.building_removed` and refresh when the removed item is `COUNTER_ITEM_ID`.

This removal signal is only a UI invalidation trigger. It must not maintain duplicated counter state.

Use a focused handler such as:

```gdscript
func _on_building_removed(_cell: Vector2i, item_id: String) -> void:
	if item_id == COUNTER_ITEM_ID:
		_refresh()
```

Do not alter the historical behavior of unrelated tutorial latches such as the thorn-turret tutorial.

## 5. Make the dawn branch explicit

Review the dawn decision around:

```text
scripts/misc/tutorial.gd
_current_key()
```

The effective ordering for grown roses must be clear:

```text
1. Counter capacity exists
   → KEY_HARVEST_ROSE

2. No capacity and current counter count is zero
   → KEY_PLACE_SHOP

3. No capacity and one or more counters exist
   → KEY_ADD_COUNTERS_TO_SELL_ROSES
```

Avoid relying on misleading helper names or comments.

Do not add a hardcoded `_is_day_two()` condition to the core decision.

Day 2 uses the arrows for `KEY_PLACE_SHOP`, but the gameplay requirement itself must be based on live counter state.

## 6. Verify the high-priority alert path

Review:

```text
scripts/map/dawn_harvest_controller.gd
_show_counter_room_alert_if_blocked()
```

It currently guards the `"add counters"` alert with:

```gdscript
_manager.rose_shop_counter_count() <= 0
```

Preserve that invariant:

```text
The high-priority “Not enough counters!” alert must never fire when zero counters exist.
```

Do not change this controller unless a small consistency fix is actually necessary.

Search all emitters of:

```gdscript
"tutorial.add_counters_to_sell_roses"
```

and verify that every emitter requires at least one currently existing counter.

---

# Required regression scenarios

Review the code against all of these cases:

### Fresh day-2 dawn, no counters

```text
grown roses > 0
counter count == 0
```

Expected:

```text
KEY_PLACE_SHOP
```

The day-2 hammer/counter arrows must work.

### Empty counter available

```text
grown roses > 0
counter count > 0
remaining counter capacity > 0
```

Expected:

```text
KEY_HARVEST_ROSE
```

### All counters full

```text
grown roses > 0
counter count > 0
remaining counter capacity == 0
```

Expected:

```text
KEY_ADD_COUNTERS_TO_SELL_ROSES
```

### Only counter removed before dawn

Sequence:

```text
place one counter
remove or destroy it
reach dawn with grown roses
```

Expected:

```text
KEY_PLACE_SHOP
```

It must not retain historical placement state.

### Counter removed during dawn

Sequence:

```text
dawn begins with one counter
remove the counter
```

Expected:

* tutorial refreshes immediately;
* current counter count becomes zero;
* tutorial changes to `KEY_PLACE_SHOP`.

### Walk over a grown rose with zero counters

Expected:

* `DawnHarvestController` must not raise the high-priority `KEY_ADD_COUNTERS_TO_SELL_ROSES` alert;
* the normal `KEY_PLACE_SHOP` tutorial remains authoritative.

### Save/load

Review both:

```text
save with zero counters
save with one or more counters
```

Expected after load:

* tutorial derives the answer from restored current buildings;
* no stale historical counter boolean is involved.

---

# Scope limits

* Do not redesign the complete tutorial system.
* Do not introduce a generic state framework.
* Do not add persistent save data for this condition.
* Do not change tutorial text or translations.
* Do not alter counter capacity or harvesting rules.
* Do not perform unrelated cleanup.
* Keep the fix local, readable, and production-oriented.

---

# Final report

Report:

1. the exact files changed;
2. the stale state removed;
3. the authoritative live query now used;
4. how counter addition/removal refreshes the tutorial;
5. confirmation that every `"Not enough counters!"` path now requires at least one currently existing counter;
6. any initialization-order caveat found during implementation.

Do not claim runtime testing because Godot must not be launched.
