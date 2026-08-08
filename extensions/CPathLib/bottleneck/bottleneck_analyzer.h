#pragma once

#include "../core/types.h"
#include "../flow/flow_field_algorithms.h"

#include <vector>

namespace ffcore
{
    struct DetectedBottleneck
    {
        Vec2i cell;
        int axis = 0;
        double route_cost = 0.0;
        std::vector<Vec2i> zone_cells;
    };

    class BottleneckAnalyzer
    {
    public:
        static std::vector<DetectedBottleneck> analyze(
            const CellSet &walkable_cells,
            const IntegrationCosts &integration_costs,
            int zone_radius);
    };
} // namespace ffcore
