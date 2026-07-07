We are continuing the BuildingManager cleanup.

Goal:
Batch 2 = move rose counter/shop logic out of `scripts/map/building_manager.gd`, and only remove compatibility wrappers that are proven safe to remove.

This is a refactor-only pass.
Do not change gameplay behavior.
Do not optimize logic unless required by the extraction.
Do not run Godot, tests, export, build, or compilation commands.

Project rules:
- Godot/GDScript strict typing is enabled.
- Avoid `:=` inference for numeric expressions, Dictionary/Array values, signal/call returns, mixed int/float math, nullable values, and dynamic values.
- Prefer explicit local types.
- Keep files readable.
- Do not create or grow 1000+ line files.
- Do not create generic abstractions without immediate use.
- Preserve behavior exactly.
- If unsure, keep the existing wrapper or method.

Current context:
`BuildingManager` has already had several responsibilities extracted into RefCounted services/controllers using the `setup(self)` pattern.
Follow that pattern.

Existing related services may include:
- `counter_stock_manager.gd`
- `morning_harvest_controller.gd`
- `client_sale_controller.gd`
- `seed_merchant_controller.gd`
- `building_manager.gd`

Before editing:
1. Inspect `scripts/map/building_manager.gd`.
2. Search all counter/shop/rose-related methods and variables.
3. Inspect existing counter/harvest/client-sale/merchant services.
4. Decide whether to extend an existing counter service or create a new focused one.
5. Do not duplicate existing responsibility.

Main target:
Move rose counter/shop logic out of `BuildingManager`.

Likely methods to review and move if they still live in `BuildingManager`:

```gdscript
_rose_shop_counter_cells()
_rose_shop_counter_cells_with_room()
counter_room_for_harvest()
serialize_counter_stock()
restore_counter_stock()
_consume_counter_rose()
_select_stocked_counter_target()
_animate_harvested_rose_to_counter()
_animate_counter_rose_to_client()
_can_install_new_counter()

Also search for related names:

counter
rose
shop
stock
harvest
client
merchant

Preferred destination:
If CounterStockManager already exists and is the best owner, extend it carefully.

Otherwise create:

scripts/map/rose_counter_service.gd

Suggested shape:

extends RefCounted
class_name RoseCounterService

var _manager: Node = null

func setup(manager: Node) -> void:
	_manager = manager

Responsibility:
Own rose counter/shop queries and stock operations.

It may coordinate:

discovering rose shop counter cells
resolving counter room for harvest
serializing counter stock
restoring counter stock
consuming counter roses
selecting stocked counter targets
checking whether a new counter can be installed
rose counter animation helpers, only if they are currently tightly coupled to counter stock behavior

Do not move unrelated client-sale behavior unless it is specifically counter-stock behavior.
Do not move unrelated morning-harvest behavior unless it is specifically counter-target / counter-stock behavior.
Do not move unrelated merchant behavior unless it is specifically counter installation / counter availability behavior.

Compatibility:
Keep thin wrappers in BuildingManager for any method that may be used by:

other scripts
scenes
signals
Callable
call()
editor wiring
saved references

Example wrapper style:

func serialize_counter_stock() -> Dictionary:
	return _rose_counter_service.serialize_counter_stock()

or, if extending CounterStockManager:

func serialize_counter_stock() -> Dictionary:
	return _counter_stock_manager.serialize_counter_stock()

Only delete wrappers if direct search proves:

there are no references;
the method is not likely called dynamically;
the method is not public API used by scenes/editor wiring;
deleting it does not reduce compatibility.

When in doubt, keep the wrapper.

Important behavior preservation:

Do not change stock data format.
Do not change save/load format.
Do not change room/counter selection priority.
Do not change animation timing, node ownership, z-index, tween behavior, or visual behavior.
Do not change client sale behavior.
Do not change morning harvest behavior.
Do not change seed merchant behavior.
Do not change counter install validation.
Do not change warnings/debug output unless a moved warning would become misleading.

Allowed manager-private coupling:
For this pass, it is acceptable for the new service to call existing _manager._private_method() methods if that avoids risky architecture rewrites.
Reducing private coupling is a later pass.
The priority here is responsibility extraction with exact behavior preservation.

Expected result:

BuildingManager loses most rose counter/shop implementation code.
BuildingManager keeps only compatibility wrappers for counter/shop methods where needed.
Counter/shop state ownership is clearer.
No new large file over 1000 lines.
No unrelated refactor.

Safety checks by reading/searching only:

Search all references to every moved method before and after moving.
Search for dynamic calls using method-name strings.
Search scenes/resources for method names if practical.
Verify preload/load paths.
Verify _ready() setup order if a new service is created.
Verify save/load methods still return the same structure.
Verify animation methods still have access to the same nodes and coordinate conversions.
Verify no method signature changed unless all call sites were updated safely.

Conservative wrapper cleanup:
After extraction, inspect the old wrappers in BuildingManager.

You may remove only wrappers that are obviously unused by direct search and are not likely called dynamically.

Do not remove wrappers for:

save/load
phase controllers
public-ish APIs
methods used by Callable/call/signals
methods that other nodes could reasonably call
methods whose name appears in scenes/resources

If wrapper cleanup becomes unclear, skip it and report that wrappers were intentionally retained.

Output required:

List changed files.
Explain what counter/shop logic moved.
Confirm which wrappers were preserved.
Confirm whether any wrappers were removed, with reason.
Mention any intentionally retained _manager._private coupling.
Mention manual test scenarios.

Manual test scenarios to suggest:

Harvest roses and verify they animate/move into counters correctly.
Save and reload counter stock.
Start client sale phase and verify clients consume stocked roses correctly.
Verify stocked counter target selection still behaves the same.
Verify counter installation rules still behave the same.
Verify merchant/morning/client phases still proceed.
Verify no new warnings/errors appear.