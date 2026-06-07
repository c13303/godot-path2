You are working on a Godot 4 project.

Goal:
Clean the current placeable item architecture and add a simple generic light-source system for night-time lamps.

Important constraints:
- Do not compile.
- Do not run tests.
- Do not delete unrelated code.
- Preserve current behavior: wall, rose, and lamp must still be placeable exactly as now.
- Keep implementation simple.
- Do not over-engineer with resources/classes unless clearly useful.
- Avoid hardcoding "lamp" in gameplay logic except in the item definition.
- No visual polish beyond the needed light source.

Current relevant scripts:
- scripts/items/item_catalog.gd
- scripts/map/buildsystem.gd
- scripts/map/building_object_manager.gd
- scripts/map/plant_manager.gd
- scripts/misc/day_night_colors.gd
- scripts/gameState/gameState.gd

Current mess:
- Placeables currently use item_type = "placeable"
- They also use placeable_kind = "wall" / "building"
- Some use building_subtype = "edible_plant" / "lamp"
- This is unclear and should be replaced by a clear placeable type system.

New architecture:
Every placeable item must have:

type = "wall" | "plant" | "furniture" | "turret" | "trap"

Meaning:
- wall: wall-like construction, currently the existing wall item
- plant: edible/growing plant-like item, currently rose
- furniture: passive placed object, currently lamp
- turret: future defensive shooting object
- trap: future triggered damage object

Keep item_type = "placeable" if the existing UI/inventory logic depends on it.
But for placeable routing, use the new type field.

Shared placeable item properties should remain simple:
- id
- name
- item_type
- category
- frame
- type
- target_layer
- atlas
- occupies_cell
- blocks_movement
- blocks_projectiles
- runtime_id if still useful

Type-specific properties should be plain optional fields:
- wall may later have integrity
- plant may later have edible/growth properties
- furniture may be passive
- turret may later have damage/range/fire_rate
- trap may later have trigger/damage/cooldown

Optional capability properties are allowed:
- light_source: number of tiles of light radius
Example:
"light_source": 3

This means:
- any placeable item with light_source > 0 emits light at night
- this is generic and must not be tied to lamp id
- lamp is currently the only item using it

Refactor ItemCatalog:
1. Replace placeable_kind/building_subtype usage with type.
2. Current item definitions should become:

wall:
- item_type: "placeable"
- type: "wall"
- target_layer: "wallz"
- atlas: existing wall atlas
- occupies_cell: true
- blocks_movement: true
- blocks_projectiles: true

rose:
- item_type: "placeable"
- type: "plant"
- target_layer: "plantz"
- atlas: existing rose atlas
- occupies_cell: true
- blocks_movement: false
- blocks_projectiles: false
- runtime_id: "rose"

lamp:
- item_type: "placeable"
- type: "furniture"
- target_layer: "buildings"
- atlas: existing lamp atlas
- occupies_cell: true
- blocks_movement: false
- blocks_projectiles: false
- runtime_id: "lamp"
- light_source: 3

3. Remove building_subtype from item definitions.
4. Remove placeable_kind from item definitions if no longer needed.
5. Keep backwards compatibility only if some existing code still needs it temporarily, but prefer replacing all usage now.

Refactor BuildSystem:
Current function to change:
_after_placeable_placed(cell, placeable_def)

Replace building_subtype routing with type routing.

Expected behavior:
- type == "plant":
    call plant_manager.add_plant(cell) if available
- type == "furniture":
    call building_object_manager.add_building(cell, placeable_def) if available
- type == "turret":
    call building_object_manager.add_building(cell, placeable_def) if available
- type == "trap":
    call building_object_manager.add_building(cell, placeable_def) if available
- type == "wall":
    no runtime object for now, just the tile placement
- unknown type:
    do nothing extra, but do not crash

Keep all current placement validation behavior:
- Cannot place over occupied cell
- Cannot place over existing wall/plant/building
- Cannot place on occupied character/player/monster cell
- Preview still works
- Tile placement still works
- Existing wall layer still works
- Existing plant layer still works
- Existing buildings layer still works

Important:
Do not make BuildSystem know about lamps or lights.
BuildSystem should only place and route by type.

Refactor BuildingObjectManager:
Current issues:
- It stores building_subtype
- It creates lamp runtime only if building_subtype == "lamp"
- _default_building_def_for_existing_tile searches for placeable_kind == "building"

Change this manager so it stores generic placed non-wall objects:
- furniture
- turret
- trap
Possibly also plants later, but for now plants still use PlantManager.

Keep class name BuildingObjectManager for now unless renaming is easy and safe. Do not perform a large rename if risky.

In add_building(cell, item_def):
- Read item_id from item_def.id
- Read type from item_def.type
- Read runtime_id from item_def.runtime_id or item_id
- Store:
    item_id
    type
    runtime_id
    light_source if present
