Task: Integrate the procedural Kraken as a complete buildable

Read and follow AGENTS.md before modifying anything.

The standalone Kraken laboratory already exists and is the visual source of truth. Reuse the tested procedural Kraken visual and its four animations:

idle;
grab/retract;
eating;
digestion.

Do not rewrite the procedural tentacle from scratch. Preserve kraken_lab.tscn as a functional standalone test scene.

This pass integrates the Kraken into actual gameplay as a proper buildable.

Required gameplay

The buildable is:

Item id: kraken
English name: Kraken Vine
French name: Liane Kraken
Price: 20 gems
Build menu: gardening tool
Placement: watersource cells only
Bulk building: forbidden

Behavior:

The Kraken waits in its idle animation.
When ready, it acquires one monster inside its radius.
It extends toward that monster.
At contact, the monster is removed from active navigation and captured by the tip.
The Kraken retracts the monster toward its base.
The Kraken eats it for exactly three seconds.
The monster dies using the normal monster death explosion.
Exactly one gem is propelled from the Kraken toward the nearest valid dry floor.
The Kraken enters its digestion/cooldown animation.
Once digestion ends, it returns to idle and can capture again.

Do not implement this as a turret weapon. The Kraken does not shoot and must not use TurretSystem, FightSystem projectiles, spray logic, gun logic or TurretData.

Existing codebase architecture to respect

Relevant existing owners include:

scripts/items/item_catalog.gd
scripts/shop/toolbuild.gd
scripts/ui/game_ui.gd

scripts/map/buildsystem.gd
scripts/map/build_input_controller.gd
scripts/map/build_preview_controller.gd
scripts/map/build_placement_service.gd
scripts/map/build_removal_service.gd
scripts/map/building_object_manager.gd

scripts/map/building_manager.gd
scripts/map/agent_cell_tracker.gd
scripts/map/agent_suspend_service.gd
scripts/map/monster_death_controller.gd
scripts/map/ground_drop_manager.gd

scripts/combat/turret_system.gd
scripts/entities/character.gd
scripts/map/level_loader.gd
scripts/spawning/level_spawn_config.gd

The current code already provides generic behavior for:

build affordability;
currency spending;
full-price removal refunds;
refund currency flight animations;
placement effects;
removal progress;
player-built provenance;
hostile destruction without refunds;
save/load reconstruction from building tiles;
building-added and building-removed signals;
runtime building nodes;
destructible placeables;
monster registry cleanup;
ground currency collection and HUD animations.

Reuse these systems. Do not duplicate them inside Kraken code.

Before coding, identify:

The reusable Kraken visual scene and script created by the laboratory pass.
Its actual public methods and signals.
The scene containing TurretSystem and FightSystem.
The active demo level and its LevelSpawnConfig.
The appropriate runtime-parent node used by BuildingObjectManager.

Adapt method names to the implementation that actually exists. Do not guess paths or APIs when they can be inspected.

Do not run Godot, tests, compilation, builds or exports. The user tests manually.

1. Kraken catalog definition

Add a proper kraken placeable to ItemCatalog.

The semantic definition should be equivalent to:

"kraken": {
    "id": "kraken",
    "name": "Kraken Vine",
    "currency": &"gem",
    "type": "placeable",
    "category": "trap",
    "price": 20,

    "frame": TEMPORARY_ICON_FRAME,

    "target_layer": "traversable_buildings",
    "atlas": INVISIBLE_BUILDING_MARKER_ATLAS,

    "occupies_cell": true,
    "blocks_movement": false,
    "blocks_player_movement": false,
    "blocks_projectiles": false,

    "placement_surface": &"water_source",

    "drag_buildable": false,
    "pad_skip_preview": true,

    "runtime_id": "kraken",
    "building_visual_scene": KRAKEN_VISUAL_SCENE,
    "kraken_data": KRAKEN_DATA,

    "max_health": 1,
    "max_stack": 999,
}

Use the exact field names selected by the implementation, but retain these semantics.

Important:

Category must be trap, not turret.
It must not contain turret_data.
It must not have a terrain speed multiplier.
It must not block movement or projectiles.
It must not trigger navigation topology rebuilds.
The watersource tile remains present underneath it.
The building marker should be invisible; the procedural scene supplies the entire visible object.

BuildingObjectManager.BUILDING_CATEGORIES already includes trap.

Build-menu inclusion

