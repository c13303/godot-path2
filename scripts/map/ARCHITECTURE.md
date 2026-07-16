# Map / Building Architecture

## BuildingManager
Owns:
- Scene-facing exported references, setup, lifecycle, day/night orchestration.
- Service/controller wiring and compatibility wrappers used by scenes, signals, saves, and older callers.
- High-level dispatch for spawning, garden rebuilds, client/merchant phases, save/progression integration.
- Exported `night_preparation_budget_ms`, sanitized during setup and passed to preparation/topology/route/runtime consumers.
- Phase side-effect callbacks after preparation succeeds or aborts.

Does not own:
- Detailed garden topology data structures.
- Build placement/removal/input behavior.
- Spawner route caches and garden-access scoring internals.
- Night/client preparation mode, readiness, or active preparation token.
- Shared budgeted-work generation.

Notes:
- Still large by design as the coordinator/facade. Keep wrappers when external Godot calls may depend on them.
- `is_night_preparation_ready()` remains as a public facade for save, spawning, merchant, and day-visitor callers.

## BuildingPreparationController
Owns:
- Night/client preparation mode.
- Night readiness.
- Active preparation token reference.
- Night/client preparation sequencing and stale-run checks.
- Completion/failure lifecycle publication through narrow manager callbacks.

Does not own:
- Runtime rebuild active/progress state.
- Work-token generation.
- Garden topology data.
- Spawner route caches.
- Run-phase progression.
- Exported scene configuration.

Notes:
- Uses focused services directly for scan, navigation sync, topology, invalidation, and route preparation.
- Hard night-preparation failure is fail-closed: readiness is not published and the active work remains until an authoritative phase reset.

## BuildingPreparationWorkGate
Owns:
- The single generation shared by budgeted topology/route work.
- Active diagnostic purpose for the current budgeted operation.
- Stale-token detection.

Does not own:
- Preparation mode or readiness.
- Dirty flags.
- Rebuild algorithms.
- Phase transitions.

Notes:
- `finish_work(token)` clears the purpose, so a finished token is no longer current.
- `cancel_current_work()` is reserved for authoritative seams such as phase reset, restore, and developer night skip.
- Owners cancelling their own work use `cancel_if_current(token)`, which prevents stale runtime/preparation work from cancelling newer work.

## BuildingInvalidationController
Owns:
- Navigation topology dirty state.
- Plant-layout dirty state.
- Runtime rebuild active/type/progress state.
- Runtime rebuild id.
- Active runtime work-token reference.

Does not own:
- Preparation mode or readiness.
- Shared work-token generation.

Notes:
- The shared work token cancels budgeted topology/route operations across preparation and runtime rebuilds.
- The runtime rebuild id still guards invalidation-controller active/progress fields from stale coroutines.

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
- Prepared Starpath descriptors for monster inbound routes and client inbound/outbound routes, including explicit start/goal cells.
- Queued group-flow rebuild requests, including explicit fence-blocking policy for route groups.

Does not own:
- Spawner source-of-truth dictionaries or spawn timing.

Notes:
- Uses agent/flow dynamic calls where external native or scene APIs are optional.

## PathPreviewController / PathPreviewRunner
Owns:
- Phase-specific Starpath descriptor selection, route signatures, low-frequency refresh, runner pooling, and phase cleanup.
- Distributed invisible Walk Animation sections for each ready route, sized from actual polyline length, 16 px stride distance, even step-pair allocation, and a 4x density reduction target.
- Runner-owned arc-length stamping, alternating left/right footprint offsets, local tangent orientation, bounded held/fading footprint slots per side, and section-boundary wrapping without counting the teleport as travelled distance.
- Deterministic shared-edge ownership for monster preview routes: matching `(A, B)` / `(B, A)` edges are assigned once by stable route order, and runners may travel through every section but only print on owned segments. Client preview routes do not merge shared edges; each inbound and outbound route owns all of its segments independently. A skipped unowned step retires that side's held footprint into its normal fade slot so route splits do not leave frozen fully-opaque stamps behind.

Does not own:
- Gameplay spawning, normal spawner/garden route groups, native agent registration, steering, A* routes, or map topology state.

Notes:
- Starpath uses the real SpawnerRouteService route groups. Monster previews are shown in afternoon and night; client inbound/outbound previews are shown only at dawn.
- The preview consumes prepared tile-center polylines as path data only; it does not draw the line or alter route generation.
- The footprint sheet uses authored client/monster colors directly, with alpha fading only.
- Default Starpath cadence is 16 px stride at 64 px/s: one footprint every 0.25 s, same-side replacement every 0.5 s, 6 px lateral offset per side, and 0.45 s linear fade for replaced same-side footprints. The default section target is one Walk Animation per 384 px instead of one per 96 px.
- Runtime agents register with AgentCellTracker through runtime-agent tracking wrappers only.

