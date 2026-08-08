#pragma once
#include "CPathLib/core/types.h"

namespace ffcore
{
    // Route groups should own at most one pooled flow field. Keeping these equal
    // makes pool pressure expose lifecycle bugs instead of masking leaked groups
    // with excess memory-heavy field slots.
    constexpr int MAX_FLOWFIELDS = 64;
    constexpr int MAX_GROUPS = 64;
    constexpr GroupID GROUP_IDLE = 0;
    constexpr int FLOW_WIDTH = 256;
    constexpr int FLOW_HEIGHT = 256;
    constexpr double FLOW_TILE_SIZE = 32.0;
}
