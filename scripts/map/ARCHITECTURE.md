# Map / Building Architecture

## BuildingManager
Owns:
- Scene-facing exported references, setup, lifecycle, day/night orchestration.
- Service/controller wiring and compatibility wrappers used by scenes, signals, saves, and older callers.
- High-level dispatch for spawning, garden rebuilds, client/merchant phases, save/progression integration.

Does not own:
- Detailed garden topology data structures.
- Build placement/removal/input behavior.
- Spawner route caches and garden-access scoring internals.

Notes:
- Still large by design as the coordinator/facade. Keep wrappers when external Godot calls may depend on them.

## GardenTopologyService
Owns:
- Garden dictionaries, plant-zone caches, walkable-map cache, dirty/empty garden state.

Does not own:
- Agent retargeting, route scoring, spawning, or scene lifecycle.

Notes:
- This is the source of truth for garden topology state.

## GardenAccessResolver
Owns:
- Garden entry/exit access scoring and memoized entry resolution.

Does not own:
- Garden topology storage or route cache ownership.

Notes:
- Reads manager-owned low-level queries through explicit accessors.

## SpawnerRouteService
Owns:
- Spawner escape routes, spawner-to-garden route groups, exit-wall escape groups, route cache stats.
- Queued group-flow rebuild requests, including explicit fence-blocking policy for preview-only groups.

Does not own:
- Spawner source-of-truth dictionaries or spawn timing.

Notes:
- Uses agent/flow dynamic calls where external native or scene APIs are optional.

## PathPreviewController / PathPreviewRunner
Owns:
- Preview-only client/monster route descriptors, temporary flow groups, route signatures, low-frequency refresh, runner pooling, and phase cleanup.
- Distributed invisible Walk Animation sections for each ready route, sized from actual polyline length, 16 px stride distance, even step-pair allocation, and a 4x density reduction target.
- Runner-owned arc-length stamping, alternating left/right footprint offsets, local tangent orientation, bounded held/fading footprint slots per side, and section-boundary wrapping without counting the teleport as travelled distance.
- Deterministic shared-edge ownership for preview routes: matching `(A, B)` / `(B, A)` edges are assigned once by stable route order, and runners may travel through every section but only print on owned segments. A skipped unowned step retires that side's held footprint into its normal fade slot so route splits do not leave frozen fully-opaque stamps behind.

Does not own:
- Gameplay spawning, normal spawner/garden route groups, native agent registration, steering, A* routes, or map topology state.

Notes:
- Preview groups are allocated through AgentManager but never receive agents. Flow builds use SpawnerRouteService's normal one-request-per-frame queue with explicit policy: clients block fences, monsters ignore fences.
- The preview consumes prepared tile-center polylines as path data only; it does not draw the line or alter route generation.
- The footprint sheet uses authored client/monster colors directly, with alpha fading only.
- Default Starpath cadence is 16 px stride at 64 px/s: one footprint every 0.25 s, same-side replacement every 0.5 s, 6 px lateral offset per side, and 0.45 s linear fade for replaced same-side footprints. The default section target is one Walk Animation per 384 px instead of one per 96 px.
- Runtime agents register with AgentCellTracker through runtime-agent tracking wrappers only.

## AgentNavigationPhaseController
Owns:
- Runtime agent phase dictionaries for entry flow, A* in, eating/counter work, and escape.

Does not own:
- Garden topology or route cache state.

Notes:
- BuildingManager exposes compatibility wrappers for older phase-related call sites.

## DayVisitorMovementController
Owns:
- One passive daytime visitor's active node, native nav id, source spawner cell, target cell, arrival/wait/departure flags, A* arrival path assignment, bounded repath, pending night departure, and generic cleanup.

Does not own:
- Merchant interaction state, Builder roster state, claim allocation, save-file writing, generic pathfinding algorithms, or native route generation.

Notes:
- SeedMerchantController owns one instance. BuilderController owns one instance per active Builder.

