#include "navigation_world_2d.h"

#include <godot_cpp/core/class_db.hpp>
#include <algorithm>
#include <vector>

namespace godot
{
    namespace
    {
        std::vector<ffcore::Vec2i> convert_cells(const PackedVector2Array &cells)
        {
            std::vector<ffcore::Vec2i> converted;
            converted.reserve(cells.size());
            for (int index = 0; index < cells.size(); ++index)
            {
                const Vector2 cell = cells[index];
                converted.push_back({static_cast<int>(cell.x), static_cast<int>(cell.y)});
            }
            return converted;
        }
    }

    void NavigationWorld2D::_bind_methods()
    {
        ClassDB::bind_method(D_METHOD("configure_grid", "bounds", "cell_size", "world_origin", "walkable_cells", "physical_wall_cells"), &NavigationWorld2D::configure_grid);
        ClassDB::bind_method(D_METHOD("configure_sparse_grid", "walkable_cells", "blocked_cells"), &NavigationWorld2D::configure_sparse_grid);
        ClassDB::bind_method(D_METHOD("configure_flow", "wall_clearance_weight", "detect_bottlenecks", "bottleneck_zone_radius"), &NavigationWorld2D::configure_flow);
        ClassDB::bind_method(D_METHOD("set_cell_walkable", "cell", "walkable"), &NavigationWorld2D::set_cell_walkable);
        ClassDB::bind_method(D_METHOD("set_cell_physics_blocked", "cell", "blocked"), &NavigationWorld2D::set_cell_physics_blocked);
        ClassDB::bind_method(D_METHOD("set_cell_traversal_cost", "cell", "cost"), &NavigationWorld2D::set_cell_traversal_cost);
        ClassDB::bind_method(D_METHOD("find_path_cells", "start", "goal"), &NavigationWorld2D::find_path_cells);
        ClassDB::bind_method(D_METHOD("build_flow_to_cell", "goal"), &NavigationWorld2D::build_flow_to_cell);
        ClassDB::bind_method(D_METHOD("request_flow_to_cell", "goal"), &NavigationWorld2D::request_flow_to_cell);
        ClassDB::bind_method(D_METHOD("cancel_flow_request", "request_id"), &NavigationWorld2D::cancel_flow_request);
        ClassDB::bind_method(D_METHOD("sample_latest_flow", "world_position"), &NavigationWorld2D::sample_latest_flow);
        ClassDB::bind_method(D_METHOD("get_topology_revision"), &NavigationWorld2D::get_topology_revision);
        ClassDB::bind_method(D_METHOD("get_cost_revision"), &NavigationWorld2D::get_cost_revision);
        ClassDB::bind_method(D_METHOD("create_area", "interior_cells", "target_cells"), &NavigationWorld2D::create_area);
        ClassDB::bind_method(D_METHOD("create_portal", "area_handle", "boundary_cells", "outside_cells", "direction", "capacity"), &NavigationWorld2D::create_portal);
        ClassDB::bind_method(D_METHOD("remove_area", "area_handle"), &NavigationWorld2D::remove_area);
        ClassDB::bind_method(D_METHOD("plan_enter_area", "area_handle", "world_start", "area_destination"), &NavigationWorld2D::plan_enter_area);
        ClassDB::bind_method(D_METHOD("plan_exit_area", "area_handle", "area_start", "world_destination"), &NavigationWorld2D::plan_exit_area);
        ClassDB::bind_method(D_METHOD("is_route_current", "route"), &NavigationWorld2D::is_route_current);
        ADD_SIGNAL(MethodInfo("flow_ready",
                              PropertyInfo(Variant::INT, "request_id"),
                              PropertyInfo(Variant::INT, "status"),
                              PropertyInfo(Variant::INT, "topology_revision")));
    }

    bool NavigationWorld2D::configure_grid(
        Rect2i bounds,
        double cell_size,
        Vector2 world_origin,
        const PackedVector2Array &walkable_cells,
        const PackedVector2Array &physical_wall_cells)
    {
        ffcore::GridDefinition definition;
        definition.width = bounds.size.x;
        definition.height = bounds.size.y;
        definition.cell_size = cell_size;
        definition.world_origin = {world_origin.x, world_origin.y};
        definition.cell_origin = {bounds.position.x, bounds.position.y};
        has_latest_flow = false;
        return world.set_grid(
            definition,
            convert_cells(walkable_cells),
            convert_cells(physical_wall_cells));
    }

