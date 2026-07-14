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

Does not own:
- Spawner source-of-truth dictionaries or spawn timing.

Notes:
- Uses agent/flow dynamic calls where external native or scene APIs are optional.

## AgentNavigationPhaseController
Owns:
- Runtime agent phase dictionaries for entry flow, A* in, eating/counter work, and escape.

Does not own:
- Garden topology or route cache state.

Notes:
- BuildingManager exposes compatibility wrappers for older phase-related call sites.

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
- The authoritative house registry (one logical HouseRecord per house: id, catalog item_id, sprite, entrance, five blocking cells, authored/player-built, removable, destructible, under-construction) plus the presence->house lookup covering all six cells (`get_house_at_presence_cell`), so any footprint cell resolves to one logical house.
- Authored-house discovery (`house_`-prefixed Sprite2D under the spawner container) and normalization: sprite bottom-edge snapping, entrance-top-edge z-index (so an agent in the walkable doorway draws in front), batched footprint-wall stamping, paired spot-marker snapping. Authored houses reserve their presence but are never player-built (not removable/refundable/destructible).
- Player-built house lifecycle: validation (`house_structural_rejection`), atomic runtime creation (`build_player_house`/`create_house`: five-cell wall stamp + immediate collision + one hard-topology invalidation + one construction visual + one durability target), normal unbuild (`remove_player_built_house`) and hostile no-refund teardown (`remove_player_built_house_no_refund`), both via one shared `_teardown_house`.
- Sprite positioning shared with the preview (`position_house_sprite`), the health-bar anchor above the roof (`get_house_health_bar_world_position`), and player-built house save records (`serialize_player_built_houses`/`restore_player_built_houses`).

Does not own:
- Flow-field generation, garden rebuilding, general building placement, inventory/currencies, build-menu state, the generic per-cell buildable/occupancy validation (BuildPlacementService), durability health storage (PlayerPlaceableDurabilityService), the save file itself (Progression), or merchant AI.

Notes:
- Authored preparation is a static entry point (`prepare_authored_houses`) invoked by LevelLoader on the off-tree level instance BEFORE spawner bindings are captured, because a paired spot (seedmerchent_spot) becomes the merchant's stored spot_cell.
- Reaches BuildingManager only through public wrappers: `get_construction_overlay`, `set_player_navigation_cell_blocked`, `is_walkable_cell`, `has_floor_cell`, `has_wall_cell`, `cell_center`, `register_player_built_house_durability`, `remove_house_durability_record`, and `get_building_invalidation_controller().after_walkability_changed(...)`.
- Footprint blockers use the transparent wallz tile (15,0) — the same invisible blocker as the reservoir base — resolved from the live tile_set, never hardcoded source ids. The blocker atlas never identifies the logical house; that is always the presence registry.

## House build-system integration
- ItemCatalog: `house` is one inventory-backed, non-fixed-stock placeable (wall icon frame 3, house1.png world/preview texture) flagged by `special_placement_kind == &"house"` (`is_house_placeable`). It flows automatically into starting-items, the merchant list (inventory-backed), and `NightReward.item_id`; it is added to the hammer menu category.
- BuildPlacementService: routes house items before the generic one-tile path (`_apply_house_placeable`): full six-cell validation (`house_placement_rejection` = HouseManager structural + per-cell buildable/occupancy), consume exactly one inventory unit, `HouseManager.build_player_house`, and immediate refund rollback if the commit unexpectedly fails. Also reserves every house presence cell against all other placeables in `is_placeable_occupied`.
- BuildPreviewController: `_draw_house_preview` renders six-cell coverage + the full house1.png sprite (aligned via `HouseManager.position_house_sprite`), tinted valid/invalid as one atomic footprint.
- BuildRemovalService: resolves one logical house from any presence cell, normalized/deduped by house id (`_house_removable_at_cell` / rectangle dedup), tears it down via HouseManager and refunds exactly one `house` item.
- PlayerPlaceableDurabilityService: one entrance-keyed target on the logical `houses` layer per player-built house (never five wall targets); validity/destruction/health-bar position resolve through the BuildingManager house facade.
- Progression: `runtime_houses` save section (save version 5; versions 1-4 load with no houses), restored after layers/reindex and before durability.

## BuildingConstructionOverlay / BuildingConstructionIndicator
Owns:
- The single flow-construction progress state machine (dirty/quiet window -> budgeted walkability rebuild -> lazy flow queue drain -> async worker idle -> complete).

Notes:
- The overlay ghosts per-cell wall/turret/fence tiles AND drives external sprite visuals (houses) that share the same progress. A house uses one BuildingConstructionIndicator child (one bar, 50% ghost) instead of five per-cell bars. Processing stays active while either pending cells or house indicators remain.