## AgentNavigationPhaseController
Owns:
- Runtime agent phase dictionaries for entry flow, A* in, eating/counter work, and escape.
- Game-specific traffic right-of-way groups/priorities and the central assignment/clear helpers used by navigation phase transitions.

Does not own:
- Garden topology or route cache state.
- Native traffic arbitration, cooldowns, or physical shove application.

Notes:
- BuildingManager exposes compatibility wrappers for older phase-related call sites.
- AgentSuspendService clears traffic while navigation is temporarily suspended and restores it only after entry-flow, A*, or escape navigation has been restored. TrafficRightOfWayResolver owns generic native arbitration between opaque traffic groups/priorities; SteeringSystem supplies lazy-flow-wait eligibility and submits accepted traffic requests to the existing smash pipeline. BuildingManager only forwards traffic state to native code and owns no traffic state or algorithm. Future agent kinds such as ducks are integrated game-side by assigning traffic state during their navigation phases; native traffic code should not need species-specific changes.

## DayVisitorMovementController
Owns:
- One passive daytime visitor's active node, native nav id, source spawner cell, target cell, arrival/wait/departure flags, A* arrival path assignment, bounded repath, pending night departure, and generic cleanup.

Does not own:
- Merchant interaction state, Builder roster state, claim allocation, save-file writing, generic pathfinding algorithms, or native route generation.

Notes:
- SeedMerchantController owns one instance. BuilderController owns one instance per active Builder.

## SeedMerchantController
Owns:
- One house-bound seed merchant runtime visitor, player proximity pause, shop/prompt positioning queries, purchase-phase closure, and home/evacuation requests.

Does not own:
- The reusable single-agent visitor movement details now handled by DayVisitorMovementController.

Notes:
- Seed merchant presence is granted by `AllyHousingController` from completed `house_merchant` records. The old unconditional `seedmerchent` spawner path is no longer authoritative.

## BuilderController
Owns:
- Temporary active Builder visitor collection, target-cell claims around each builder's home entrance/spot or a house work target, house-bound Builder spawning, fundamental Builder spawning, night home/evacuation orchestration, Builder movement/lifecycle state, and Builder removal notifications.

Does not own:
- Debug keyboard input, generic save-file writing, native pathfinding algorithms, flow-field generation, merchant interaction, WIP house task assignment, or Builder work progress.

Notes:
- Normal Builder presence is granted by `AllyHousingController` from completed `house_builder` records. Saved/desired builder counts and the dev roster increment are intentionally not authoritative.
- The fundamental Builder uses explicit `fundamental_builder_in`, `fundamental_builder_spot`, and `fundamental_builder_out` ally markers captured by LevelLoader as named spots, not normal spawners.
- AgentDefinitionService owns `builder.png` visual setup.
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
- ItemCatalog: `house_builder` and `house_merchant` are direct gem-purchase house placeables flagged by `special_placement_kind == &"house"` (`is_house_placeable`). Legacy `house` IDs normalize to `house_merchant`.
- BuildPlacementService: routes house items before the generic one-tile path (`_apply_house_placeable`): centralized housing availability + full six-cell validation (`house_placement_rejection` = HouseManager structural + per-cell buildable/occupancy), direct currency purchase, `HouseManager.build_player_house`, and immediate refund rollback if the commit unexpectedly fails. Also reserves every house presence cell against all other placeables in `is_placeable_occupied`.
- BuildPreviewController: `_draw_house_preview` renders six-cell coverage + the full house1.png sprite (aligned via `HouseManager.position_house_sprite`), tinted valid/invalid as one atomic footprint.
- BuildRemovalService: resolves one logical house from any presence cell, normalized/deduped by house id (`_house_removable_at_cell` / rectangle dedup), tears it down via HouseManager and refunds the house item currency.
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

## BambooHarvestController
Owns the authored permanent bamboo plants: the cell registry captured by LevelLoader, per-plant maturity, the visual instances, player-proximity harvesting, dawn regrowth, the `bamboo_states` save section, and each cell's static terrain-speed registration.

Does not own:
- General plant state or growth (bamboo is never a PlantManager plant), flow-field rebuilding, build placement algorithms, global currency storage, or save-file orchestration.

