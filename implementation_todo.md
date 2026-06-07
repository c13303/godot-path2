Task: refactor placeable item architecture and implement first building item support.

Context:
- Godot 4 project.
- Existing toolbar items include:
  - weapon items, for example sword, bomb
  - gun items, for example water
  - wall item
- Existing wall placement already works.
- Existing plants already behave like floor-placeable objects.
- New goal: support a new family of placeable items called buildings.
- Buildings are placed on the floor like current plants, not like walls.
- First building subtype to support: lamp.
- Lamp will later create a light source.
- Future building subtypes:
  - edible plants
  - defensive plants / tower-defense style plants
  - other floor objects
- Do not compile.
- Do not run tests.
- Do not execute the project.
- I will test manually.

Main architecture decision:
- Do not make buildings behave like weapons or guns.
- Do not make buildings behave as walls.
- Introduce/standardize a generic item behavior type: placeable.
- Walls, lamps, plants, defensive plants are all placeable items.
- Their gameplay identity is defined by placeable metadata.

Required item model:
Use this conceptual structure:

item_type:
- weapon
- gun
- placeable

For placeable items:

placeable_kind:
- wall
- building

For building items:

building_subtype:
- edible_plant
- lamp
- defensive_plant

Important semantic distinction:
- wall = terrain obstruction
- building = floor object
- plant = building subtype, not a wall
- lamp = building subtype, not a wall

Current wall item should become or be treated as:
- item_type: placeable
- placeable_kind: wall

Current plants should become or be treated as:
- item_type: placeable
- placeable_kind: building
- building_subtype: edible_plant

New lamp item should be:
- item_type: placeable
- placeable_kind: building
- building_subtype: lamp

Do not break existing weapon/gun behavior.

Files likely involved:
- scripts/items/item_catalog.gd
- scripts/ui/item_slot.gd
- scripts/ui/game_ui.gd
- build/placement system scripts
- plant manager scripts
- tilemap/world scripts where wall/plant/building placement is handled

First step:
- Inspect the current item catalog.
- Find how sword, bomb, water, wall are defined.
- Find how current plants are defined/placed.
- Find how toolbar buttons decide behavior.
- Find how BuildSystem or equivalent places wall/plant/building tiles.
- Preserve current working behavior while generalizing it.

Refactor goal:
- The toolbar/input code should not special-case “wall” as the only placeable.
- It should ask the catalog/item definition whether an item is placeable.
- If item_type == placeable, route it to the placement/build system.
- The build system should use item metadata to know which layer and runtime manager to update.

ItemCatalog requirements:
Add or normalize metadata for placeable items.

Each placeable item definition should support:
- id
- label/name
- frame/icon frame
- item_type = "placeable"
- placeable_kind
- building_subtype optional
- target_layer
- atlas coords or tile source data
- occupies_cell: bool
- blocks_movement: bool
- blocks_projectiles: bool
- runtime_id optional

Suggested shape, adapted to the existing style:

wall:
- id: "wall"
- item_type: "placeable"
- placeable_kind: "wall"
- target_layer: "wallz"
- occupies_cell: true
- blocks_movement: true
- blocks_projectiles: true
- runtime_id: ""

edible_plant:
- id: "edible_plant"
- item_type: "placeable"
- placeable_kind: "building"
- building_subtype: "edible_plant"
- target_layer: "plantz" or existing plant layer
- occupies_cell: true
- blocks_movement: false
- blocks_projectiles: false
- runtime_id: "edible_plant"

lamp:
- id: "lamp"
- item_type: "placeable"
- placeable_kind: "building"
- building_subtype: "lamp"
- target_layer: "buildings"
- occupies_cell: true
- blocks_movement: false by default
- blocks_projectiles: false by default
- runtime_id: "lamp"

Do not move existing plant tiles to another layer unless the current architecture makes it trivial.
Keeping edible plants on the current plant layer is acceptable.
Lamps should use the existing buildings layer if available.

Toolbar icon:
- Add a lamp item icon frame in the item catalog.
- Use the next available frame in the existing items atlas.
- Do not edit the image asset unless required.
- If the lamp icon graphic does not exist yet, still define the item with a safe placeholder frame and make this easy to change.

Placement behavior:
- Selecting wall still places wall.
- Selecting edible plant still places plant if already available.
- Selecting lamp places a lamp floor object on the buildings layer.
- Building placement should use the same preview/placement interaction as wall/plant where possible.
- Do not duplicate placement code for every subtype.

BuildSystem requirements:
Refactor placement into generic placeable placement.

Expected flow:

1. User selects item.
2. If item_type is weapon or gun, existing behavior remains.
3. If item_type is placeable, pass full item definition to BuildSystem.
4. BuildSystem reads:
   - target_layer
   - tile source/atlas data
   - occupies_cell
   - placeable_kind
   - building_subtype
   - runtime_id
5. BuildSystem validates placement.
6. BuildSystem writes tile to correct TileMapLayer.
7. BuildSystem notifies runtime managers.

Placement validation:
- Respect existing wall placement rules.
- Respect existing plant placement rules.
- For buildings, check that target cell is valid and not already occupied by an incompatible object.
- Do not allow lamps to overwrite walls unless existing placement rules explicitly allow overwrite.
- Do not allow obvious duplicate objects on the same cell.
- If there is already a plant/building in the target cell, either reject placement or replace cleanly, depending on existing behavior.
- Prefer preserving existing behavior.

Runtime manager split:
- Do not overload PlantManager with lamp logic.
- Keep PlantManager for edible plant tracking.
- Add a new manager for building objects, for example:
  - BuildingObjectManager
  - BuildingManager
  - PlaceableObjectManager

