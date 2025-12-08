#include "global_config.h"

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
        target_slow_radius_T1 = tile_size * 3.0;
        target_approach_radius_T2 = tile_size * 1.0;
        target_occupy_radius_T3 = tile_size * 0.4;
    }

    void reset_globalconfig()
    {
        g_config = GlobalConfig();
    }

} // namespace ffcore

