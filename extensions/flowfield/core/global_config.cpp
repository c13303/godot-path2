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
        target_T2_param_margin = tile_size * 2.0;
        // Vitesse minimale scaled with tile size to stay meaningful across grids
        target_T2_param_minimal_speed = std::max(1.0, tile_size * 0.25);
    }

    void reset_globalconfig()
    {
        g_config = GlobalConfig();
    }

} // namespace ffcore
