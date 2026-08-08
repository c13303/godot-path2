#pragma once

#include "../flow/flow_field_builder.h"
#include "../flow/flow_field_store.h"
#include "../pathfinding/a_star_solver.h"
#include "../area/navigation_area.h"
#include "../area/area_builder.h"
#include "../area/route_planner.h"
#include "navigation_channel_store.h"

#include <cstdint>
#include <limits>
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
        std::uint64_t default_blocker_channel_mask = std::numeric_limits<std::uint64_t>::max();
        int default_directional_channel = -1;
    };

    struct FlowBuildOptions
    {
        std::uint64_t blocker_channel_mask = std::numeric_limits<std::uint64_t>::max();
        int directional_channel = -1;
        DirectionalTraversalConstraints additional_constraints;
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
        NavigationChannelStore channel_store;
        FlowFieldStore flow_store;
        std::uint64_t topology_revision = 0;
        std::uint64_t cost_revision = 0;

        bool contains_cell(const Vec2i &cell) const;
        void effective_cells(std::uint64_t blocker_channel_mask,
                             CellSet &effective_walkables,
                             CellSet &effective_physical_walls) const;

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
        WorldPathResult find_path(const Vec2i &start, const Vec2i &goal,
                                  std::uint64_t blocker_channel_mask) const;
        WorldFlowResult build_flow(
            const Vec2i &goal,
            const FlowBuildOptions &options) const;
        WorldFlowResult build_flow(const Vec2i &goal) const;
        FlowHandle create_flow(
            const Vec2i &goal,
            const FlowBuildOptions &options);
        FlowHandle create_flow(const Vec2i &goal);
        FlowHandle begin_flow_request(const Vec2i &goal);
        bool complete_flow_request(FlowHandle handle, const WorldFlowResult &result);
        bool set_flow_status(FlowHandle handle, FlowStatus status);
        bool release_flow(FlowHandle handle);
        const StoredFlow *get_flow(FlowHandle handle) const { return flow_store.get(handle); }
        std::vector<FlowHandle> active_flows() const { return flow_store.active_handles(); }
        FlowFieldBuildRequest create_flow_request(
            const Vec2i &goal,
            const FlowBuildOptions &options) const;
        FlowFieldBuildRequest create_flow_request(const Vec2i &goal) const;
        NavigationSnapshot snapshot() const;
        RoutePlan plan_enter_area(AreaHandle area, const Vec2i &world_start,
                                  const Vec2i &area_destination) const;
        RoutePlan plan_enter_area(AreaHandle area, const Vec2i &world_start,
                                  const Vec2i &area_destination,
                                  std::uint64_t blocker_channel_mask) const;
        RoutePlan plan_exit_area(AreaHandle area, const Vec2i &area_start,
                                 const Vec2i &world_destination) const;
        RoutePlan plan_exit_area(AreaHandle area, const Vec2i &area_start,
                                 const Vec2i &world_destination,
                                 std::uint64_t blocker_channel_mask) const;
        bool is_route_current(const RoutePlan &route) const;

        bool replace_blocker_channel(std::uint32_t channel,
                                     const std::vector<Vec2i> &cells,
                                     bool blocks_navigation,
                                     bool blocks_physics);
        bool clear_blocker_channel(std::uint32_t channel);
        bool set_blocker_channel_cell(std::uint32_t channel, const Vec2i &cell, bool blocked,
                                      bool blocks_navigation, bool blocks_physics);
        bool replace_directional_channel(
            int channel, const DirectionalTraversalConstraints &constraints);
        bool clear_directional_channel(int channel);
        AreaHandle create_area_from_seed(const Vec2i &seed,
                                         std::size_t maximum_cells = 0);
        AreaHandle create_area_from_seed(const Vec2i &seed,
                                         std::size_t maximum_cells,
                                         std::uint64_t blocker_channel_mask);

        NavigationAreaStore &areas() { return area_store; }
        const NavigationAreaStore &areas() const { return area_store; }
        const NavigationChannelStore &channels() const { return channel_store; }
        const FlowFieldStore &flows() const { return flow_store; }

        const GridDefinition &grid() const { return grid_definition; }
        std::uint64_t get_topology_revision() const { return topology_revision; }
        std::uint64_t get_cost_revision() const { return cost_revision; }
        bool revisions_match(std::uint64_t topology, std::uint64_t cost) const
        { return topology == topology_revision && cost == cost_revision; }
    };
} // namespace ffcore
