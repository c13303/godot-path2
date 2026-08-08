#include "flow_field_builder.h"

#include "../bottleneck/bottleneck_analyzer.h"

#include <limits>

namespace ffcore
{
    FlowFieldBuildResult FlowFieldBuilder::build(const FlowFieldBuildRequest &request)
    {
        FlowFieldBuildResult result;
        if (request.width <= 0 || request.height <= 0 ||
            request.walkable_cells.count(request.goal_cell) == 0)
            return result;

        FlowField &field = result.field;
        field.resize(request.width, request.height);
        field.set_tile_size(request.tile_size);
        field.set_cell_origin(request.cell_origin);
        field.set_world_origin(request.world_origin);
        if (!request.derive_navigability_from_directions)
        {
            field.enable_explicit_navigability();
            for (const Vec2i &absolute : request.walkable_cells)
            {
                field.set_cell_navigable({
                    absolute.x - request.cell_origin.x,
                    absolute.y - request.cell_origin.y}, true);
            }
        }
        field.enable_explicit_physics_passability();
        for (int y = 0; y < request.height; ++y)
        {
            for (int x = 0; x < request.width; ++x)
            {
                const Vec2i absolute(request.cell_origin.x + x, request.cell_origin.y + y);
                field.set_cell_physics_passable(
                    {x, y}, request.physical_wall_cells.count(absolute) == 0);
            }
        }

        const std::vector<float> distances = FlowFieldAlgorithms::compute_wall_distance_field(
            request.width,
            request.height,
            request.cell_origin,
            request.physical_wall_cells);
        field.set_distance_field(distances);

        const IntegrationCosts costs = FlowFieldAlgorithms::compute_integration_costs(
            request.walkable_cells,
            request.goal_cell,
            &request.traversal_constraints);
        std::vector<double> route_costs(
            static_cast<std::size_t>(request.width * request.height),
            std::numeric_limits<double>::infinity());
        for (int y = 0; y < request.height; ++y)
        {
            for (int x = 0; x < request.width; ++x)
            {
                const Vec2i absolute(request.cell_origin.x + x, request.cell_origin.y + y);
                const auto cost = costs.find(absolute);
                if (cost != costs.end())
                    route_costs[y * request.width + x] = cost->second;
            }
        }
        field.set_route_cost_field(route_costs);

        if (request.detect_bottlenecks)
        {
            const std::vector<DetectedBottleneck> bottlenecks = BottleneckAnalyzer::analyze(
                request.walkable_cells,
                costs,
                request.bottleneck_zone_radius);
            for (const DetectedBottleneck &bottleneck : bottlenecks)
            {
                const Vec2i relative(
                    bottleneck.cell.x - request.cell_origin.x,
                    bottleneck.cell.y - request.cell_origin.y);
                const int index = field.add_bottleneck(
                    relative, bottleneck.axis, bottleneck.route_cost);
                for (const Vec2i &zone_cell : bottleneck.zone_cells)
                {
                    field.add_bottleneck_zone_cell(index, {
                        zone_cell.x - request.cell_origin.x,
                        zone_cell.y - request.cell_origin.y});
                }
            }
        }
        else
        {
            field.clear_bottlenecks();
        }

        const std::vector<Vec2> directions = FlowFieldAlgorithms::generate_directions(
            request.width,
            request.height,
            request.cell_origin,
            request.walkable_cells,
            costs,
            distances,
            request.wall_clearance_weight,
            &request.traversal_constraints);
        for (int y = 0; y < request.height; ++y)
        {
            for (int x = 0; x < request.width; ++x)
                field.set_dir(x, y, directions[y * request.width + x]);
        }

        const Vec2i relative_goal(
            request.goal_cell.x - request.cell_origin.x,
            request.goal_cell.y - request.cell_origin.y);
        field.set_dir(relative_goal.x, relative_goal.y, Vec2());
        field.set_goal_cell(relative_goal);
        result.ok = true;
        return result;
    }
} // namespace ffcore
