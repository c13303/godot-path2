# House-resident refactor — regression checklist

Behavior-preserving genericization of house-resident villagers (see `cleanupforvillage.md`).
The project has no GDScript scene-test harness, so these are deterministic manual reproductions.
Each maps to a required automated check from the task.

Run the game via `C:\GAMETOOLS\godot` **only if the user authorizes it**.

## Ordinary-resident lifecycle (HouseResidentController + AllyHousingController)

1. **Completed ordinary house creates exactly one resident.**
   Build + complete a Merchant House during the day → exactly one Seed Merchant walks in.

2. **Repeated reconciliation does not duplicate.**
   With the merchant present, trigger a reconcile (e.g. place/remove a wall to fire a walkability
   change, or start a new day) → still exactly one Seed Merchant. Enable `CppDebugOptions.logs_enabled`
   and watch for no "duplicate" spawns.

3. **Removing the house evacuates/removes its resident.**
   Destroy/unbuild the completed Merchant House → the merchant walks out via the shared exit (or
   leaves immediately if the exit is unreachable) and is gone; no leftover prompt.

4. **WIP house creates no resident.**
   Place a Merchant House and leave it WIP (do not let a Builder finish it) → no Seed Merchant.

5. **Save/load reconstructs one resident.**
   Save with a completed Merchant House (merchant on the map, day). Reload → exactly one merchant,
   associated with that house; shop still opens. Repeat with the merchant inside at night.

6. **Unique-house rule is generic.**
   With a Merchant House present, the Merchant House build item is unavailable (unique). Confirmed
   via `ItemCatalog.is_unique_house_type` + `count_existing_houses` in `is_house_build_item_available`.

7. **Prerequisite from catalog data.**
   Before any Builder House is completed, the Merchant House is locked. After one completes, it
   unlocks. Driven by `requires_completed_house_type: &"house_builder"` in ItemCatalog.

8. **Unknown resident_type fails clearly.**
   A `HouseResidentConfig` whose `resident_type` does not match its house's `house_resident_type`
   spawns nothing (its `on_house_completed`/`reconcile` filters mismatch) rather than spawning the
   wrong agent. With logs on, `HouseResidentController.setup` warns on an incomplete config.

## Builder specialization (BuilderResidentHandler)

9. **Builders are not routed through the ordinary handler.**
   The BuilderResidentHandler owns all builder + fundamental-Builder reconcile/night/removal;
   HouseResidentController's `on_house_completed` explicitly skips `resident_role == fundamental`
   and any `resident_type != seed_merchant`. Verify: fundamental Builder tutorial/dialog/first-house
   /idle-return unchanged; normal builders start from the 2nd Builder House; work queues, WIP,
   hammer, night, and house-destruction behavior unchanged. No Builder is processed by both systems.

## Generic removal routing

10. **Removed agent mappings are cleaned.**
    Kill/evacuate/scene-reset/save-load each villager type. Every removal path
    (`BuildingManager._remove_escaped_monster`, `MonsterDeathController._remove_dead_agent_without_drop`,
    `AgentSaveService._clear_existing_agents`) routes `house_residents` agents through
    `AllyHousingController.on_agent_removed`, which dispatches by reference to the owning handler.
    Confirm no stale merchant/builder state after removal (next reconcile spawns cleanly).

## Interaction + contact (unchanged behavior)

- Interaction: merchant + fundamental Builder both interactable via the InteractionRouter
  (`interaction_targets` group). Two targets nearby → nearest opens (they never overlap in
  practice, matching prior priority). Closing one clears state; no lingering prompt after an agent
  leaves.
- Contact: clients, merchant, and builders still crush plants/buildings and are classified by
  turrets; a future villager inherits crushing via the `crushes_placeables` meta from its
  definition. The "people crush plants" tutorial still triggers for people, never monsters.
