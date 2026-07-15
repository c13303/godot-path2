# Task: generic held-object visual system + permanent Builder hammer

Implement exactly this feature:

1. Refactor the existing rose-in-hand rendering into a **generic single held-object visual system** usable by any `FlowAgent`.
2. Preserve existing client and monster rose behavior exactly.
3. Every Builder permanently holds `marto.png`.
4. While a Builder is actively constructing a WIP house, its hammer performs one full 360° rotation every 1 second. Each rotation lasts exactly 0.3 seconds.

Do not implement inventory, pickups, equipment, combat, or item gameplay. This is only an agent-attached visual system.

---

## Existing code that must be respected

The current rose visual is implemented directly in:

```txt
scripts/entities/character.gd
```

Relevant existing functions/state:

```gdscript
var _held_rose_sprite: Sprite2D

func _update_held_rose_pin() -> void
func _held_rose_frame() -> int
func _ensure_held_rose_sprite() -> Sprite2D
func _held_rose_pin_position() -> Vector2
```

Existing rose visibility remains controlled by metadata:

```txt
client_rose_visible
monster_rose_visible
monster_rose_frame
```

Do not change the gameplay systems that write those metadata values.

Builder appearance is configured in:

```txt
scripts/map/agent_definition_service.gd
```

through:

```gdscript
func apply_builder_data(agent: Node) -> void
```

Builder runtime IDs and agent instances are owned by:

```txt
scripts/map/builder_controller.gd
```

Active WIP-house construction is owned by:

```txt
scripts/map/house_builder_work_controller.gd
```

`HouseBuilderWorkController._advance_work()` is the correct active-construction interval:

* It does not run while the Builder initially travels toward the house.
* It runs while construction progress advances.
* It continues while the Builder pauses or makes local movements around the house.

Use that existing distinction. Do not invent another definition of “building.”

---

# Allowed files

Create:

```txt
scripts/entities/agent_held_object_visual.gd
```

Modify only:

```txt
scripts/entities/character.gd
scripts/map/agent_definition_service.gd
scripts/map/builder_controller.gd
scripts/map/house_builder_work_controller.gd
```

Do not modify:

```txt
scripts/map/building_manager.gd
scripts/map/day_visitor_movement_controller.gd
scripts/map/agent_save_service.gd
scenes/entities/character.tscn
mainRun.tscn
extensions/
```

Do not perform unrelated cleanup.

---

# 1. Create a focused generic held-object visual owner

Create:

```txt
scripts/entities/agent_held_object_visual.gd
```

Class:

```gdscript
extends RefCounted
class_name AgentHeldObjectVisual
```

This class owns only:

* The dynamically created held-object `Sprite2D`.
* Its texture, frame layout, frame, scale and visibility.
* Its local attachment position.
* Whether it renders in front of or behind the agent.
* Its temporary rotation tween.

It must not know about:

* Roses.
* Hammers.
* Clients.
* Monsters.
* Builders.
* Houses.
* Construction state.
* Gameplay metadata.

Suggested public API:

```gdscript
func setup(owner: Node2D) -> void

func show_object(
		texture: Texture2D,
		hframes: int,
		frame: int,
		object_scale: Vector2
) -> void

func set_frame(frame: int) -> void

func hide_object() -> void

func clear_object() -> void

func is_visible() -> bool

func update_attachment(
		local_position: Vector2,
		render_behind_agent: bool
) -> void

func rotate_full_turn(duration: float) -> void

func stop_animation(reset_rotation: bool = true) -> void
```

Exact visual rules:

* Lazily create one `Sprite2D`.
* Name it:

```txt
HeldObjectSprite2D
```

* Add it directly under the owning `FlowAgent`.
* It must remain a normal local child.
* Never use `set_as_top_level(true)`.
* Never assign `global_position`.
* Set:

```gdscript
sprite.centered = true
sprite.visible = false
```

* Use relative z-index:

```gdscript
1
```

when in front of the agent, and:

```gdscript
-1
```

when behind it.

The system supports exactly **one held object per agent**.

Calling `show_object()` replaces the currently held visual.

Do not create one Node or Timer per animation. The controller is a `RefCounted`; only the single displayed `Sprite2D` is added to the scene.

---

# 2. Generic full-turn animation

Implement `rotate_full_turn(duration)` inside `AgentHeldObjectVisual`.

Required behavior:

* If no visible object exists, do nothing.
* Duration is clamped to a safe positive value.
* Kill any existing held-object rotation tween before starting another.
* Start from the sprite’s current normalized/rest rotation.
* Tween one full turn:

```gdscript
0.0 -> TAU
```

* Duration for the Builder call will be:

```gdscript
0.3
```

* Use linear rotation.
* When finished, reset rotation exactly to:

```gdscript
0.0
```

Do not accumulate rotation indefinitely.

Do not rotate the whole agent.

Do not rotate `MonsterSprite2D`.

Do not rotate around world origin.

Only rotate `HeldObjectSprite2D` around its own centered pivot.

`stop_animation(true)` must:

* Kill the active tween if one exists.
* Reset the held object rotation to `0.0`.

---

# 3. Refactor `FlowAgent` to use the generic system

Modify:

```txt
scripts/entities/character.gd
```

Replace the rose-specific `Sprite2D` ownership with:

```gdscript
var _held_object_visual: AgentHeldObjectVisual
```

Set it up with the FlowAgent as owner.

Expose these generic public methods on `FlowAgent`:

```gdscript
func set_held_object(
		texture: Texture2D,
		hframes: int = 1,
		frame: int = 0,
		object_scale: Vector2 = Vector2.ONE
) -> void

func set_held_object_frame(frame: int) -> void

func clear_held_object() -> void

func animate_held_object_full_rotation(duration: float) -> void

func stop_held_object_animation() -> void
```

These methods must only delegate to `AgentHeldObjectVisual`.

They must be valid for any `FlowAgent`, regardless of `agent_kind`.

---

# 4. Preserve the existing rose behavior through a narrow compatibility bridge

Do not rewrite all rose gameplay.

Keep these existing metadata contracts unchanged:

```txt
client_rose_visible
monster_rose_visible
monster_rose_frame
```

Inside `FlowAgent`, replace `_update_held_rose_pin()` with a generic held-object update plus a small rose compatibility bridge.

The bridge must:

* Detect the same client/monster rose visibility conditions as before.
* Use the existing rose texture.
* Use the existing rose frame count.
* Use the existing rose scale.
* Use `monster_rose_frame` for monsters exactly as before.
* Use frame `0` for clients exactly as before.
* Show the rose through `set_held_object(...)`.
* Update only its frame when the frame changes.
* Clear the rose when the existing visibility metadata becomes false.

Track whether the generic held object was activated by the legacy rose bridge, for example:

```gdscript
var _legacy_rose_held: bool = false
var _legacy_rose_frame: int = -1
```

Important:

* The rose bridge must never clear a Builder’s hammer.
* It may clear the held object only when `_legacy_rose_held` is true.
* Do not remove or rename the rose metadata.
* Do not modify save serialization.
* Do not modify the code that sends roses from counters to clients.
* Do not change when clients or monsters receive or lose roses.

The observable rose behavior must remain unchanged.

---

# 5. Use the exact existing attachment positioning rules

Rename/generalize:

```gdscript
func _held_rose_pin_position() -> Vector2
```

to something such as:

```gdscript
func _held_object_pin_position() -> Vector2
```

Keep its existing positioning mathematics unchanged.

The generic held object must continue to derive its pin from the live `MonsterSprite2D`:

* Current sprite position.
* Current sprite offset.
* Current sprite scale.
* Current frame dimensions.
* Centered/non-centered state.
* East/west facing.

This is required so the held object follows the procedural bounce and squash from `CharacterAnimation`, just as the rose currently does.

The held object must use the same direction-dependent z-index rule as the rose:

```gdscript
render behind when facing north
render in front otherwise
```

Specifically:

```gdscript
var render_behind: bool = _facing_frame == MONSTER_FRAME_NORTH
```

Then call:

```gdscript
_held_object_visual.update_attachment(
	_held_object_pin_position(),
	render_behind
)
```

Do not introduce a different Builder attachment offset.

Do not add a special south/east/north hammer position.

Do not add world-space compensation.

Do not add camera compensation.

Do not add magic pixel offsets.

The Builder hammer must use exactly the same attachment-position and z-index rules as the existing held roses.

---

# 6. Track facing for agents holding generic objects

There is an important current limitation:

`_update_directional_facing()` returns early for agents that do not use the monster/client directional frame layouts.

Builders still need `_facing_frame` and `_facing_west` updated because the hammer attachment uses those values, even if the Builder body sprite rendering remains otherwise unchanged.

Modify the early-return condition so directional facing is updated when either:

* The agent uses directional monster frames.
* The agent uses directional client frames.
* A generic held object is currently visible.

Conceptually:

```gdscript
var needs_facing: bool = (
	_uses_directional_monster_frames()
	or _uses_directional_client_frames()
	or _held_object_visual.is_visible()
)
if not needs_facing:
	return
```

Do not change Builder body sprite frames as part of this task.

Do not add a new Builder animation layout.

Do not change client or monster directional animation.

This change exists only so generic held visuals follow east/west/north/south attachment rules.

---

# 7. Give every Builder a permanent hammer

Modify:

```txt
scripts/map/agent_definition_service.gd
```

Locate the actual existing asset named:

```txt
marto.png
```

Use its real project path. Do not rename, duplicate, regenerate, or relocate it.

Add a preload such as:

```gdscript
const BUILDER_HAMMER_TEXTURE: Texture2D = preload("<actual marto.png path>")
```

Use one frame:

```gdscript
hframes = 1
frame = 0
```

Use this held scale:

```gdscript
const BUILDER_HAMMER_SCALE: Vector2 = Vector2(0.56, 0.56)
```

At the end of:

```gdscript
func apply_builder_data(agent: Node) -> void
```

call the generic FlowAgent API:

```gdscript
if agent.has_method("set_held_object"):
	agent.call(
		"set_held_object",
		BUILDER_HAMMER_TEXTURE,
		1,
		0,
		BUILDER_HAMMER_SCALE
	)
```

The hammer is always visible while the Builder exists:

* Entering the map.
* Walking.
* Idle.
* Travelling toward a WIP house.
* Building.
* Returning to the idle area.
* Leaving at night.

Do not hide it outside construction.

Construction only controls rotation, not hammer visibility.

---

# 8. Add narrow Builder visual delegation methods

Modify:

```txt
scripts/map/builder_controller.gd
```

`BuilderController` already owns the mapping:

```txt
builder_id -> DayVisitorMovementController -> agent node
```

Add exactly these kinds of safe delegation methods:

```gdscript
func play_builder_hammer_swing(builder_id: int, duration: float) -> void

func stop_builder_hammer_swing(builder_id: int) -> void
```

Implementation rules:

1. Resolve the visitor with `_visitor_for_id(builder_id)`.
2. Resolve the agent through `visitor.agent_node()`.
3. Safely no-op if the visitor or agent is missing.
4. Call:

```gdscript
animate_held_object_full_rotation
```

for a swing.

5. Call:

```gdscript
stop_held_object_animation
```

when construction stops.

Do not expose the internal visitor dictionaries.

Do not move construction timing into `BuilderController`.

Do not make `BuilderController` process per-frame animation.

It only resolves the Builder agent and delegates to its generic visual API.

---

# 9. Construction hammer cadence

Modify:

```txt
scripts/map/house_builder_work_controller.gd
```

Add:

```gdscript
const HAMMER_SWING_INTERVAL_SECONDS: float = 1.0
const HAMMER_SWING_DURATION_SECONDS: float = 0.3
```

Add Builder-specific countdown state:

```gdscript
var _hammer_swing_remaining_by_builder_id: Dictionary = {}  # int -> float
```

This state belongs here because this controller already owns whether a Builder is actively making house progress.

## Starting the cadence

When `_try_assign_builder_to_house()` successfully establishes an assignment, initialize:

```gdscript
_hammer_swing_remaining_by_builder_id[builder_id] = HAMMER_SWING_INTERVAL_SECONDS
```

Do not rotate while the Builder initially travels to the house.

The countdown must only advance from `_advance_work()`.

## Advancing the cadence

Add a focused helper:

```gdscript
func _process_builder_hammer_swing(builder_id: int, delta: float) -> void
```

Call it from `_advance_work()` only while construction progress is actually advancing.

Required behavior:

```gdscript
var remaining: float = float(
	_hammer_swing_remaining_by_builder_id.get(
		builder_id,
		HAMMER_SWING_INTERVAL_SECONDS
	)
)

remaining -= maxf(0.0, delta)

if remaining <= 0.0:
	_builder.play_builder_hammer_swing(
		builder_id,
		HAMMER_SWING_DURATION_SECONDS
	)

	while remaining <= 0.0:
		remaining += HAMMER_SWING_INTERVAL_SECONDS

_hammer_swing_remaining_by_builder_id[builder_id] = remaining
```

The normalization loop may correct a large frame delta, but it must trigger at most one visual swing in a single frame.

Expected cadence:

* No immediate rotation when assigned.
* First rotation after approximately 1 second of active work.
* Then one rotation every approximately 1 second of active work.
* Each rotation lasts 0.3 seconds.

