Each Agent Behavior.
T2 = radius green circle computed
Claimed Zone = global "claimed_zone_tiles = 3"; << it means that 3 tiles away from your claimed tile, it's considered as "Claimed Zone"

Outside T2: FF + wall + separation; max_speed; lerp_general.

Entering T2 (not Claimed Zone): FF + wall + separation; ramp to t2_speed_target; t2_speed_lerp.

Claimed Zone (when at ): wall + separation + claim force; ramp to t2_speed_target; t2_speed_lerp.

Claimed Tile (reached): wall + separation only; max_speed; lerp_general (reset).

