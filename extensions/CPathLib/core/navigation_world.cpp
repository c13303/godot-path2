#include "navigation_world.h"

#include <algorithm>
#include <cmath>
#include <utility>

namespace ffcore
{
    void NavigationWorld::set_config(const NavigationWorldConfig &new_config)
    {
        NavigationWorldConfig sanitized = new_config;
        sanitized.flow_wall_clearance_weight = std::isfinite(sanitized.flow_wall_clearance_weight)
            ? std::max(0.0, sanitized.flow_wall_clearance_weight) : 0.0;
        sanitized.bottleneck_zone_radius = std::clamp(sanitized.bottleneck_zone_radius, 0, 2);
        const bool blocker_policy_changed =
            config.default_blocker_channel_mask != sanitized.default_blocker_channel_mask;
        if (config.flow_wall_clearance_weight == sanitized.flow_wall_clearance_weight &&
            config.detect_bottlenecks == sanitized.detect_bottlenecks &&
            config.bottleneck_zone_radius == sanitized.bottleneck_zone_radius &&
            !blocker_policy_changed &&
            config.default_directional_channel == sanitized.default_directional_channel)
            return;
        config = sanitized;
        if (blocker_policy_changed)
            ++topology_revision;
        ++cost_revision;
        flow_store.mark_stale();
    }

    bool NavigationWorld::contains_cell(const Vec2i &cell) const
    {
        return grid_definition.is_valid() &&
               cell.x >= grid_definition.cell_origin.x &&
               cell.y >= grid_definition.cell_origin.y &&
               cell.x < grid_definition.cell_origin.x + grid_definition.width &&
               cell.y < grid_definition.cell_origin.y + grid_definition.height;
    }

    void NavigationWorld::effective_cells(
        std::uint64_t blocker_channel_mask,
        CellSet &effective_walkables,
        CellSet &effective_physical_walls) const
    {
        effective_walkables = walkable_cells;
        effective_physical_walls = physical_wall_cells;
        channel_store.apply_blockers(
            blocker_channel_mask, effective_walkables, effective_physical_walls);
    }

    bool NavigationWorld::set_grid(
        const GridDefinition &definition,
        const std::vector<Vec2i> &walkables,
        const std::vector<Vec2i> &physical_walls)
    {
        if (!definition.is_valid())
            return false;

        grid_definition = definition;
        channel_store = NavigationChannelStore();
        walkable_cells.clear();
        physical_wall_cells.clear();
        traversal_costs.clear();
        for (const Vec2i &cell : walkables)
        {
            if (contains_cell(cell))
                walkable_cells.insert(cell);
        }
        for (const Vec2i &cell : physical_walls)
        {
            if (contains_cell(cell))
                physical_wall_cells.insert(cell);
        }
        ++topology_revision;
        ++cost_revision;
        flow_store.mark_stale();
        return true;
    }

    bool NavigationWorld::set_cell_walkable(const Vec2i &cell, bool walkable)
    {
        if (!contains_cell(cell))
            return false;
        const bool changed = walkable ? walkable_cells.insert(cell).second
                                      : walkable_cells.erase(cell) != 0;
        if (changed)
        {
            ++topology_revision;
            flow_store.mark_stale();
        }
        return changed;
    }

    bool NavigationWorld::set_cell_physics_blocked(const Vec2i &cell, bool blocked)
    {
        if (!contains_cell(cell))
            return false;
        const bool changed = blocked ? physical_wall_cells.insert(cell).second
                                     : physical_wall_cells.erase(cell) != 0;
        if (changed)
        {
            ++topology_revision;
            flow_store.mark_stale();
        }
        return changed;
    }

    bool NavigationWorld::set_cell_traversal_cost(const Vec2i &cell, double cost)
    {
        if (!contains_cell(cell) || !std::isfinite(cost) || cost <= 0.0)
            return false;
        const auto existing = traversal_costs.find(cell);
        if (std::abs(cost - 1.0) <= 1e-12)
        {
            if (existing == traversal_costs.end())
                return false;
            traversal_costs.erase(existing);
        }
        else
        {
            if (existing != traversal_costs.end() && std::abs(existing->second - cost) <= 1e-12)
                return false;
            traversal_costs[cell] = cost;
        }
        ++cost_revision;
        flow_store.mark_stale();
        return true;
    }

    WorldPathResult NavigationWorld::find_path(const Vec2i &start, const Vec2i &goal) const
    {
        return find_path(start, goal, config.default_blocker_channel_mask);
    }