    bool NavigationWorld2D::configure_sparse_grid(
        const PackedVector2Array &walkable_cells,
        const PackedVector2Array &blocked_cells)
    {
        bool has_cell = false;
        int min_x = 0;
        int min_y = 0;
        int max_x = 0;
        int max_y = 0;
        const auto include_cell = [&](const Vector2 &cell) {
            const int x = static_cast<int>(cell.x);
            const int y = static_cast<int>(cell.y);
            if (!has_cell)
            {
                min_x = max_x = x;
                min_y = max_y = y;
                has_cell = true;
                return;
            }
            min_x = std::min(min_x, x);
            min_y = std::min(min_y, y);
            max_x = std::max(max_x, x);
            max_y = std::max(max_y, y);
        };

        for (int index = 0; index < walkable_cells.size(); ++index)
            include_cell(walkable_cells[index]);
        for (int index = 0; index < blocked_cells.size(); ++index)
            include_cell(blocked_cells[index]);

        if (!has_cell)
        {
            min_x = min_y = max_x = max_y = 0;
        }

        return configure_grid(
            Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1),
            1.0,
            Vector2(),
            walkable_cells,
            blocked_cells);
    }

    void NavigationWorld2D::configure_flow(
        double wall_clearance_weight,
        bool detect_bottlenecks,
        int bottleneck_zone_radius)
    {
        ffcore::NavigationWorldConfig config;
        config.flow_wall_clearance_weight = wall_clearance_weight;
        config.detect_bottlenecks = detect_bottlenecks;
        config.bottleneck_zone_radius = std::clamp(bottleneck_zone_radius, 0, 2);
        world.set_config(config);
        has_latest_flow = false;
    }

    bool NavigationWorld2D::set_cell_walkable(Vector2i cell, bool walkable)
    {
        has_latest_flow = false;
        return world.set_cell_walkable({cell.x, cell.y}, walkable);
    }

    bool NavigationWorld2D::set_cell_physics_blocked(Vector2i cell, bool blocked)
    {
        has_latest_flow = false;
        return world.set_cell_physics_blocked({cell.x, cell.y}, blocked);
    }

    bool NavigationWorld2D::set_cell_traversal_cost(Vector2i cell, double cost)
    {
        return world.set_cell_traversal_cost({cell.x, cell.y}, cost);
    }

    PackedVector2Array NavigationWorld2D::find_path_cells(Vector2i start, Vector2i goal) const
    {
        const ffcore::WorldPathResult path = world.find_path({start.x, start.y}, {goal.x, goal.y});
        PackedVector2Array converted;
        converted.resize(static_cast<int>(path.cells.size()));
        for (int index = 0; index < static_cast<int>(path.cells.size()); ++index)
            converted.set(index, Vector2(path.cells[index].x, path.cells[index].y));
        return converted;
    }

    bool NavigationWorld2D::build_flow_to_cell(Vector2i goal)
    {
        const ffcore::WorldFlowResult result = world.build_flow({goal.x, goal.y});
        has_latest_flow = result.status == ffcore::NavigationStatus::Found;
        if (has_latest_flow)
            latest_flow.copy_from(result.field);
        return has_latest_flow;
    }

    std::int64_t NavigationWorld2D::request_flow_to_cell(Vector2i goal)
    {
        const ffcore::GridDefinition &grid = world.grid();
        if (!grid.is_valid())
            return 0;
        const std::uint64_t id = jobs.submit(
            world.create_flow_request({goal.x, goal.y}),
            world.get_topology_revision(),
            world.get_cost_revision());
        return static_cast<std::int64_t>(id);
    }

    void NavigationWorld2D::cancel_flow_request(std::int64_t request_id)
    {
        if (request_id > 0)
            jobs.cancel(static_cast<std::uint64_t>(request_id));
    }

    void NavigationWorld2D::_process(double)
    {
        ffcore::FlowFieldJobResult result;
        while (jobs.take_completed(result))
        {
            int status = static_cast<int>(ffcore::NavigationStatus::Stale);
            if (world.revisions_match(result.topology_revision, result.cost_revision))
            {
                status = result.build.ok ? static_cast<int>(ffcore::NavigationStatus::Found)
                                         : static_cast<int>(ffcore::NavigationStatus::Unreachable);
                if (result.build.ok)
                {
                    latest_flow.copy_from(result.build.field);
                    has_latest_flow = true;
                }
            }
            emit_signal("flow_ready",
                        static_cast<std::int64_t>(result.request_id),
                        status,
                        static_cast<std::int64_t>(result.topology_revision));
        }
    }

    Vector2 NavigationWorld2D::sample_latest_flow(Vector2 world_position) const
    {
        if (!has_latest_flow)
            return Vector2();
        const ffcore::Vec2 direction = latest_flow.compute_flow_dir({world_position.x, world_position.y});
        return Vector2(direction.x, direction.y);
    }

    std::int64_t NavigationWorld2D::get_topology_revision() const
    { return static_cast<std::int64_t>(world.get_topology_revision()); }

    std::int64_t NavigationWorld2D::get_cost_revision() const
    { return static_cast<std::int64_t>(world.get_cost_revision()); }

    std::int64_t NavigationWorld2D::encode_area_handle(ffcore::AreaHandle handle)
    { return static_cast<std::int64_t>((static_cast<std::uint64_t>(handle.generation) << 32) | handle.index); }

    std::int64_t NavigationWorld2D::encode_portal_handle(ffcore::PortalHandle handle)
    { return static_cast<std::int64_t>((static_cast<std::uint64_t>(handle.generation) << 32) | handle.index); }

    ffcore::AreaHandle NavigationWorld2D::decode_area_handle(std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    std::int64_t NavigationWorld2D::create_area(
        const PackedVector2Array &interior_cells,
        const PackedVector2Array &target_cells)
    {
        return encode_area_handle(world.areas().create_area(
            convert_cells(interior_cells), convert_cells(target_cells)));
    }

    std::int64_t NavigationWorld2D::create_portal(
        std::int64_t area_handle,
        const PackedVector2Array &boundary_cells,
        const PackedVector2Array &outside_cells,
        int direction,
        int capacity)
    {
        const ffcore::PortalDirection portal_direction = static_cast<ffcore::PortalDirection>(
            std::clamp(direction, 0, 2));
        return encode_portal_handle(world.areas().create_portal(
            decode_area_handle(area_handle),
            convert_cells(boundary_cells),
            convert_cells(outside_cells),
            portal_direction,
            static_cast<std::uint32_t>(std::max(1, capacity))));
    }

    bool NavigationWorld2D::remove_area(std::int64_t area_handle)
    { return world.areas().remove_area(decode_area_handle(area_handle)); }

    Ref<NavigationRoute2D> NavigationWorld2D::plan_enter_area(
        std::int64_t area_handle,
        Vector2i world_start,
        Vector2i area_destination) const
    {
        Ref<NavigationRoute2D> route;
        route.instantiate();
        route->set_core_route(world.plan_enter_area(
            decode_area_handle(area_handle),
            {world_start.x, world_start.y},
            {area_destination.x, area_destination.y}));
        return route;
    }

    Ref<NavigationRoute2D> NavigationWorld2D::plan_exit_area(
        std::int64_t area_handle,
        Vector2i area_start,
        Vector2i world_destination) const
    {
        Ref<NavigationRoute2D> route;
        route.instantiate();
        route->set_core_route(world.plan_exit_area(
            decode_area_handle(area_handle),
            {area_start.x, area_start.y},
            {world_destination.x, world_destination.y}));
        return route;
    }

    bool NavigationWorld2D::is_route_current(const Ref<NavigationRoute2D> &route) const
    {
        return route.is_valid() && world.is_route_current(route->core_route());
    }

    bool NavigationWorld2D::copy_latest_flow(ffcore::FlowField &destination) const
    {
        if (!has_latest_flow)
            return false;
        destination.copy_from(latest_flow);
        return true;
    }
} // namespace godot
