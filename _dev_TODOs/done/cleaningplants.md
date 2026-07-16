# Additional requirement: consistent plant depth sorting

All plants must use consistent world depth sorting.

This includes, at minimum:

* Roses.
* Imperial plants.
* Pasteques.
* Ronce.
* Bamboo.
* Future crop plants.
* Future defensive or effect plants represented as world vegetation.
* Plants with 32×32, 32×64, 64×64, or other visual dimensions.

## Expected visual behavior

A plant must render according to the world position of its base—the tile where its stem or lower part touches the ground.

Therefore:

* An agent north/behind the plant must render behind it.
* An agent south/in front of the plant must render in front of it.
* Tall sprites must not sort from their visual center or top.
* The lower part of a 32×64 plant remains anchored to its logical tile.
* Sprite dimensions must not affect depth-order correctness.
* Plant animations, growth stages, contact dances, and runtime scene replacements must preserve the same depth origin.

## Required implementation

Inspect the existing world depth-ordering convention and reuse its authoritative utility or formula.

Do not introduce a second incompatible z-index formula specifically for plants.

Create or reuse one clear helper that assigns world-object depth from:

```text
logical base cell / world base Y position
```

Apply it consistently to both plant representations currently used by the project:

1. Crop visuals managed by `PlantManager`.
2. Scene-based plant/placeable visuals instantiated by `BuildingObjectManager`.

The same rule must apply to:

* Initial level preload.
* Runtime placement.
* Savegame restoration.
* Growth-stage visual replacement.
* Mature/immature visual changes.
* Recreated runtime nodes.
* Any pooled or reused plant visual, if applicable.

## Architecture rule

Depth sorting is a visual concern.

Do not put plant-specific z-index branches into gameplay, navigation, save, or agent-interaction systems.

A suitable structure is conceptually:

```gdscript
apply_world_depth(node, base_cell)
```

or reuse the existing equivalent.

The helper should calculate and assign depth when the static plant visual is created or when its base position changes.

Do not update static plant z-index every frame.

## Scene authoring contract

For scene-based plants:

* The scene root must represent the plant’s ground/base position.
* Child sprites may extend upward or sideways.
* Child nodes should normally use relative depth unless a deliberate local offset is needed.
* Do not calculate world depth from an individual sprite’s texture size.
* Avoid arbitrary item-specific `z_index` constants intended to compensate for incorrectly positioned origins.

Document this alongside the placeable runtime-scene contract introduced by the refactor.

## Existing behavior to preserve

Do not alter:

* Plant collision.
* Logical footprint.
* Navigation slowdown.
* Growth.
* Watering.
* Harvesting.
* Agent contact effects.
* Animations.
* Savegame state.
* Placement positions.

This task only standardizes visual depth ordering.

## Cleanup

Search for plant-specific or manually assigned depth values.

Remove redundant hardcoded values only where the new shared depth rule replaces them safely.

Preserve intentional local offsets such as:

* A held fruit appearing above an agent.
* Particles appearing above a plant.
* Health bars or UI overlays.
* Special effects deliberately rendered above the world.

Do not flatten every child node onto the same z-index.

## Acceptance criteria

1. Roses correctly pass behind or in front of agents according to their base tile.
2. All existing plant types follow the same depth rule.
3. A future 32×64 plant receives correct depth ordering without new item-ID code.
4. Tall sprites sort from their lower ground contact point.
5. Placement and savegame restoration produce identical depth ordering.
6. Growth-stage replacement does not reset or corrupt depth.
7. No per-frame z-index processing is added for static plants.
8. No concrete plant IDs are required by the shared depth helper.
9. Health bars, particles, held items, and deliberate foreground effects retain their intended local ordering.
10. Existing gameplay behavior remains unchanged.

In the final report, identify:

* The shared depth-ordering owner/helper.
* Every plant creation/restoration path updated.
* Any remaining intentional manual z-index offsets and their purpose.
