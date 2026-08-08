#pragma once

#include "flow_field.h"
#include "flow_field_algorithms.h"

namespace ffcore
{
    struct FlowFieldBuildRequest
    {
        int width = 0;
        int height = 0;
        double tile_size = 1.0;
        Vec2i cell_origin;
        Vec2 world_origin;
        Vec2i goal_cell;
        CellSet walkable_cells;
        CellSet physical_wall_cells;
        DirectionalTraversalConstraints traversal_constraints;
        double wall_clearance_weight = 0.0;
        bool detect_bottlenecks = true;
        int bottleneck_zone_radius = 0;
        // Some callers infer navigability from non-zero directions.
        // Generic worlds use an explicit topology mask so unreachable floor and
        // physics passability remain distinct concepts.
        bool derive_navigability_from_directions = false;
    };

    struct FlowFieldBuildResult
    {
        bool ok = false;
        FlowField field;
    };

    class FlowFieldBuilder
    {
    public:
        static FlowFieldBuildResult build(const FlowFieldBuildRequest &request);
    };
} // namespace ffcore