Update ItemCatalog.get_gardening_shop_item_ids() so trap buildables are included in gardening mode.

Place Kraken in a deliberate order, for example:

rose
imperial_seed
ronce
pasteque
turret_epine
kraken

Do not put Kraken in the hammer menu or merchant inventory shop.

Availability and price configuration

Update the appropriate defaults in:

scripts/map/level_loader.gd
scripts/spawning/level_spawn_config.gd

Kraken must be a recognized tool-shop buildable.

Also update the active demo level’s actual LevelSpawnConfig so:

tool_shop_available_items contains &"kraken"
tool_shop_prices[&"kraken"] == 20

Do not rely only on ItemCatalog.price if the level overrides tool-shop prices.

Do not change unrelated level availability.

Localization

Following the existing translation storage convention, add:

item.kraken = Kraken Vine
item.kraken = Liane Kraken

for the relevant languages.

2. Temporary build-picker icon

No dedicated Kraken inventory icon has been supplied.

Use one 32×32 frame from kraken.png as the temporary build-picker icon. Frame 0 is acceptable as the temporary icon.

Do not edit items.png and do not generate new art.

If toolbuild.gd currently only supports numbered frames from items.png, add narrow data-driven support for an optional custom item icon:

icon_texture
icon_frame_size
icon_frame

The normal frame behavior must remain unchanged for every existing item.

Keep this generic and small. Do not add if item_id == "kraken" UI code.

The build-picker slot must display:

Kraken icon;
price 20;
gem currency icon;
normal affordable/unaffordable state;
translated item name.
3. Water-only placement

BuildPlacementService.is_valid_placeable_cell() currently rejects watersource cells before evaluating the item definition.

Replace this global assumption with a data-driven surface rule.

Supported semantics should include:

buildable_floor — default existing behavior
water_source   — Kraken behavior

For a normal/default placeable, preserve current behavior exactly.

For placement_surface == &"water_source":

the cell must contain a watersource tile;
the normal buildable-floor requirement must not be applied;
grass requirements must not be applied;
walkable-floor requirements must not be applied;
walls, plants, fences and other buildings must still prevent placement;
relevant group-node occupants must still prevent placement;
the watersource tile itself must not count as an occupying building;
placing the Kraken must not erase the watersource tile;
placing it must not cause a hard navigation/flow-field rebuild.

Add a specific invalid-placement notification or tutorial alert following current localization conventions:

Must be built in water

Do not hardcode item_id == "kraken" into the generic validation path.

Occupancy

Only one Kraken or other placeable may occupy the same building cell.

The invisible marker on traversable_buildings must be enough for:

collision with future placement attempts;
save/load;
build counting;
unbuilding;
hostile destruction;
runtime reconstruction.
4. No bulk building

Kraken must behave as a single-placement buildable.

Required behavior:

Mouse press places exactly one Kraken.
Mouse drag must never create a Kraken rectangle.
Gamepad confirmation places exactly one Kraken.
There must be no anchor/second-confirm bulk preview.
Holding or dragging must not purchase multiple Krakens.

Use the existing data-driven opt-out:

"drag_buildable": false

Do not create a Kraken-specific exception in BuildInputController.

Do not alter bulk behavior for existing placeables.

5. Generic visual-scene runtime support

The tested kraken_visual.tscn must be reused for both:

the placed runtime object;
the build preview.

Do not duplicate its eight segment sprites in another scene.

BuildingObjectManager

Add a narrow generic optional visual-scene contract rather than a large Kraken-specific construction block.

For example:

building_visual_scene: PackedScene

When a building definition has this field:

Instantiate the scene.
Position its immutable base at the cell center.
Parent it under the established runtime parent.
Set appropriate world z-order.
Optionally call a setup method if the visual exposes one.
Store it in _runtime_nodes_by_cell.
Ensure normal remove_building() frees it.

Add a public typed accessor equivalent to:

func get_runtime_node(cell: Vector2i) -> Node2D

KrakenSystem will use this accessor to reach the visual associated with a cell.

Preserve current turret, reservoir and light behavior. Do not refactor those unrelated systems as part of this task.

Avoid overlapping runtime registration branches: one cell must retain one authoritative primary runtime visual node.

Runtime visual expectations

A placed Kraken:

shows all eight frames simultaneously;
anchors segment 0 exactly at the cell center;
enters idle immediately;
does not contain targeting or monster-death logic;
remains the same visual component used by kraken_lab.tscn.
6. Full Kraken build preview

