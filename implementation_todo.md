Refactor plant targeting / plant zones into dynamic garden clusters.

Context:
There is a major performance issue when placing a plant during gameplay.
Currently, PlantManager.plant_added triggers BuildingManager._on_plant_added(), which calls _rebuild_plant_zone_from_layer().
That rebuilds the full plant zone, pushes full walkable tiles to PathfinderNative, then rebuilds all spawner routes and flow fields.
This is wrong: adding one edible plant should not rebuild the whole monster navigation system.

Goal:
Separate edible plants from monster navigation zones.

Definitions:
- Plant = edible target.
- Garden = connected/near-connected cluster of plants.
- Garden area = plant cells + margin cells used for monster local navigation.
- Garden entry = walkable margin cell reachable from outside.
- Flow field = route from spawner to selected garden entry, not to individual plants.

Important constraints:
- Player can place plants anywhere.
- Adding a plant must be cheap.
- Do not rebuild all FFs on plant placement.
- C++ extension should stay generic. Do not refactor C++ unless absolutely required.
- No compile, no tests, I will do it.
- Keep existing behavior working as much as possible.
- Keep existing debug overlay but extend it if needed.

Current files likely involved:
- scripts/map/plant_manager.gd
- scripts/map/building_manager.gd
- scripts/map/plant_zone_overlay.gd
- maybe scripts/map/buildsystem.gd only if plant placement signal wiring requires it

Current bad path to remove:
PlantManager.add_plant()
→ plant_added
→ BuildingManager._on_plant_added()
→ _rebuild_plant_zone_from_layer()
→ _build_plant_zone()
→ pathfinder.set_walkable_tiles(full zone)
→ _rebuild_all_spawner_routes()
→ assign/request FF for all spawners

Required new architecture:

1. Add garden data in BuildingManager or a small dedicated GardenManager if cleaner.

A garden should track:
- id: int
- plant_cells: Dictionary[Vector2i, true]
- zone_tiles: Dictionary[Vector2i, true]
- margin_tiles: Dictionary[Vector2i, true]
- entry_cells: Array[Vector2i]
- dirty: bool
- reachable: bool
- version: int

Use dictionaries for cell sets.

2. PlantManager remains the source of edible plants.

Keep:
- add_plant(cell)
- remove_plant(cell)
- get_plant_cells()
- nearest_plant_cell()

Do not make PlantManager responsible for flow fields.

3. On plant added during day or gameplay:

BuildingManager._on_plant_added(cell) must:
- not call _rebuild_plant_zone_from_layer()
- update only garden cluster membership
- create a new garden if isolated
- add to one existing garden if adjacent/nearby
- merge gardens if the new plant connects several gardens
- mark affected garden dirty
- update debug overlay
- do not call pathfinder.set_walkable_tiles
- do not call _rebuild_all_spawner_routes
- do not call assign_flow_to_group/request_flow_to_group

Adjacency rule:
Use current PLANT_ZONE_MARGIN as connection/margin logic unless another constant already exists.
A plant joins a garden if it is within garden connection distance of at least one plant/zone tile.
Keep it simple and deterministic.

4. On plant removed:

BuildingManager._on_plant_removed(cell) must:
- remove the plant from its garden
- mark the garden dirty
- if garden is now empty, remove/invalidate it
- if all plants are gone, preserve current behavior: _start_escape_for_all_monsters()
- do not full rebuild all spawner FFs immediately unless no plants remain

For now, if removing one plant could split a garden into several clusters:
- acceptable first implementation: mark garden dirty and rebuild that garden locally from remaining plants at next night validation
- do not attempt expensive global rebuild on every removal

5. Night start behavior:

When switching from day to night:
- validate all dirty gardens once
- remove empty gardens
- recompute zone_tiles and margin_tiles per dirty garden
- compute entry_cells per dirty garden
- mark unreachable gardens as reachable=false
- rebuild spawner-to-garden route cache once

This is the only normal moment where plant/garden navigation is refreshed globally.

Find the day/night hook:
- scripts/gameState/gameState.gd
- scripts/ui/dayToggle.gd
- existing BuildingManager night/day signal if already wired

Do not invent a parallel day/night state if one already exists.

6. Garden entries:

A garden entry is a walkable margin cell.
It should be outside or at the border of the garden zone and reachable by monsters.
At minimum:
- entry candidate must be walkable
- no wall on it
- inside garden margin
- preferably nearest to spawner when choosing route

If no entry exists:
- garden.reachable = false
- spawners must ignore it
- debug overlay should show it differently if practical

7. Spawner target selection:

Replace the single global plant_zone_entry_cell concept with garden-specific targeting.

At monster spawn:
- get all gardens with edible plants and reachable entries
- choose a garden reachable from this spawner
- first implementation can choose nearest reachable garden by Manhattan distance from spawner to nearest entry
- optional but good: spread pressure by preferring gardens with fewer currently assigned monsters

Store on monster:
- spawner_cell
- garden_id
- garden_entry_cell
- current phase

Existing route flow:
Monster should follow spawner → selected garden entry FF/group.

Do not route spawner → individual plant.

8. Flow field cache:

Current _spawner_routes is keyed only by spawner_cell.
Change or extend it so routes can be keyed by:
- spawner_cell + garden_id