## SeedMerchantController
Owns:
- Seed merchant phase state, player proximity pause, shop/prompt positioning queries, purchase-phase closure, and merchant-specific save restoration.

Does not own:
- The reusable single-agent visitor movement details now handled by DayVisitorMovementController.

Notes:
- The seed merchant still uses its authored `seedmerchent_spot` via the existing `SpawnerBinding.spot_cell` path.

## BuilderController
Owns:
- Persistent desired Builder count, temporary active Builder visitor collection, target-cell claims around `builder_spot` or a house work target, day-start spawn batching, K-key roster increment handling through the manager facade, night departure orchestration, Builder save/load state, Builder movement/lifecycle state, and Builder removal notifications.

Does not own:
- Debug keyboard input, generic save-file writing, native pathfinding algorithms, flow-field generation, merchant interaction, WIP house task assignment, or Builder work progress.

Notes:
- Builder count persists independently from live Builder nodes. Builders spawn from the exact `seedmerchent` binding, reuse its `seedmerchent_exit` escape route through `spawner_cell` metadata, and claim deterministic unique tiles within the bounded Builder spot radius.
- AgentDefinitionService owns `builder.png` visual setup. LevelLoader captures direct authored `_spot` children, including `builder_spot`, before the loaded level shell is freed. CppDebugOptions owns the K developer shortcut and delegates to `BuildingManager.add_builder_for_dev()`.
- HouseBuilderWorkController uses focused BuilderController APIs to release idle claims, claim reachable work cells, assign normal A* paths, detect arrival, and return Builders to idle.

## GardenRetargetController
Owns:
- Retarget queue, plant-target reverse index, stale-target checks, retarget profiling.

Does not own:
- Garden topology source data or route groups.

Notes:
- Some manager interaction remains direct because retargeting coordinates several manager-owned subsystems.

## BuildSystem Controllers / Services
Owns:
- Build input, preview, drag, placement, removal, and build-mode direction state.

Does not own:
- Night/day map preparation or agent navigation behavior.

Notes:
- BuildModeStateController is wired to BuildSystem, not BuildingManager.

## HouseManager
Owns:
- Fixed house geometry rules (3x2 blocking footprint on the entrance cell; 3x3 visual sprite with a purely-visual overhang row). The single geometry authority: five blocking cells + the walkable entrance form the six-cell presence (`get_presence_cells` / `get_blocking_cells`); no other file recomputes house offsets.
- The authoritative house registry (one logical HouseRecord per house: id, catalog item_id, sprite, entrance, five blocking cells, authored/player-built, removable, destructible, persistent WIP/completed status, and construction order) plus the presence->house lookup covering all six cells (`get_house_at_presence_cell`), so any footprint cell resolves to one logical house.
- Authored-house discovery (`house_`-prefixed Sprite2D under the spawner container) and normalization: sprite bottom-edge snapping, entrance-top-edge z-index (so an agent in the walkable doorway draws in front), batched footprint-wall stamping, paired spot-marker snapping. Authored houses reserve their presence but are never player-built (not removable/refundable/destructible).
- Player-built house lifecycle: validation (`house_structural_rejection`), atomic runtime creation (`build_player_house`/`create_house`: five-cell wall stamp + immediate collision + one hard-topology invalidation + one durability target + WIP task notification), normal unbuild (`remove_player_built_house`) and hostile no-refund teardown (`remove_player_built_house_no_refund`), both via one shared `_teardown_house`.
- House completion (`complete_house`): swaps only persistent status and the existing sprite texture from WIP to completed. It does not alter footprint, navigation, durability, health, or registry identity.
- Sprite positioning shared with the preview (`position_house_sprite`), the health-bar anchor above the roof (`get_house_health_bar_world_position`), and player-built house save records (`serialize_player_built_houses`/`restore_player_built_houses`).

Does not own:
- Flow-field generation, garden rebuilding, general building placement, inventory/currencies, build-menu state, the generic per-cell buildable/occupancy validation (BuildPlacementService), durability health storage (PlayerPlaceableDurabilityService), runtime Builder work progress/assignment (HouseBuilderWorkController), the save file itself (Progression), or merchant AI.