Notes:
- Bamboo is authored and permanent: absent from PlantManager, BuildingObjectManager, PlayerPlaceableDurabilityService, BuildRemovalService, garden topology and every damage/target system. No health, collision or removal callbacks. A harvest changes only maturity.
- The `0.5` slowdown belongs to the bamboo's presence, not its maturity: registered once per cell at setup and never touched again, so maturity changes never dirty navigation.
- Harvest range and scan cadence are reused from GroundDropManager (`pickup_radius_for_floor`, `PICKUP_CHECK_INTERVAL`), never re-declared. No Area2D or physics body.
- Reward is atomic: GameUI credits all five bamboo before the icons fly (`grant_currency_from_world_immediate`), so a save mid-flight cannot lose it. The controller never calls Progression directly.
- Restored dawn signals are ignored (`GameState.is_emitting_restored_phase_signals`), so loading a dawn save does not re-mature harvested bamboo.
- Set up synchronously in `BuildingManager._ready()`, which the scene orders ahead of `progression`, so the restore facade is always ready before Progression uses it.

## BambooPlantVisual
Owns only one bamboo's sprite, its frame (0 = immature, 1 = mature), its base-anchored idle dance, and its world-Y z_index. It owns no maturity rules, harvesting, currency, save state, dawn events, slowdown or build reservations.

Notes:
- bamboo.png is two horizontal frames; each frame is the artwork plus 4px of transparent padding on every side. The node origin is the cell centre (sort point), a pivot sits at the cell's bottom edge, and the centred sprite hangs half the artwork height above it — so the artwork's lower half covers the authored tile and its upper half rises above it. Offsets derive from the live texture and tile size, never hardcoded tile dimensions.
- The dance transforms the pivot, so sway/breathe rotate around the planted base. Phases are randomized per plant; no tween is allocated per frame.

## WorldDepthSort / placeable visual depth
`WorldDepthSort` owns the shared static-world depth rule: `z_index = int(world_base_y)`, with `z_as_relative = false`. Agents use the same world-Y convention, so plants and placeable runtime scenes sort from their logical base cell rather than from sprite dimensions.

Notes:
- Plant-bearing TileMapLayer visuals are configured for world-depth tile sorting by their owner (`PlantManager` for `plantz`, `BuildingObjectManager` for traversable plant/placeable tiles such as ronce and pasteque). Static plant z-index is assigned when the visual or layer is created, not every frame.
- Scene-based placeable visuals must use the scene root as the ground/base position. Child sprites may extend upward or sideways and should normally keep relative local depth; use child z offsets only for deliberate local layering such as foreground effects.
- Do not derive world depth from texture size, visual centre, or item-specific z-index constants. A future 32x64 plant should work by placing its root at the base cell and letting `WorldDepthSort` assign the root depth.
- Health bars, particles, held items, construction overlays, water fill, and other deliberate foreground/background effects keep their own local or absolute depth rules.

## LevelLoader
Captures the root-level `bamboo` container's direct Node2D children into stable floor cells (deduplicated, sorted by Y then X) before freeing the authored level shell. The markers are editor aids only: never mutated or reparented as gameplay visuals. A level with no container yields an empty list without error.

## TerrainSpeedModifierService / BuildingNavigationSyncService
`TerrainSpeedModifierService` owns terrain-speed composition and native uploads. Contributions are keyed by stable source id per cell/channel, then composed as strongest slowdown first, otherwise strongest speed-up. Native terrain speed lives on `SteeringSystemNative` and affects physical movement only; flow fields and async flow workers do not read or rebuild for terrain speed.

Channel `0` is the default terrain-speed channel. Channel `1` is currently assigned to the player profile so player-exempt slowdowns can upload a neutral channel-specific value while other agents fall back to channel `0`. The native side treats channels as integers and does not know which gameplay entity a channel represents.

`BuildingNavigationSyncService` still owns building/fence/player-blocking synchronization and registers tile/placeable/static-world-feature terrain contributions through `TerrainSpeedModifierService`. `BuildSystem` performs the early startup layer scan because it runs before `BuildingManager`, but it also uploads through `TerrainSpeedModifierService` using packed channel replacement rather than one native call per cell.

## Build placement
`BuildPlacementService.is_placeable_occupied` rejects permanent world-feature cells (`BuildingManager.is_permanent_world_feature_cell`, reached from BuildSystem's resolver) before actor-displacement logic — that bypass would otherwise let most non-plant placeables skip group occupancy. Covers one-cell buildings, plants, fences, turrets, counters, every house presence cell, drag placement and both previews. Bamboo cells stay walkable.
