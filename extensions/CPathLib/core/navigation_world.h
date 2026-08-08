#pragma once

#include "../flow/flow_field_builder.h"
#include "../pathfinding/a_star_solver.h"
#include "../area/navigation_area.h"
#include "../area/route_planner.h"

#include <cstdint>
#include <vector>

namespace ffcore
{
    struct GridDefinition
    {
        int width = 0;
        int height = 0;
        double cell_size = 1.0;
        Vec2 world_origin;
        Vec2i cell_origin;

        bool is_valid() const { return width > 0 && height > 0 && cell_size > 0.0; }
    };

    struct NavigationWorldConfig
    {
        double flow_wall_clearance_weight = 0.0;
        bool detect_bottlenecks = true;
        int bottleneck_zone_radius = 0;
    };

    enum class NavigationStatus
    {
        Found,
        Unreachable,
        InvalidInput,
        Stale
    };

    struct WorldPathResult
    {
        NavigationStatus status = NavigationStatus::InvalidInput;
        std::vector<Vec2i> cells;
        std::uint64_t topology_revision = 0;
    };

    struct WorldFlowResult
    {
        NavigationStatus status = NavigationStatus::InvalidInput;
        FlowField field;
        std::uint64_t topology_revision = 0;
        std::uint64_t cost_revision = 0;
    };

    struct NavigationSnapshot
    {
        GridDefinition grid;
        CellSet walkable_cells;
        CellSet physical_wall_cells;
        std::unordered_map<Vec2i, double, CellHash> traversal_costs;
        std::uint64_t topology_revision = 0;
        std::uint64_t cost_revision = 0;
    };

    class NavigationWorld
    {
    private:
        GridDefinition grid_definition;
        NavigationWorldConfig config;
        CellSet walkable_cells;
        CellSet physical_wall_cells;
        std::unordered_map<Vec2i, double, CellHash> traversal_costs;
        NavigationAreaStore area_store;
        std::uint64_t topology_revision = 0;
        std::uint64_t cost_revision = 0;

        bool contains_cell(const Vec2i &cell) const;

    public:
        void set_config(const NavigationWorldConfig &new_config);
        const NavigationWorldConfig &get_config() const { return config; }

        bool set_grid(const GridDefinition &definition,
                      const std::vector<Vec2i> &walkables,
                      const std::vector<Vec2i> &physical_walls = {});
        bool set_cell_walkable(const Vec2i &cell, bool walkable);
        bool set_cell_physics_blocked(const Vec2i &cell, bool blocked);
        bool set_cell_traversal_cost(const Vec2i &cell, double cost);

        WorldPathResult find_path(const Vec2i &start, const Vec2i &goal) const;
        WorldFlowResult build_flow(
            const Vec2i &goal,
            const DirectionalTraversalConstraints &constraints = {}) const;
        FlowFieldBuildRequest create_flow_request(
            const Vec2i &goal,
            const DirectionalTraversalConstraints &constraints = {}) const;
        NavigationSnapshot snapshot() const;
        RoutePlan plan_enter_area(AreaHandle area, const Vec2i &world_start,
                                  const Vec2i &area_destination) const;
        RoutePlan plan_exit_area(AreaHandle area, const Vec2i &area_start,
                                 const Vec2i &world_destination) const;
        bool is_route_current(const RoutePlan &route) const;

        NavigationAreaStore &areas() { return area_store; }
        const NavigationAreaStore &areas() const { return area_store; }

        const GridDefinition &grid() const { return grid_definition; }
        std::uint64_t get_topology_revision() const { return topology_revision; }
        std::uint64_t get_cost_revision() const { return cost_revision; }
        bool revisions_match(std::uint64_t topology, std::uint64_t cost) const
        { return topology == topology_revision && cost == cost_revision; }
    };
} // namespace ffcore