Extend BuildPreviewController to support the same optional visual scene.

The Kraken preview must show the entire eight-segment Kraken, not:

only frame 0;
the invisible marker tile;
a line;
an endpoint;
a single disc;
a static icon.

Required preview:

segment 0 is centered on the hovered watersource cell;
all eight body segments are visible;
the Kraken plays its idle pose, or a representative full idle pose;
it does not acquire or attack monsters;
it is rendered at preview z-order;
clearing or changing the build selection frees the preview cleanly;
moving the cursor does not leak old visual nodes.

The preview must turn visibly invalid/red when the hovered cell is not a legal Kraken placement cell, especially when it is not water.

Keep this support data-driven through the visual-scene field. Do not add a large Kraken-only preview implementation.

The preview must remain a single preview even though the procedural tentacle extends beyond one tile.

7. Kraken gameplay data

Create a focused resource:

res://scripts/combat/kraken/kraken_data.gd
res://scripts/combat/kraken/kraken.tres

Suggested class:

extends Resource
class_name KrakenData

At minimum, expose:

@export var capture_range: float
@export var target_scan_interval: float
@export var digestion_seconds: float
@export var forced_drop_currency: StringName = &"gem"

Use the tested visual’s actual maximum extension as the initial capture_range.

Do not allow the gameplay capture radius and visual maximum reach to silently differ. Configure the visual from the resource or validate that both values match.

Use the visual’s existing timing for:

extension + retraction = approximately 0.7 seconds
eating = exactly 3 seconds

For digestion, use a clearly centralized gameplay value. If no value has been established by the lab implementation, use 5.0 seconds as a temporary tunable default.

Do not scatter Kraken tuning constants across systems.

8. Dedicated KrakenSystem

Create:

res://scripts/combat/kraken/kraken_system.gd

Add one KrakenSystem node to the gameplay scene, close to the existing combat-system ownership. A sibling of TurretSystem under FightSystem is appropriate if that matches the actual scene structure.

Do not put Kraken state inside:

TurretSystem;
BuildingManager;
BuildingObjectManager;
FightSystem;
BuildSystem.

KrakenSystem owns Kraken gameplay state by building cell.

Registration

At _ready():

resolve FightSystem;
resolve BuildingObjectManager;
resolve BuildingManager;
resolve BuildSystem if needed for preview/hover range rendering;
connect to building_added;
connect to building_removed;
inspect already registered buildings and register existing Krakens.

This must work for:

newly built Krakens;
authored/pre-existing Krakens;
restored saves;
runtime reconstruction.
Per-Kraken state

Use an explicit state record, equivalent to:

READY
EXTENDING
RETRACTING
EATING
DIGESTING

A state record should contain only what is required, such as:

cell
visual weak reference
KrakenData
state
target weak reference
target nav_id
target resume state
scan timer
capture flag

Do not use nested uncancellable await chains.

The visual signals may drive transitions, but KrakenSystem remains the gameplay authority.

Pause behavior

Respect the existing combat pause state.

While FightSystem.is_paused():

Kraken gameplay timers must not advance;
visuals in active gameplay animations must not advance;
captured monster positions must remain stable;
no targets may be acquired.

Add a small pause API to KrakenVisual only if needed.

The standalone laboratory must remain functional.

9. Efficient target acquisition

Do not call:

get_tree().get_nodes_in_group("monsters")

once per Kraken per frame.

The game targets hundreds of agents.

Extend AgentCellTracker with a reusable spatial query based on its existing:

cell -> agent instance ids

index.

Provide an API equivalent to:

func get_agents_in_world_radius(
    center: Vector2,
    radius: float,
    category: StringName
) -> Array[Node2D]

Requirements:

inspect only nearby indexed cells;
perform an exact distance check before returning an agent;
return only valid non-deleting agents;
return only the requested category;
exclude tracker-suspended agents;
do not allocate excessive temporary data;
do not expose the tracker’s internal dictionaries.

Kraken target scans should occur at the configured interval, approximately 10 times per second, not every frame.

Stagger initial scan timers between Kraken cells so many Krakens do not all scan on the same frame.

Eligible target

A Kraken may capture only an actual monster.

Reject:

clients;
merchants;
sheep;
dead or queued-for-deletion agents;
agents with invalid navigation IDs;
agents already reserved or captured by another Kraken;
drowning agents;
turret-eating agents;
agents currently eating a plant;
externally controlled/captured agents.