Notes:
- Authored preparation is a static entry point (`prepare_authored_houses`) invoked by LevelLoader on the off-tree level instance BEFORE spawner bindings are captured, because a paired spot (seedmerchent_spot) becomes the merchant's stored spot_cell.
- Reaches BuildingManager only through public wrappers: `get_house_builder_work_controller`, `set_player_navigation_cell_blocked`, `is_walkable_cell`, `has_floor_cell`, `has_wall_cell`, `cell_center`, `register_player_built_house_durability`, `remove_house_durability_record`, and `get_building_invalidation_controller().after_walkability_changed(...)`.
- Footprint blockers use the transparent wallz tile (15,0) — the same invisible blocker as the reservoir base — resolved from the live tile_set, never hardcoded source ids. The blocker atlas never identifies the logical house; that is always the presence registry.

## House build-system integration
- ItemCatalog: `house` is one inventory-backed, non-fixed-stock placeable (wall icon frame 3, house1.png world/preview texture) flagged by `special_placement_kind == &"house"` (`is_house_placeable`). It flows automatically into starting-items, the merchant list (inventory-backed), and `NightReward.item_id`; it is added to the hammer menu category.
- BuildPlacementService: routes house items before the generic one-tile path (`_apply_house_placeable`): full six-cell validation (`house_placement_rejection` = HouseManager structural + per-cell buildable/occupancy), consume exactly one inventory unit, `HouseManager.build_player_house`, and immediate refund rollback if the commit unexpectedly fails. Also reserves every house presence cell against all other placeables in `is_placeable_occupied`.
- BuildPreviewController: `_draw_house_preview` renders six-cell coverage + the full house1.png sprite (aligned via `HouseManager.position_house_sprite`), tinted valid/invalid as one atomic footprint.
- BuildRemovalService: resolves one logical house from any presence cell, normalized/deduped by house id (`_house_removable_at_cell` / rectangle dedup), tears it down via HouseManager and refunds exactly one `house` item.
- PlayerPlaceableDurabilityService: one entrance-keyed target on the logical `houses` layer per player-built house (never five wall targets); validity/destruction/health-bar position resolve through the BuildingManager house facade.
- Progression: `runtime_houses` save section (save version 5; versions 1-4 load with no houses), restored after layers/reindex and before durability. Current records include WIP/completed status and construction order. Older records without status load as completed.

## HouseBuilderWorkController / HouseWorkProgressOverlay
Owns:
- WIP house task assignment in deterministic construction order, one-Builder-per-house assignment state, unsaved runtime work seconds, bounded work-cell candidate selection around HouseManager presence cells, pause/move busy-work timing, night interruption/resumption, invalid task cancellation, and completion requests back to HouseManager.
- HouseWorkProgressOverlay owns only the visible Builder work progress bar attached above the WIP house sprite. It does not calculate progress and does not own health or topology state.

Does not own:
- House registry/status/order/sprites, Builder roster/lifecycle/path internals, durability health, save records, footprint geometry, generic A*, navigation topology rebuilds, or build UI.

Notes:
- WIP status is persistent and saved. Runtime Builder work seconds are preserved through night in memory but intentionally not saved; loading a WIP house restarts its work at 0 seconds.
- Builder work bars are separate from BuildingConstructionOverlay. Runtime houses no longer display the short technical topology progress bar, so the player sees only the 20-second Builder work bar.
- Night cancels active assignments and hides bars before BuilderController sends Builders through the normal night departure path. WIP queue order and runtime progress are preserved.

## BuildingConstructionOverlay / BuildingConstructionIndicator
Owns:
- The single flow-construction progress state machine (dirty/quiet window -> budgeted walkability rebuild -> lazy flow queue drain -> async worker idle -> complete).

Notes:
- The overlay ghosts per-cell wall/turret/fence tiles for technical navigation readiness. House Builder work uses HouseWorkProgressOverlay instead, so house gameplay construction is not mixed with topology readiness.
