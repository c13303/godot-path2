#pragma once

#include "navigation_area.h"
#include "../flow/flow_field_algorithms.h"

#include <cstddef>

namespace ffcore
{
    struct AreaBuildResult
    {
        std::vector<Vec2i> interior_cells;
        std::vector<Vec2i> boundary_cells;
    };

    class AreaBuilder
    {
    public:
        static AreaBuildResult from_explicit_cells(const std::vector<Vec2i> &cells);
        static AreaBuildResult from_seed(
            const Vec2i &seed,
            const CellSet &allowed_cells,
            std::size_t maximum_cells = 0);
    };
} // namespace ffcore
