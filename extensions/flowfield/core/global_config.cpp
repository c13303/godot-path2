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
        wall_avoid_radius = tile_size * 1.2;
        direct_steer_radius = tile_size * 2.5;
        target_T1_param_tile_ratio = 0.1;
        target_T2_param_margin = tile_size * 2.0;
        // vitesse cible ratio reste inchangée; lerp constant
    }

    void reset_globalconfig()
    {
        g_config = GlobalConfig();
    }

} // namespace ffcore