    WorldPathResult NavigationWorld::find_path(
        const Vec2i &start,
        const Vec2i &goal,
        std::uint64_t blocker_channel_mask) const
    {
        WorldPathResult result;
        result.topology_revision = topology_revision;
        if (!contains_cell(start) || !contains_cell(goal))
            return result;

        CellSet effective_walkables;
        CellSet effective_walls;
        effective_cells(blocker_channel_mask, effective_walkables, effective_walls);
        std::vector<Vec2i> walkables(effective_walkables.begin(), effective_walkables.end());
        std::vector<Vec2i> blockers(effective_walls.begin(), effective_walls.end());
        AStarSolver solver;
        solver.set_walkable_cells(walkables);
        solver.set_blocked_cells(blockers);
        std::vector<Vec2i> cost_cells;
        std::vector<double> costs;
        cost_cells.reserve(traversal_costs.size());
        costs.reserve(traversal_costs.size());
        for (const auto &entry : traversal_costs)
        {
            cost_cells.push_back(entry.first);
            costs.push_back(entry.second);
        }
        solver.set_traversal_costs(cost_cells, costs);
        result.cells = solver.find_path(start, goal);
        result.status = result.cells.empty() ? NavigationStatus::Unreachable : NavigationStatus::Found;
        return result;
    }

    WorldFlowResult NavigationWorld::build_flow(
        const Vec2i &goal,
        const FlowBuildOptions &options) const
    {
        WorldFlowResult result;
        result.topology_revision = topology_revision;
        result.cost_revision = cost_revision;
        if (!contains_cell(goal))
            return result;

        FlowFieldBuildRequest request = create_flow_request(goal, options);
        FlowFieldBuildResult build_result = FlowFieldBuilder::build(request);
        if (!build_result.ok)
        {
            result.status = NavigationStatus::Unreachable;
            return result;
        }
        result.field.copy_from(build_result.field);
        result.status = NavigationStatus::Found;
        return result;
    }

    WorldFlowResult NavigationWorld::build_flow(const Vec2i &goal) const
    {
        FlowBuildOptions options;
        options.blocker_channel_mask = config.default_blocker_channel_mask;
        options.directional_channel = config.default_directional_channel;
        return build_flow(goal, options);
    }

    FlowHandle NavigationWorld::create_flow(
        const Vec2i &goal,
        const FlowBuildOptions &options)
    {
        const FlowHandle handle = begin_flow_request(goal);
        complete_flow_request(handle, build_flow(goal, options));
        return handle;
    }

    FlowHandle NavigationWorld::create_flow(const Vec2i &goal)
    {
        FlowBuildOptions options;
        options.blocker_channel_mask = config.default_blocker_channel_mask;
        options.directional_channel = config.default_directional_channel;
        return create_flow(goal, options);
    }

    FlowHandle NavigationWorld::begin_flow_request(const Vec2i &goal)
    {
        return flow_store.create_pending(goal, topology_revision, cost_revision);
    }

    bool NavigationWorld::complete_flow_request(
        FlowHandle handle,
        const WorldFlowResult &result)
    {
        StoredFlow *stored = flow_store.get(handle);
        if (stored == nullptr)
            return false;
        if (!revisions_match(result.topology_revision, result.cost_revision))
            return flow_store.set_status(handle, FlowStatus::Stale);
        if (result.status != NavigationStatus::Found)
            return flow_store.set_status(
                handle, result.status == NavigationStatus::Stale
                    ? FlowStatus::Stale : FlowStatus::Unreachable);
        return flow_store.store(
            handle, result.field, result.topology_revision, result.cost_revision);
    }

    bool NavigationWorld::set_flow_status(FlowHandle handle, FlowStatus status)
    {
        return flow_store.set_status(handle, status);
    }

    bool NavigationWorld::release_flow(FlowHandle handle)
    {
        return flow_store.release(handle);
    }

    FlowFieldBuildRequest NavigationWorld::create_flow_request(
        const Vec2i &goal,
        const FlowBuildOptions &options) const
    {
        CellSet effective_walkables;
        CellSet effective_walls;
        effective_cells(options.blocker_channel_mask, effective_walkables, effective_walls);
        FlowFieldBuildRequest request;
        request.width = grid_definition.width;
        request.height = grid_definition.height;
        request.tile_size = grid_definition.cell_size;
        request.cell_origin = grid_definition.cell_origin;
        request.world_origin = grid_definition.world_origin;
        request.goal_cell = goal;
        request.walkable_cells = std::move(effective_walkables);
        request.physical_wall_cells = std::move(effective_walls);
        const DirectionalTraversalConstraints *stored_constraints =
            channel_store.get_directional_channel(options.directional_channel);
        if (stored_constraints != nullptr)
            request.traversal_constraints = *stored_constraints;
        for (const auto &constraint : options.additional_constraints)
            request.traversal_constraints[constraint.first] = constraint.second;
        request.wall_clearance_weight = config.flow_wall_clearance_weight;
        request.detect_bottlenecks = config.detect_bottlenecks;
        request.bottleneck_zone_radius = config.bottleneck_zone_radius;
        return request;
    }

    FlowFieldBuildRequest NavigationWorld::create_flow_request(const Vec2i &goal) const
    {
        FlowBuildOptions options;
        options.blocker_channel_mask = config.default_blocker_channel_mask;
        options.directional_channel = config.default_directional_channel;
        return create_flow_request(goal, options);
    }