Example structure:
_spawner_garden_routes[spawner_cell][garden_id] = {
    "plant_group": int,
    "entry_cell": Vector2i,
    "entry_world": Vector2,
    "ready": bool,
    "garden_version": int
}

Do not rebuild all spawner/garden combinations if too many.
Acceptable first implementation:
- compute route lazily when a spawner first needs a garden
- cache it
- invalidate by garden.version or wall signature

On wall changes:
- wall changes may affect routes immediately
- invalidate route cache or request rebuilds
- keep existing escape FF behavior if possible
- do not confuse wall invalidation with plant invalidation

9. Monster behavior:

Monster spawn:
- select target garden
- assign monster to route group for spawner → garden entry
- move via FF toward entry

When monster reaches garden entry:
- switch to local plant targeting
- choose edible plant inside assigned garden
- use existing _start_astar_in-style behavior, but restrict target selection to the assigned garden’s plant_cells

When plant is eaten:
- remove plant through PlantManager
- if same garden still has edible plants, pick another plant in that garden
- if garden is empty, request another valid garden
- if another garden exists, route to its entry
- if no garden exists, fallback to current escape behavior

Do not leave monster frozen when its garden runs out.

10. Local A* inside garden:

Current _find_path_in_zone() uses global _plant_zone_tiles.
Update it to use the assigned garden zone tiles.

Options:
- pass garden_id to _find_path_in_zone()
- resolve garden zone set from garden_id
- snap endpoints to nearest tile inside that garden only

Important:
A monster assigned to garden A must not path to a plant in garden B during local phase unless reassigned.

11. Existing plant zone API compatibility:

Existing overlay calls:
- get_plant_zone_tiles()
- get_plant_zone_margin_tiles()
- get_plant_zone_route_tiles()

Keep these methods for compatibility, but make them aggregate all gardens:
- get_plant_zone_tiles() returns all garden zone tiles
- get_plant_zone_margin_tiles() returns all garden margin tiles
- get_plant_zone_route_tiles() returns all garden entries and/or active route cells

Add optional new debug getters if useful:
- get_garden_debug_cells()
- get_garden_entry_cells()
- get_unreachable_garden_cells()
- get_dirty_garden_cells()

12. Debug overlay:

Extend scripts/map/plant_zone_overlay.gd minimally.

It should still work if only old getters exist.

Useful visualization:
- all garden zone tiles
- entries more opaque
- unreachable gardens different color if available
- dirty gardens different color if available

Do not overbuild text labels unless easy.

13. Remove or deprecate global plant zone rebuild:

Keep _build_plant_zone() only if needed for initial migration, but stop using it as the normal runtime path.

Replace:
- _plant_zone_tiles
- _plant_zone_margin_tiles
- _plant_zone_built

with either:
- aggregated compatibility caches rebuilt from gardens
or:
- methods that aggregate garden dictionaries on demand

Do not let plant_added call _rebuild_plant_zone_from_layer() anymore.

14. Startup behavior:

On startup:
- PlantManager.initialize_from_layer()
- build initial gardens from all existing plants
- validate gardens
- initialize spawner data
- do not break existing startup_loading_progress behavior

It is acceptable to build all gardens once at startup.

15. During night plant placement:

First implementation rule:
- plant is registered and garden data is marked dirty
- do not recompute routing immediately
- monsters may ignore newly placed night plants until next night validation
- if plant joins an already validated active garden, it may be eaten only if easy to support without route recompute

Make this behavior explicit in code with a clear boolean/flag, not accidental.

16. Performance requirements:

Plant placement must be O(local garden work), not O(all spawners × FF rebuild).
No calls to:
- pathfinder.set_walkable_tiles
- _rebuild_all_spawner_routes
- assign_flow_to_group
- request_flow_to_group

from the plant_added path.

17. Safety checks:

Handle:
- no gardens
- no plants
- garden with no entries
- spawner with no reachable garden
- monster assigned to deleted/empty garden
- plant target removed before monster reaches it
- wall changes after route cached

Fallbacks:
- if no target garden: do not spawn monster from that spawner
- if current garden invalid: reassign
- if no reassignment possible: escape / idle / despawn according to existing behavior

18. Naming:

Prefer names like:
- _gardens
- _garden_by_plant_cell
- _dirty_gardens
- _next_garden_id
- _validate_dirty_gardens()
- _build_gardens_from_plants()
- _add_plant_to_gardens(cell)
- _merge_gardens(ids)
- _select_garden_for_spawner(spawner_cell)
- _get_or_create_spawner_garden_route(spawner_cell, garden_id)
- _resolve_plant_target_for_agent_in_garden(agent, from_cell, garden_id)

19. Keep C++ extension unchanged.

Do not add garden concepts to C++.
C++ should still only receive:
- generic walkable tile sets
- blockers
- flow group goals

The main fix is GDScript invalidation and routing architecture.

20. Acceptance criteria:

After refactor:
- placing one plant does not freeze the game
- placing one plant does not rebuild every spawner FF
- plants can be placed anywhere
- isolated plants become their own garden
- nearby plants belong to the same garden
- gardens can merge
- monsters spawn at night and choose a reachable garden
- monsters go to garden entry, then eat plants inside that garden
- if their garden is empty, they retarget another garden
- if no plants remain, existing escape/no-plant behavior still works
- existing wall placement flow-field updates remain functional
- existing debug plant-zone overlay still displays useful navigation information