- If the item has light_source > 0, create/register a light runtime.
- Do not check item_id == "lamp".
- Do not check building_subtype.

Runtime node:
- Replace current marker-only lamp runtime with a real Node2D containing a PointLight2D created in code.
- Keep it simple; no new scene required unless it is clearly cleaner.
- The runtime node should be positioned at the center of the tile cell.
- Use buildings.map_to_local / to_global as currently done.

Light behavior:
- Any placed item with light_source > 0 creates a PointLight2D.
- Radius in pixels = light_source * tile_size.
- Determine tile_size from the buildings TileMapLayer tile_set if possible.
- If tile size cannot be determined safely, use a sane fallback like 16 px.
- Use a circular gradient texture for the PointLight2D if possible.
- If creating a gradient texture is too annoying, use a generated ImageTexture with a soft circular alpha gradient.
- The light should be warm, simple, Stardew-like.
- The light should be visible/enabled only at night.
- It should sync with /root/GameState.is_night.
- It should listen to /root/GameState.mode_changed if available.
- It should update immediately on creation so lamps placed during night light up immediately.

Recommended PointLight2D setup:
- enabled = GameState.is_night
- color = warm yellow/orange
- energy around 0.7 or 0.8
- texture_scale or texture size should roughly match radius
- shadow_enabled = false for now

Important:
The current day/night system uses CanvasModulate in DayNightColors.
The new PointLight2D should work with that. Do not modify DayNightColors unless strictly needed.
Do not replace the day/night system.

Light lifecycle:
- When a light-source item is placed:
    create runtime light node
- When the item is removed:
    free the runtime node
- When BuildingObjectManager.clear() is called:
    free all runtime nodes
- When initialize_from_layer() scans existing tiles:
    recreate runtime light nodes for existing matching furniture/building tiles

Update _default_building_def_for_existing_tile:
- It should no longer search placeable_kind == "building".
- It should find placeable item definitions where:
    item_type == "placeable"
    type is one of ["furniture", "turret", "trap"]
    target_layer == "buildings"
    atlas matches the existing tile atlas coords
- This allows lamp tiles already present on the buildings layer to be recognized after initialization.

Plant behavior:
- Rose must still go through PlantManager.
- Do not move rose to BuildingObjectManager in this task.
- Remove building_subtype == "edible_plant" logic and replace it with type == "plant".

Wall behavior:
- Wall must still only place the wall tile on wallz.
- Wall does not need BuildingObjectManager.
- Wall does not need runtime node.
- Wall still blocks movement/projectiles according to its item definition.

Target layers:
Keep current target_layer strings:
- wall -> "wallz"
- rose -> "plantz"
- lamp -> "buildings"

Do not introduce new TileMapLayer exports unless necessary.
Use existing:
- wallz
- plantz
- buildings
- previewbuild

Expected resulting item definitions conceptually:

wall:
{
    "id": "wall",
    "name": "Wall",
    "item_type": "placeable",
    "category": "blocks",
    "frame": 3,
    "type": "wall",
    "target_layer": "wallz",
    "atlas": Vector2i(11, 1),
    "occupies_cell": true,
    "blocks_movement": true,
    "blocks_projectiles": true,
    "runtime_id": ""
}

rose:
{
    "id": "rose",
    "name": "Rose",
    "item_type": "placeable",
    "category": "plants",
    "frame": 5,
    "type": "plant",
    "target_layer": "plantz",
    "atlas": Vector2i(0, 0),
    "occupies_cell": true,
    "blocks_movement": false,
    "blocks_projectiles": false,
    "runtime_id": "rose"
}

lamp:
{
    "id": "lamp",
    "name": "Lamp",
    "item_type": "placeable",
    "category": "furniture",
    "frame": 4,
    "type": "furniture",
    "target_layer": "buildings",
    "atlas": Vector2i(1, 0),
    "occupies_cell": true,
    "blocks_movement": false,
    "blocks_projectiles": false,
    "runtime_id": "lamp",
    "light_source": 3
}

Clean-up requirements:
- Remove building_subtype logic from BuildSystem and BuildingObjectManager.
- Remove placeable_kind logic where possible.
- Keep helper methods in ItemCatalog simple and compatible.
- Do not touch unrelated combat, UI, pathfinder, or player code unless required by this refactor.
- Do not create a large abstract framework.
- Keep names explicit and boring.

Acceptance checklist:
- Sword/bomb/water still remain non-placeable as before.
- Wall still places on wallz.
- Rose still places on plantz and registers with PlantManager.
- Lamp still places on buildings.
- Lamp now creates a light source with radius 3 tiles.
- Lamp light is off during day.
- Lamp light is on during night.
- Lamp light reacts when GameState switches day/night.
- Existing buildings layer lamps can be reconstructed by BuildingObjectManager.initialize_from_layer().
- Removing/replacing a lamp frees its runtime light node.
- No code path depends on building_subtype.
- No gameplay code checks item_id == "lamp" to create light.