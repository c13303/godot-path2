Implement a clean, reusable dialog system and migrate the existing seed merchant shop to it.

Read and follow AGENTS.md first.

Do not run Godot, tests, compilation, export, or build commands. I will test manually.

The implementation must be production-oriented and must reduce responsibilities in the oversized `scripts/shop/toolbuild.gd`, not add another feature to it.

# Objective

Create:

- `scenes/dialog.tscn`
- `scripts/ui/dialog.gd`
- `scripts/ui/merchant_dialog_controller.gd`

`dialog.tscn` must be instantiated exactly once by `mainRun.tscn`, hidden when unused, and reused for every dialog.

Do not instantiate/free a new dialog scene whenever a conversation opens.

The system must be generic and callable by future gameplay systems, while the seed merchant integration stays in its own focused controller.

# Architecture

## Generic dialog owner

`dialog.gd` owns only:

- dialog presentation
- typewriter state
- dynamically generated choice rows
- mouse, keyboard, and gamepad navigation while open
- modal gameplay-input locking
- public open/refresh/close API

It must not know anything about:

- the seed merchant
- items
- currencies
- inventory
- rewards
- purchases
- GameState merchant phases

Use `class_name DialogUI`.

Add the instantiated dialog root to a stable group such as:

```gdscript
&"dialog_ui"

This allows unrelated systems to find the single dialog instance when necessary, while code with an explicit reference should use that reference.

Merchant adapter

merchant_dialog_controller.gd owns:

deciding when the merchant shop may open
converting merchant inventory into generic dialog choices
purchasing
reward claiming
purchase animation origins
refreshing rows after a purchase
closing when the merchant phase ends or the player leaves

It must use the existing economy/inventory methods in game_ui.gd.

Do not move merchant economy logic out of game_ui.gd during this task.

Remove merchant UI from Toolbuild

The current merchant presentation and input code in:

scripts/shop/toolbuild.gd

must be removed after its callers are migrated.

toolbuild.gd should return to owning only:

build picker UI
weapon picker UI
their selection/layout behavior

Remove merchant-specific constants, fields, layout code, reward rows, selection code, purchase code, and comments from Toolbuild.

Before deleting public wrappers, search the full repository for:

direct calls
call()
Callable
signal connections
string method references
scene references

Known current callers such as player_controller.gd and merchant_prompt.gd must be migrated to MerchantDialogController.

Do not leave the old merchant column hidden as a compatibility implementation. There must be one merchant UI implementation.

Scene integration

Add dialog.tscn as a PackedScene external resource in mainRun.tscn.

Instantiate it once under GameUI, named:

GameUI/Dialog

It must:

fill the viewport
be hidden by default
render above other gameplay UI
block mouse interaction with the world while visible
remain the same instance for the lifetime of mainRun.tscn

Add one controller node under GameUI:

GameUI/MerchantDialogController

Attach merchant_dialog_controller.gd.

Use explicit exported NodePaths or typed node references for:

GameUI/Dialog
GameUI
Player/PlayerController
Map/BuildingManager

Avoid repeated deep scene-tree searches in per-frame code.

Dialog layout

The colors in the mockup identify layout regions. They are not instructions to make the portrait yellow, text white, or choices blue.

Use the existing dark UI aesthetic.

The close button may use a warm brown background similar to the mockup.

The dialog is a centered modal occupying most of the screen while retaining a safe viewport margin. It must scale down correctly on smaller supported resolutions.

Upper section

Two columns:

Left column
Portrait area.
Speaker name directly below it.
Fixed enough width that the main text starts at the same position regardless of name length.
Portraits are usually one 64×64 sprite frame.
Display them enlarged while preserving aspect ratio.
Use nearest-neighbour filtering for pixel-art portraits.
Do not stretch the portrait.
Right column
Main dialog text.
Use a scroll container.
No horizontal scrolling.
Vertical scrolling only becomes relevant when the text exceeds the available area.
Use a typewriter reveal.
The scroll container must not enlarge the dialog when the text is long.
Lower section

A vertically scrollable list of choice buttons.

It must remain inside the dialog panel.
A large number of choices must scroll rather than enlarge beyond the viewport.
The complete choice area appears only after typewriting finishes or is skipped.
Every choice is a full-width clickable row.

Each row has these aligned columns, in this exact order:

[ICON] [PRICE + optional currency icon] [LABEL]

Requirements:

Icon column has a fixed width.
Price column has a fixed width shared by every row.
Label column expands.
An empty price must leave the price cell empty without collapsing the column.
All labels therefore start at the same X position.
Rows have a consistent height.
Choice focus/selection must be visibly clear.
Unavailable/unaffordable choices remain readable and may still receive selection so the player can inspect them, but activating them must do nothing.
Their visual state must clearly indicate that they cannot currently be used.
Do not rely solely on Button.disabled if that prevents pad selection of an unaffordable shop row.

For reward choices, support an optional amount badge over the icon while the price column stays empty.

Close cross

Place an X button overlapping or closely pinned to the upper-right corner of the panel, matching the mockup.

It must close the dialog immediately, including while typewriting.

Generic public API

Implement a small, explicit API. A suitable shape is:

func open_dialog(
	context_id: StringName,
	speaker_name: String,
	body_text: String,
	portrait: Texture2D,
	choices: Array[Dictionary],
	choice_handler: Callable = Callable(),
	closed_handler: Callable = Callable(),
	options: Dictionary = {}
) -> void

Also expose:

func refresh_choices(
	choices: Array[Dictionary],
	preferred_choice_id: String = ""
) -> void

func close_dialog(reason: StringName = &"closed") -> void

func is_open() -> bool

func is_open_for(context_id: StringName) -> bool

func finish_typewriter() -> void

The exact signatures may be adjusted if a cleaner typed implementation is found, but preserve these capabilities.

Document the accepted choice dictionary fields. It should support at least:

{
	"id": String,
	"label": String,
	"icon": Texture2D,
	"price_text": String,
	"currency_icon": Texture2D,
	"icon_badge_text": String,
	"visible": bool,
	"enabled": bool,
	"close_on_select": bool,
}

Rules:

Validate malformed entries safely.
Use explicit GDScript types and casts.
Do not let arbitrary untyped dictionary access spread through the whole script.
Centralize choice parsing/building.
refresh_choices() must not restart the typewriter.
Try to preserve the currently selected choice by ID.
If it disappeared, select the closest sensible remaining choice, otherwise the first row.
If a choice uses close_on_select, invoke its handler first and then close.
Opening another context while one is already open must cleanly close/replace the previous context without leaking callbacks or input locks.

Pass the activated row’s global center position to the choice handler, because merchant purchase/reward animations need the source position.

For example, the handler may receive:

choice_handler.call(choice_id, source_global_position)
Typewriter behavior

Use an exported or clearly named configurable character speed, approximately 40–50 characters per second.

Use RichTextLabel.visible_characters or another efficient reveal mechanism. Do not rebuild the text every frame with repeated string slicing.

When typewriting finishes:

reveal the choices area
select/focus the first valid row
ensure it is visible in the choice scroll container

Skipping typewriting reveals the entire text immediately and then reveals the choices.

Important input precedence:

Escape closes immediately.
Gamepad B closes immediately.
Close cross closes immediately.
Those inputs must close, not merely skip typewriting.
While typing, a normal left mouse click completes the text.
While typing, any pressed gamepad button other than B completes the text.
A click on the close cross must still reach the close button.
Do not consume the close-button mouse event as a generic typewriter skip.

Guard against the input that opened the dialog instantly skipping it in the same frame. The E/Y event used to open the shop must not also complete the typewriter immediately.

Use a one-frame input guard or equivalent explicit protection.

Input after typewriting

Keyboard:

Up/Down: move choice selection
Enter or Space: activate selected choice
Escape: close

Gamepad:

D-pad Up/Down: move selection
Left-stick vertical movement should also work with a threshold and release latch, without repeating uncontrollably
A: activate selected choice
B: close

Mouse:

Mouse wheel scrolls the relevant text or choice scroll area naturally
Clicking a choice activates that choice
Clicking outside the panel must not interact with the world

When pad/keyboard selection changes, call the scroll container’s visibility helper so the selected row automatically scrolls into view.

The dialog itself owns this navigation. Do not route dialog choice navigation through Toolbuild.

Gameplay input locking

The dialog is modal for player input, but do not use:

SceneTree.paused
PlayerController.set_paused()
PauseOverlay

The existing pause path hides units and would also interfere with merchant purchase animations.

Instead, use the existing:

PlayerController.set_cutscene_input_locked(true)

while a blocking dialog is open.

Add a small public query if needed:

func is_cutscene_input_locked() -> bool

The dialog must remember whether input was already locked before it opened and restore that previous state when it closes. Do not blindly unlock an input lock that existed before the dialog.

Support an option such as:

"blocks_gameplay_input": true

defaulting to true.

The merchant dialog uses the default blocking behavior.

World simulation may continue behind the merchant dialog. Player movement, attacks, construction, quickbar input, and world clicks must not.

Seed merchant implementation

Use context:

&"seed_merchant"

Opening remains triggered by the existing interaction:

keyboard E
gamepad Y

Preserve the existing ability to interact while the merchant is walking in when the player is close, even though the floating prompt only appears once the merchant reaches the authored idle spot.

The merchant dialog must close when:

the player presses Escape
the player presses gamepad B
the close cross is clicked
the player leaves merchant interaction range
the merchant phase ends
night invalidates the merchant interaction

Update player_controller.gd so _try_toggle_merchant_shop() delegates to MerchantDialogController, not Toolbuild.

Remove old merchant-specific pad selection branches from PlayerController. The open dialog owns A/B/D-pad/left-stick behavior.

Ensure build cursor and gameplay controls do not continue underneath the dialog.

Update merchant_prompt.gd so it queries MerchantDialogController.is_shop_open() rather than Toolbuild.

Merchant content
Portrait

Use the existing merchant texture:

res://assets/sprites/legval/merchent.png

It currently contains 4 horizontal frames.

Use the first frame as the portrait. Build an AtlasTexture region from the actual texture dimensions rather than assuming the full sheet is the portrait.

Preserve nearest-neighbour filtering.

Speaker name

Use a translation key.

English:

Seed Merchant

French:

Marchande de graines
Main text

Add translations for the greeting.

French:

Hey, salut Rose ! J'ai des choses pour toi !

English:

Hey, Rose! I've got some things for you!

Use the project’s Translations.t() system. Do not hardcode only one language.

Use clear keys such as:

merchant.seed.name
merchant.seed.greeting

Update both existing locale JSON files.

Choices

List every item currently sold by the merchant, using the same data-driven source as before:

ItemCatalog.get_merchant_shop_item_ids()

Filter them with the current level availability rules through:

game_ui.is_merchant_item_available(item_id)

Preserve:

level-configured merchant items
level-configured prices
unlock days
growth price factors
already-owned weapon hiding
inventory capacity rules
current affordability
translated item names
existing item order

Use:

game_ui.get_merchant_price(item_id)
game_ui.get_merchant_affordable_quantity(item_id)

Use the existing purchase routes exactly:

seed:
	game_ui.try_purchase_seed_merchant_item(item_id, 1)

inventory-backed placeable:
	game_ui.try_purchase_placeable_merchant_item(item_id, 1)

weapon:
	game_ui.try_purchase_shop_inventory_item(item_id, 1)

On successful purchase:

set GameState.seed_merchant_purchase_made = true
play Sfx.play_sound(&"buy")
preserve the existing fly-to-HUD/inventory animation behavior
refresh merchant choices
keep the dialog open
preserve selection by ID when possible
if a purchased weapon disappears, move selection to an adjacent remaining row

On failed purchase:

do not close
do not play the buy sound
refresh the row state only if needed

Merchant item icons must use the same item/currency atlas regions as the old UI.

It is acceptable for the new merchant controller to contain small focused icon-region helpers. Do not perform a broad item-icon refactor unless it is genuinely required.

Special night rewards

Preserve the current merchant special-reward feature.

Read rewards from:

game_ui.get_active_night_reward()

Insert each active reward before normal shop items.

Each reward row has:

reward currency/item icon
amount badge over the icon
empty price column
reward/item label

Use the existing translation key for merchant.special_reward where applicable.

Claim through:

game_ui.claim_active_night_reward(source_global_position, reward_key)

On success:

play the buy sound
refresh the choices
remove the claimed row
keep the dialog open

If an item reward cannot be claimed because inventory is full, leave it visible and claimable later, preserving current behavior.

Toolbuild cleanup details

After migration, remove from toolbuild.gd all merchant-specific concepts, including equivalents of:

_merchant_column
_merchant_panel
_merchant_close_button
_merchant_items_list
_merchant_shop_open_requested
_selected_merchant_item_id
merchant row dictionaries
reward cell arrays/signatures
merchant layout constants
merchant construction functions
merchant open/close functions
merchant pad selection
reward row construction
merchant purchases
reward claims
merchant animation dispatch
toggle_merchant_shop()
is_merchant_shop_open()

Do not remove generic currency/icon helpers still used by build or weapon menus.

Update Toolbuild’s file header comments to accurately describe only its remaining responsibilities.

The resulting Toolbuild file should shrink materially.

Important preservation requirements

Do not change:

merchant spawn/movement logic
proximity radius
phase timing
level merchant configuration format
inventory rules
price growth calculations
special reward save/state rules
existing purchase animations
merchant interaction prompt timing
unrelated build picker behavior
unrelated weapon picker behavior
normal pause behavior

Do not modify C++ or the GDExtension.

Manual validation checklist

Report these for me to test manually:

Approach the merchant after it reaches its spot: E/Y prompt appears.
Press E: dialog opens with merchant portrait, name, and typewritten greeting.
The same E press does not instantly skip the greeting.
Press Y or another pad button while typing: greeting completes.
Click normal dialog content while typing: greeting completes.
Press Escape while typing: dialog closes immediately.
Press gamepad B while typing: dialog closes immediately.
Click the X while typing: dialog closes immediately.
Choices remain hidden until the greeting completes.
All merchant rows use aligned icon, price, and label columns.
Keyboard, mouse, D-pad, left stick, and A navigation work.
Selection auto-scrolls in a long choice list.
Main text scrolls only when it exceeds its area.
An unaffordable item remains visible but cannot be purchased.
Buying seeds updates currency/seeds, refreshes affordability, animates, and leaves the dialog open.
Buying a weapon removes it from the list when ownership makes it unavailable.
Inventory-backed merchant items still enter inventory correctly.
Special night reward rows appear first and remain free.
Claiming a reward removes only that reward row.
An inventory-full item reward remains unclaimed.
Walking away closes the merchant dialog.
Night/phase transition closes it.
Player movement, attacks, building, and world clicks are blocked while open.
World visuals remain visible and merchant purchase animations still run.
Normal Toolbuild and weapon menus still behave exactly as before.
The merchant prompt no longer depends on Toolbuild.
Only one Dialog instance exists during the scene.
Final report

At completion, report:

changed files
new public dialog API
merchant code removed from Toolbuild
how gameplay input locking is restored safely
preserved merchant behaviors
any compatibility wrapper retained and why
any remaining production-quality concern
manual tests recommended

Do not run the project.