extends Resource
class_name NightReward

## One currency payout inside a night's "special reward". A night can list several
## of these; they are all granted together for free at the merchant.

## Which currency this entry grants. Matches the ItemCatalog/HUD currency ids.
@export_enum("seed", "money", "gem") var currency: String = "seed"
## How much of that currency is granted. 0 means this entry gives nothing.
@export_range(0, 1000000, 1) var amount: int = 0
