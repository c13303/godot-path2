bamboo harvest feature.

Now the level (we use level_demo.tscn) can have "bamboo" nodes. 

at level start, place matured bamboos on the tiles of those nodes.

use bamboo.png. zindexed and the lower part of 32x64 sprite is on the tile. 
frame 0 : non mature
frame 1 : matured

make them "dance" animation like the other plants, maybe a bit more.

player walks on the tile (same distance like gem collecting) to grab the bamboo.
The bamboo therefore become immature again, and 5 x bamboo items are givent to player (animate from tile to currencyUI like always)

The bamboo become mature again at every dawn.

Those plants are never destroyed ever.

they create 50% slowdown for everyone
they make the tiles unbuildable

Their state must be included in savegames.


I think its pretty clear and simple. read AGENTS.md and prepare for a super clean implementation with dedicated files. Make things generic and reusable where it's possible, however there might not be much reusable stuff here.