Select the nearest eligible monster inside the radius.

Reserve the target immediately when an attack begins so two Krakens cannot choose it.

No line-of-sight restriction is required in this pass. Do not inherit turret build-range restrictions or turret LOS logic.

10. Moving-target extension

The laboratory target was static, but gameplay monsters move.

During EXTENDING:

retain a weak reference to the target;
update the visual target position while the monster remains valid;
keep the target reserved;
do not suspend the target before actual contact;
clamp the visual extension to the Kraken’s maximum reach.

Add a visual API equivalent to:

func update_grab_target_global_position(target_position: Vector2) -> void

if the tested visual currently accepts only the initial target position.

If the target:

dies;
leaves the tree;
becomes externally controlled;
leaves capture range beyond a small reasonable tolerance;

then cancel the attack, release the reservation and return the Kraken to idle.

Do not teleport the tip to a stale position.

11. Generic external agent capture

At grab_contacted, the monster must stop participating in normal movement and tile interactions.

Do not simply set its global_position while native navigation and cell interactions continue underneath.

Extend the existing shared suspension architecture instead of creating Kraken-only copies.

AgentSuspendService

Add generic methods equivalent to:

func suspend_agent_for_external_capture(nav_id: int, agent: Node2D) -> Dictionary
func resume_agent_after_external_capture(
    nav_id: int,
    agent: Node2D,
    resume_state: Dictionary
) -> void

Suspension must:

Capture the current resume state.
Detach native flow and path navigation.
Remove the agent from active navigation-phase collections that would continue driving it.
Suspend it in AgentCellTracker.
Prevent drowning and normal tile interaction while captured.
Mark the agent as externally captured.

Resume must:

Remove external-capture state.
Re-enable cell tracking.
Refresh its tracked cell.
Restore or retarget navigation using the existing resume machinery.
Avoid restoring stale paths when the topology has changed.

Do not unregister the monster from the monsters group during capture. Night completion must continue to count it until it actually dies.

Expose this service through a small public BuildingManager getter if necessary. Do not add a large Kraken API surface to BuildingManager.

AgentCellTracker

Add explicit suspension support.

A suspended captured agent must:

be removed from cell buckets;
be removed from water candidates;
not receive transition checks;
not be returned by spatial queries;
remain registered enough to resume cleanly;
be fully removed normally if it dies while suspended.
FlowAgent

Add a small generic external-capture state, not a Kraken-specific animation system.

An API equivalent to:

func begin_external_capture() -> void
func end_external_capture() -> void
func is_external_capture_active() -> bool

While externally captured:

normal external damage should not kill the monster before the scripted eating completion;
it must not start drowning;
it must not become another turret target;
its node remains visible;
its position remains controlled by KrakenSystem.

Update turret target filtering so turrets do not waste shots on externally captured monsters.

Keep these semantics generic enough for future scripted captures, but do not build a large status framework.

12. Grab, retract and eating lifecycle
Contact

When the visual emits contact:

Verify the Kraken, visual and target are still valid.
Capture the target’s resume state.
Suspend it through the generic external-capture service.
Mark the state as captured.
Keep the target attached to frame/segment 7.
Retraction

Every gameplay frame during retraction:

target.global_position = visual.get_tip_global_position()

Frame 7 remains the actual grabbing point.

Do not use a separate invisible grab marker unless the tested visual already exposes an intentional anchor at segment 7.

Eating

When retraction finishes:

transition the visual to eating;
keep the monster at get_capture_anchor_global_position();
allow the existing visual contraction and struggle animation to play;
do not call the monster’s existing start_eating() semantic, because that means the monster itself is eating something;
do not apply incremental damage during the three seconds.

At the visual’s eating completion signal, execute one authoritative scripted death.

13. Forced normal death plus one gem

The eaten monster must explode using the normal monster death effect, but its drop must always be exactly one gem.

Do not:

roll the ordinary seed/gem probability;
directly call queue_free();
duplicate monster registry cleanup in KrakenSystem;
directly update the gem progression value.

Extend MonsterDeathController with a narrow authoritative operation equivalent to:

func remove_dead_monster_with_forced_currency_drop(
    agent: Node2D,
    currency: StringName,
    landing_target: Vector2
) -> void

It should share the same internal cleanup path as remove_dead_monster():

