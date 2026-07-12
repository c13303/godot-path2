extends Resource
class_name NightReward

## One payout inside a night's "special reward". A night can list several of these;
## they are all offered together for free at the merchant.
##
## A reward grants EITHER a currency amount OR an inventory item:
## - Leave `item_id` empty to grant `amount` of `currency` (seed/money/gem).
## - Set `item_id` to a catalog item id to grant `amount` of that item into the
##   inventory instead; `currency` is then ignored.

## Which currency this entry grants when `item_id` is empty. Matches the ItemCatalog/HUD currency ids.
@export_enum("seed", "money", "gem") var currency: String = "seed"
## Catalog item id to grant instead of a currency. Empty = currency reward (see `currency`).
@export var item_id: String = ""
## How much is granted: currency amount, or item quantity when `item_id` is set. 0 grants nothing.
@export_range(0, 1000000, 1) var amount: int = 0
