#pragma once

#include "../core/types.h"

#include <cstddef>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace ffcore
{
    struct CellHash
    {
        std::size_t operator()(const Vec2i &cell) const noexcept;
    };

    using CellSet = std::unordered_set<Vec2i, CellHash>;
    using DirectionalTraversalConstraints = std::unordered_map<Vec2i, Vec2i, CellHash>;
    using IntegrationCosts = std::unordered_map<Vec2i, double, CellHash>;

    class FlowFieldAlgorithms
    {
    public:
        static bool can_traverse(const Vec2i &from_cell,
                                 const Vec2i &to_cell,
                                 const CellSet &walkable_cells,
                                 const DirectionalTraversalConstraints *traversal_constraints = nullptr);

        static IntegrationCosts compute_integration_costs(
            const CellSet &walkable_cells,
            const Vec2i &goal_cell,
            const DirectionalTraversalConstraints *traversal_constraints = nullptr);

        static std::vector<float> compute_wall_distance_field(
            int width,
            int height,
            const Vec2i &cell_origin,
            const CellSet &wall_cells);
    };
} // namespace ffcore
