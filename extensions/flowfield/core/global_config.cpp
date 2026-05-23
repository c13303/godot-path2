#include "global_config.h"
#include <algorithm>

namespace ffcore
{
    static GlobalConfig g_config;

    GlobalConfig &globalconfig()
    {
        return g_config;
    }

    void GlobalConfig::recompute_from_tile()
    {
        // Derived defaults for tile-size changes. Set explicit per-scene overrides
        // after tile_size, because this resets tile-relative tuning values.
        wall_avoid_radius = tile_size * 1.2;
        direct_steer_radius = tile_size * 2.5;     
        target_T2_param_margin = tile_size * 2.0;
        // vitesse cible ratio reste inchangée; lerp constant
    }

    void reset_globalconfig()
    {
        g_config = GlobalConfig();
    }

} // namespace ffcore