Preferred name:
- BuildingObjectManager

BuildingObjectManager responsibilities:
- Track placed building objects by cell.
- Store item_id / runtime_id / building_subtype per cell.
- Provide add_building(cell, item_def)
- Provide remove_building(cell)
- Provide get_building(cell)
- Provide has_building(cell)
- Provide clear/reset if needed on level reload.
- For now, handle lamp registration in a simple placeholder-safe way.

Lamp runtime behavior:
- For this refactor, lamp placement must create/register a runtime lamp object cleanly.
- If LightSource2D already exists in the project, instantiate/add it at the lamp cell center.
- If LightSource2D does not exist yet, create a minimal placeholder path/hook without overbuilding.
- Do not implement complex lighting here if not already present.
- The lamp system should be ready to connect to the fake light source component later.

Recommended lamp handling:
- On lamp placed:
  - BuildingObjectManager stores the lamp cell.
  - If a light scene/resource exists, create it at cell center.
  - Parent the runtime light under a stable world node, for example a `buildingObjects` or `runtimeBuildings` node.
- On lamp removed/replaced:
  - remove the runtime light node.
  - remove the cell from BuildingObjectManager.

If there is no clean runtime parent:
- Add a simple Node2D named `buildingObjects` or `runtimeBuildings` under the world/main scene.
- Do not attach building runtime nodes under Camera2D.
- Do not attach building runtime nodes under UI.

Important:
- Tile placement and runtime object registration must stay synchronized.
- If the tile is removed, the runtime object must also be removed.
- If placement fails, no runtime object should be created.
- If runtime object creation fails, fail safely and avoid corrupting placement state.

Post-placement hooks:
Refactor current plant special-casing into a generic post-placement function.

Example conceptual behavior:

After successful placement:
- If placeable_kind == "wall":
  - update wall/path/projectile masks if existing code already does this.
- If building_subtype == "edible_plant":
  - PlantManager.add_plant(cell)
- If building_subtype == "lamp":
  - BuildingObjectManager.add_building(cell, item_def)
- If building_subtype == "defensive_plant":
  - BuildingObjectManager.add_building(cell, item_def), even if behavior is not implemented yet

On removal/replacement:
- If previous cell had plant:
  - PlantManager.remove_plant(cell)
- If previous cell had building:
  - BuildingObjectManager.remove_building(cell)
- If previous cell had wall:
  - update wall/path/projectile masks if existing code already does this

Do not add defensive plant behavior yet.
Only make the data/model extensible.

Layer rules:
- wallz:
  - walls
  - movement blocking
  - projectile blocking
- plantz:
  - edible plants if currently used
  - probably non-blocking
- buildings:
  - lamps
  - defensive plants later
  - other floor objects later

If current project already has these layers:
- use existing names exactly.
- do not rename layers unless necessary.

If current project has different names:
- adapt to current names.
- keep the semantic distinction.

Collision/pathfinding:
- Do not change pathfinding behavior for lamps unless item metadata says blocks_movement.
- Do not make lamps projectile blockers by default.
- Do not make edible plants blockers unless already existing behavior requires it.
- Walls remain blockers.
- Keep wall mask/pathfinding updates separated from building placement.

Data-driven future:
Design so future placeables can be added mostly in ItemCatalog:
- lamp
- edible_plant
- defensive_plant
- turret
- trap
- machine
- door
- decoration

Avoid hardcoding specific IDs everywhere.
Some subtype branching is acceptable in manager hooks, but keep it centralized.

Expected minimal hardcoded branching:
- BuildSystem generic placeable handling
- PlantManager for edible_plant
- BuildingObjectManager for lamp/building subtypes

Avoid:
- toolbar-specific checks like `if selected_item == "wall"`
- duplicated lamp placement code inside UI
- placing lamps as walls
- putting lamp logic into PlantManager
- putting light logic into ItemSlot or GameUI
- creating a different placement system for each building subtype
- changing weapon/gun behavior
- large unrelated refactors

Editor/data requirements:
- Item definitions should be easy to edit.
- Lamp should appear as a toolbar item if the toolbar is data-driven from ItemCatalog.
- If toolbar list is hardcoded, add lamp to it cleanly.
- Keep icon frame configurable through ItemCatalog.

Save/load:
Inspect current save/load behavior for placed walls/plants.
- If placed objects are already saved by TileMap state, make sure lamp tile placement uses same persistence path.
- If PlantManager data is saved separately, do not break it.
- If BuildingObjectManager needs save/load now, add minimal support consistent with current architecture.
- If no building save/load exists yet, at least structure the manager so save/load can be added cleanly.
- Do not implement a huge save refactor unless necessary.

Manual validation I will perform:
- Existing sword still works.
- Existing bomb still works.
- Existing water gun still works.
- Existing wall placement still works.
- Existing plant behavior still works.
- Lamp appears in toolbar or can be selected through item system.
- Lamp places a tile/object on the floor.
- Lamp does not behave like a wall.
- Lamp does not block movement unless explicitly configured.
- Lamp does not block projectiles unless explicitly configured.
- Removing/replacing lamp cleans runtime state.
- No compile/test/run needed from you.

Deliverable:
- Implement the refactor in the existing codebase.
- Keep changes focused.
- Add concise notes in the final response:
  - files changed
  - new item metadata fields
  - how to add a new building subtype later
  - anything I must configure manually in the editor

Do not:
- Do not compile.
- Do not run tests.
- Do not launch Godot.
- Do not execute the project.
- Do not add normal maps.
- Do not implement complex lighting.
- Do not create real dynamic lights unless an existing LightSource2D system already makes this trivial.
- Do not over-engineer resource classes unless the current project already uses them for items.