    NavigationSnapshot NavigationWorld::snapshot() const
    {
        NavigationSnapshot result;
        result.grid = grid_definition;
        result.walkable_cells = walkable_cells;
        result.physical_wall_cells = physical_wall_cells;
        result.traversal_costs = traversal_costs;
        result.topology_revision = topology_revision;
        result.cost_revision = cost_revision;
        return result;
    }

    RoutePlan NavigationWorld::plan_enter_area(
        AreaHandle area,
        const Vec2i &world_start,
        const Vec2i &area_destination) const
    {
        return plan_enter_area(
            area, world_start, area_destination, config.default_blocker_channel_mask);
    }

    RoutePlan NavigationWorld::plan_enter_area(
        AreaHandle area,
        const Vec2i &world_start,
        const Vec2i &area_destination,
        std::uint64_t blocker_channel_mask) const
    {
        CellSet effective_walkables;
        CellSet effective_walls;
        effective_cells(blocker_channel_mask, effective_walkables, effective_walls);
        return RoutePlanner::plan_enter(
            area_store, area, world_start, area_destination,
            effective_walkables, topology_revision);
    }

    RoutePlan NavigationWorld::plan_exit_area(
        AreaHandle area,
        const Vec2i &area_start,
        const Vec2i &world_destination) const
    {
        return plan_exit_area(
            area, area_start, world_destination, config.default_blocker_channel_mask);
    }

    RoutePlan NavigationWorld::plan_exit_area(
        AreaHandle area,
        const Vec2i &area_start,
        const Vec2i &world_destination,
        std::uint64_t blocker_channel_mask) const
    {
        CellSet effective_walkables;
        CellSet effective_walls;
        effective_cells(blocker_channel_mask, effective_walkables, effective_walls);
        return RoutePlanner::plan_exit(
            area_store, area, area_start, world_destination,
            effective_walkables, topology_revision);
    }

    bool NavigationWorld::is_route_current(const RoutePlan &route) const
    {
        return route.is_current(topology_revision, area_store);
    }

    bool NavigationWorld::replace_blocker_channel(
        std::uint32_t channel,
        const std::vector<Vec2i> &cells,
        bool blocks_navigation,
        bool blocks_physics)
    {
        if (channel >= 64)
            return false;
        CellSet filtered;
        for (const Vec2i &cell : cells)
        {
            if (contains_cell(cell))
                filtered.insert(cell);
        }
        if (!channel_store.replace_blocker_channel(
                channel, filtered, blocks_navigation, blocks_physics))
            return false;
        ++topology_revision;
        flow_store.mark_stale();
        return true;
    }

    bool NavigationWorld::clear_blocker_channel(std::uint32_t channel)
    {
        if (!channel_store.clear_blocker_channel(channel))
            return false;
        ++topology_revision;
        flow_store.mark_stale();
        return true;
    }

    bool NavigationWorld::set_blocker_channel_cell(
        std::uint32_t channel,
        const Vec2i &cell,
        bool blocked,
        bool blocks_navigation,
        bool blocks_physics)
    {
        if (channel >= 64 || !contains_cell(cell) ||
            !channel_store.set_blocker_cell(
                channel, cell, blocked, blocks_navigation, blocks_physics))
            return false;
        ++topology_revision;
        flow_store.mark_stale();
        return true;
    }

    bool NavigationWorld::replace_directional_channel(
        int channel,
        const DirectionalTraversalConstraints &constraints)
    {
        if (channel < 0)
            return false;
        DirectionalTraversalConstraints filtered;
        for (const auto &entry : constraints)
        {
            if (contains_cell(entry.first) &&
                std::abs(entry.second.x) + std::abs(entry.second.y) == 1)
                filtered[entry.first] = entry.second;
        }
        if (!channel_store.replace_directional_channel(channel, filtered))
            return false;
        ++cost_revision;
        flow_store.mark_stale();
        return true;
    }

    bool NavigationWorld::clear_directional_channel(int channel)
    {
        if (!channel_store.clear_directional_channel(channel))
            return false;
        ++cost_revision;
        flow_store.mark_stale();
        return true;
    }

    AreaHandle NavigationWorld::create_area_from_seed(
        const Vec2i &seed,
        std::size_t maximum_cells)
    {
        return create_area_from_seed(
            seed, maximum_cells, config.default_blocker_channel_mask);
    }

    AreaHandle NavigationWorld::create_area_from_seed(
        const Vec2i &seed,
        std::size_t maximum_cells,
        std::uint64_t blocker_channel_mask)
    {
        CellSet effective_walkables;
        CellSet effective_walls;
        effective_cells(blocker_channel_mask, effective_walkables, effective_walls);
        const AreaBuildResult built = AreaBuilder::from_seed(
            seed, effective_walkables, maximum_cells);
        return area_store.create_area(built.interior_cells);
    }
} // namespace ffcore