normal agent death burst;
clear manager-owned agent state;
unregister native navigation;
unregister desire and cell tracking;
remove groups;
queue-free the monster.

The only difference is the forced currency drop.

Avoid maintaining two separate copies of the registry-cleanup sequence.

14. Propel the gem to the nearest valid dry floor

The Kraken is installed in water. The gem must not remain in the water.

Extend GroundDropManager with a focused API equivalent to:

func spawn_collectible_currency_toward(
    currency: StringName,
    origin: Vector2,
    landing_target: Vector2
) -> void

Also add a nearest-valid-dry-floor query owned by GroundDropManager, or another appropriate narrow owner.

A valid destination cell must:

contain a floor tile;
not contain a watersource tile;
not contain a wall;
not contain a movement-blocking building.

Search outward from the Kraken/death cell by increasing tile radius and choose the nearest valid cell.

Requirements:

bound the search using the map/floor extent or a safe maximum radius;
do not use an unbounded loop;
do not choose water;
use exact world distance to choose between candidates in the first valid ring;
retain the existing pickup behavior once the gem lands;
retain the existing gem-to-HUD animation when the player collects it.

The gem should visibly travel in an arc from the death position toward the selected floor position.

Do not spawn it directly at the floor destination without propulsion.

If no valid dry floor can be found, preserve the gem through a safe fallback rather than losing the reward.

15. Digestion and cooldown

After the monster has been authoritatively removed:

Clear the target reference and reservation.
Play digestion for KrakenData.digestion_seconds.
Do not acquire targets during digestion.
When digestion finishes, return to idle/ready.

The visual digestion duration used in the laboratory may be shorter for demonstration. Gameplay must pass the actual cooldown duration to the visual.

A Kraken that finds no target after digestion remains ready and idle.

16. Removal and cancellation safety

building_removed must clean up Kraken state.

No captured monster

If the Kraken is removed while idle, extending before contact or digesting:

cancel its visual/state;
release any reservation;
remove its state record;
allow BuildingObjectManager to free the visual.
Captured monster

If the Kraken disappears after contact but before the monster dies:

validate the monster;
clear external-capture state;
resume or retarget it through AgentSuspendService;
re-enable AgentCellTracker;
release the reservation;
do not kill it;
do not spawn a gem.

This cleanup must also occur on:

scene unload;
KrakenSystem exit;
runtime reset;
unexpected visual deletion.

Do not leave monsters permanently detached from navigation.

17. Standard buildable behavior

Kraken must use the existing generic pathways for every normal building feature.

Purchase

Placement must call the existing:

GameUI.try_purchase_build()

Expected result:

exactly 20 gems are spent;
no direct progression mutation from Kraken code;
affordability and disabled picker state work normally;
selection clears normally when the player can no longer afford another.
Placement effects

Use the normal placement commit and _play_build_fx_at_cell() path.

Do not manually duplicate placement particles.

Unbuild

The existing unbuild tool must:

recognize the Kraken marker;
show the normal removal progress bar;
remove the procedural runtime;
unregister Kraken gameplay state;
erase the marker tile;
preserve the watersource;
refresh only the necessary cell state;
not rebuild flow fields.
Refund

Normal player unbuild must use:

GameUI.refund_build()

Expected result:

full refund of 20 gems;
20 existing gem refund sprites fly from the Kraken cell to the gem HUD;
credit occurs through the existing refund animation path;
no Kraken-specific direct currency credit.

Hostile destruction must continue to use the existing no-refund path.

Durability

Register Kraken through the existing player-built provenance/durability system.

Use the configured max_health and do not create a separate Kraken health implementation.

Save/load

The invisible building marker and normal building layer save must restore:

the Kraken catalog identity;
the procedural runtime visual;
the KrakenSystem registration;
idle/ready state.

Do not serialize active attack/eating timelines unless the current game genuinely allows saves during those states.

Do not modify save policy as part of this task.

18. Range visualization

Provide a readable capture-range overlay comparable in usefulness to turret range inspection, without reusing turret gameplay rules.

Show Kraken capture range when:

hovering one placed Kraken;
previewing Kraken placement.

Requirements:

use KrakenData.capture_range;
do not display turret no-build zones;
do not prevent Krakens from being built near each other;
do not perform LOS calculation;
keep the full Kraken preview visible above the range guide;
avoid overlapping opacity accumulation where possible.

