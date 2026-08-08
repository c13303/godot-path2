#include "bottleneck_analyzer.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace ffcore
{
    std::vector<DetectedBottleneck> BottleneckAnalyzer::analyze(
        const CellSet &walkable_cells,
        const IntegrationCosts &integration_costs,
        int zone_radius)
    {
        std::vector<DetectedBottleneck> result;
        if (integration_costs.empty())
            return result;

        zone_radius = std::clamp(zone_radius, 0, 2);
        const Vec2i east(1, 0);
        const Vec2i west(-1, 0);
        const Vec2i south(0, 1);
        const Vec2i north(0, -1);
        const Vec2i cardinal_directions[4] = {east, west, south, north};

        const auto is_walkable = [&](const Vec2i &cell) -> bool
        { return walkable_cells.count(cell) != 0; };
        const auto cost_at = [&](const Vec2i &cell) -> double
        {
            const auto cost = integration_costs.find(cell);
            return cost == integration_costs.end() ? std::numeric_limits<double>::infinity() : cost->second;
        };
        const auto narrow_axis = [&](const Vec2i &cell) -> int
        {
            const bool e = is_walkable({cell.x + east.x, cell.y + east.y});
            const bool w = is_walkable({cell.x + west.x, cell.y + west.y});
            const bool s = is_walkable({cell.x + south.x, cell.y + south.y});
            const bool n = is_walkable({cell.x + north.x, cell.y + north.y});
            const int neighbor_count = static_cast<int>(e) + static_cast<int>(w) +
                                       static_cast<int>(s) + static_cast<int>(n);
            if (neighbor_count == 2 && e && w)
                return 1;
            if (neighbor_count == 2 && n && s)
                return 2;
            return 0;
        };

        CellSet added_cells;
        for (const Vec2i &cell : walkable_cells)
        {
            const int axis = narrow_axis(cell);
            if (axis == 0)
                continue;
            const double cell_cost = cost_at(cell);
            if (!std::isfinite(cell_cost))
                continue;

            bool is_route_entry = false;
            for (const Vec2i &direction : cardinal_directions)
            {
                const Vec2i neighbor(cell.x + direction.x, cell.y + direction.y);
                if (!is_walkable(neighbor) || narrow_axis(neighbor) != 0)
                    continue;
                const double neighbor_cost = cost_at(neighbor);
                if (std::isfinite(neighbor_cost) && neighbor_cost > cell_cost)
                {
                    is_route_entry = true;
                    break;
                }
            }
            if (!is_route_entry || added_cells.count(cell) != 0)
                continue;
            added_cells.insert(cell);

            DetectedBottleneck bottleneck;
            bottleneck.cell = cell;
            bottleneck.axis = axis;
            bottleneck.route_cost = cell_cost;
            for (int dy = -zone_radius; dy <= zone_radius; ++dy)
            {
                for (int dx = -zone_radius; dx <= zone_radius; ++dx)
                {
                    if (std::abs(dx) + std::abs(dy) > zone_radius)
                        continue;
                    const Vec2i zone_cell(cell.x + dx, cell.y + dy);
                    if (is_walkable(zone_cell))
                        bottleneck.zone_cells.push_back(zone_cell);
                }
            }
            result.push_back(std::move(bottleneck));
        }
        return result;
    }
} // namespace ffcore