The cadence continues during:

* Work pauses beside the house.
* Local Builder movement around the same house.

This is correct because both currently advance house construction progress.

The cadence does not run during:

* Initial travel toward the house.
* Idle time.
* Return to idle.
* Night departure.
* Cancelled work.
* A missing or invalid assignment.

---

# 10. Stop rotation cleanly whenever an assignment ends

In:

```gdscript
func _clear_assignment_state(builder_id: int, house_id: StringName) -> void
```

also:

1. Call:

```gdscript
_builder.stop_builder_hammer_swing(builder_id)
```

2. Erase:

```gdscript
_hammer_swing_remaining_by_builder_id.erase(builder_id)
```

This must cover all existing assignment-ending paths:

* House completed.
* House removed.
* Builder removed.
* Night starts.
* Assignment invalidated.
* Topology invalidates the assignment.
* Builder is returned to idle.

Do not hide or clear the hammer. Only stop its tween and restore its rotation to `0.0`.

If the Builder immediately receives another house task, the new assignment gets a fresh 1-second countdown.

---

# Explicit prohibitions

Do not:

* Add Builder hammer logic to `BuildingManager`.
* Add a Timer node to every Builder.
* Add a `_process()` method to `AgentHeldObjectVisual`.
* Add a second held sprite specifically for the hammer.
* Keep both `HeldRoseSprite2D` and `HeldObjectSprite2D`.
* Duplicate the rose pin-position mathematics.
* Hardcode hammer positioning separately.
* Add inventory or equipment state.
* Serialize the hammer.
* Serialize hammer rotation or countdown.
* Modify Builder save/load behavior.
* Modify house work duration.
* Modify Builder pathing.
* Modify Builder local movement behavior.
* Modify client purchase behavior.
* Modify monster eating behavior.
* Modify agent spawning architecture.
* Touch the C++ extension.
* Add debug logs.
* Run Godot, tests, compilation, export, or builds.

---

# Strict typing

Strict GDScript typing is enabled.

Do not use ambiguous `:=` inference for:

* Dictionary values.
* Tween state.
* Call results.
* Numeric calculations.
* Nullable nodes.

Use explicit types and casts.

Examples:

```gdscript
var visitor: DayVisitorMovementController = _visitor_for_id(builder_id)
var agent: Node2D = visitor.agent_node() if visitor != null else null
var remaining: float = float(...)
var sprite: Sprite2D = ...
```

---

# Acceptance criteria

## Existing rose behavior

1. A client receives a rose from a garden plant:

   * Rose appears immediately.
   * Position matches the previous implementation.

2. A client receives a rose from a counter:

   * Rose remains hidden during its flight.
   * Pinned rose appears only when the existing arrival callback fires.

3. A monster holds the correct rose frame while eating.

4. Rose visibility still disappears under exactly the previous conditions.

5. North-facing held roses render behind the body.

6. South/east/west held roses render in front.

7. Existing rose metadata and save behavior are unchanged.

## Builder hammer

1. Every Builder shows `marto.png` immediately after spawning.

2. The hammer remains visible while:

   * Entering.
   * Idle.
   * Travelling.
   * Building.
   * Returning.
   * Leaving.

3. The hammer follows the same hand/pin position as roses.

4. The hammer follows procedural body bounce/squash.

5. The hammer is behind a north-facing Builder.

6. The hammer is in front for south/east/west facing.

7. The Builder body sprite itself is not rotated.

## Construction animation

1. Hammer does not rotate while the Builder initially walks toward a WIP house.

2. Approximately 1 second after active house progress begins, the hammer makes one complete 360° turn.

3. The turn lasts 0.3 seconds.

4. It repeats every 1 second while progress advances.

5. Multiple Builders have independent countdowns and animations.

6. Rotation stops and resets to zero when:

   * Construction completes.
   * Assignment is cancelled.
   * Night begins.
   * Builder disappears.
   * House disappears.

7. The hammer remains visible after rotation stops.

8. No permanent rotation drift accumulates.

9. No new warnings or errors occur.

---

# Final report

Report:

1. Exact changed and created files.
2. The public generic held-object API added to `FlowAgent`.
3. How existing rose metadata compatibility was preserved.
4. Where Builder hammer visibility is configured.
5. Where the one-second construction cadence is owned.
6. Confirmation that `BuildingManager`, save logic, scenes and C++ were untouched.
7. Manual test cases performed conceptually, without claiming Godot was run.