This overlay belongs in KrakenSystem or another focused Kraken visual-debug owner, not TurretSystem.

19. Do not change these semantics

Do not:

classify Kraken as a turret;
make it shoot projectiles;
give it spray or gun data;
use turret cooldown visuals;
apply a turret build-distance restriction;
erase watersource tiles;
turn water into buildable floor globally;
make every building use a procedural scene;
add Kraken gameplay to kraken_visual.gd;
move laboratory controls into runtime code;
scan every monster for every Kraken every frame;
duplicate monster-death cleanup;
duplicate currency/refund logic;
create bulk placement support;
perform unrelated architecture cleanup.
Acceptance criteria

The implementation is complete only when all of the following are true.

Build picker
Kraken appears under the gardening tool.
It displays a Kraken icon.
It displays a price of 20 with the gem icon.
Affordable/unaffordable state behaves normally.
It is available in the active demo level.
Preview and placement
Preview shows all eight permanent Kraken segments.
Segment 0 is centered on the hovered cell.
Preview animates or displays the full idle tentacle.
Off-water preview is visibly invalid.
Placement succeeds only on watersource cells.
Placement does not erase the water.
One click places exactly one Kraken.
Dragging never bulk-places Krakens.
Gamepad placement also creates exactly one Kraken.
Exactly 20 gems are spent.
Normal placement FX occur.
Placement does not trigger a hard flow-field rebuild.
Runtime
The placed Kraken uses the same visual scene as the laboratory.
All eight body segments remain visible.
It idles while ready.
Its capture radius is visible during preview and hover.
It does not use turret weapons or projectiles.
Capture
It finds the nearest eligible monster through the cell tracker.
Multiple Krakens cannot reserve the same monster.
The attack follows a moving monster during extension.
Frame 7 reaches the monster.
Contact suspends the monster’s active navigation.
The captured monster no longer triggers drowning or tile interactions.
Turrets do not shoot the captured monster.
The monster remains in the monsters group until death.
The monster follows frame 7 during retraction.
Retraction and extension use the tested approximately 700 ms animation.
Eating lasts exactly three seconds.
Death and reward
The monster uses the normal death burst.
Registry cleanup occurs through MonsterDeathController.
Ordinary random monster-drop logic is bypassed.
Exactly one gem is spawned.
The gem is visibly propelled toward the nearest valid dry floor.
It cannot settle in water.
Collection uses the normal gem-to-HUD animation.
Cooldown
The Kraken plays digestion after eating.
It cannot capture during digestion.
It returns to idle after the configured cooldown.
Removal and persistence
The unbuild tool detects it normally.
Removal progress works normally.
Normal removal refunds exactly 20 gems.
Refund uses the existing flying gem animations.
Hostile destruction gives no refund.
Runtime visual and KrakenSystem state are removed cleanly.
A captured monster is resumed if its Kraken disappears early.
Save/load reconstructs the Kraken in idle state.
kraken_lab.tscn still runs independently.
Manual verification checklist

Do not run the project yourself, but provide this checklist in the final report:

Place preview over land: red/invalid, whole Kraken visible.
Place preview over water: valid, whole Kraken visible.
Click once and drag: only one Kraken is created.
Confirm gem count decreases by 20.
Remove it and confirm 20 gem refund animations.
Place Kraken near several monsters.
Verify only one monster is captured.
Verify a second Kraken chooses another monster.
Test short, medium and maximum-range captures.
Test monsters approaching from several angles.
Shoot the captured monster and verify the sequence is not broken.
Verify the captured monster does not drown while carried.
Verify normal death explosion and exactly one gem.
Verify the gem lands on dry accessible floor.
Verify digestion blocks another capture.
Destroy/remove a Kraken during extension.
Destroy/remove it after contact and verify the monster resumes.
Save and reload with an idle placed Kraken.
Final report

Report:

every file created;
every file modified and why;
the actual Kraken visual API reused;
the final item definition;
the active-level availability change;
how the custom build-picker icon is sourced;
how water-only placement was generalized;
how the full preview is instantiated;
how no-bulk placement is guaranteed;
the final capture radius;
target scan frequency;
digestion duration;
how external capture is suspended and resumed;
how duplicate target reservation is prevented;
how forced gem death reuses normal cleanup;
how nearest dry-floor propulsion works;
how removal/refund/save-load were verified by inspection;
any assumptions requiring manual runtime confirmation;
explicit confirmation that Godot was not run.