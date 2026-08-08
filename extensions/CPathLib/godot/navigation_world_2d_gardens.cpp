#include "navigation_world_2d.h"

#include <algorithm>

namespace godot
{
    std::int64_t NavigationWorld2D::encode_area_handle(ffcore::AreaHandle handle)
    { return static_cast<std::int64_t>((static_cast<std::uint64_t>(handle.generation) << 32) | handle.index); }

    std::int64_t NavigationWorld2D::encode_portal_handle(ffcore::PortalHandle handle)
    { return static_cast<std::int64_t>((static_cast<std::uint64_t>(handle.generation) << 32) | handle.index); }

    ffcore::AreaHandle NavigationWorld2D::decode_area_handle(std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    ffcore::PortalHandle NavigationWorld2D::decode_portal_handle(std::int64_t encoded)
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

    std::int64_t NavigationWorld2D::create_garden(
        const PackedVector2Array &interior_cells,
        const PackedVector2Array &target_cells)
    {
        return create_area(interior_cells, target_cells);
    }

    std::int64_t NavigationWorld2D::create_garden_from_seed(
        Vector2i seed,
        int maximum_cells,
        std::int64_t blocker_channel_mask)
    {
        return encode_area_handle(world.create_area_from_seed(
            {seed.x, seed.y},
            static_cast<std::size_t>(std::max(0, maximum_cells)),
            static_cast<std::uint64_t>(blocker_channel_mask)));
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

    std::int64_t NavigationWorld2D::create_garden_portal(
        std::int64_t garden_handle,
        const PackedVector2Array &boundary_cells,
        const PackedVector2Array &outside_cells,
        int direction,
        int capacity)
    {
        return create_portal(
            garden_handle, boundary_cells, outside_cells, direction, capacity);
    }

    bool NavigationWorld2D::remove_area(std::int64_t area_handle)
    { return world.areas().remove_area(decode_area_handle(area_handle)); }

    bool NavigationWorld2D::remove_garden(std::int64_t garden_handle)
    { return remove_area(garden_handle); }

    bool NavigationWorld2D::set_garden_cells(
        std::int64_t garden_handle,
        const PackedVector2Array &interior_cells)
    {
        return world.areas().set_area_interior_cells(
            decode_area_handle(garden_handle), convert_cells(interior_cells));
    }

    bool NavigationWorld2D::set_garden_target_cells(
        std::int64_t garden_handle,
        const PackedVector2Array &target_cells)
    {
        return world.areas().set_area_target_cells(
            decode_area_handle(garden_handle), convert_cells(target_cells));
    }

    bool NavigationWorld2D::remove_portal(std::int64_t portal_handle)
    { return world.areas().remove_portal(decode_portal_handle(portal_handle)); }

    Dictionary NavigationWorld2D::get_garden_info(std::int64_t garden_handle) const
    {
        Dictionary info;
        const ffcore::NavigationArea *garden = world.areas().get_area(
            decode_area_handle(garden_handle));
        if (garden == nullptr)
        {
            info["valid"] = false;
            return info;
        }
        info["valid"] = true;
        info["revision"] = static_cast<std::int64_t>(garden->revision);
        PackedVector2Array interior;
        interior.resize(static_cast<int>(garden->interior_cells.size()));
        for (int index = 0; index < static_cast<int>(garden->interior_cells.size()); ++index)
            interior.set(index, Vector2(garden->interior_cells[index].x, garden->interior_cells[index].y));
        info["interior_cells"] = interior;
        PackedVector2Array targets;
        targets.resize(static_cast<int>(garden->target_cells.size()));
        for (int index = 0; index < static_cast<int>(garden->target_cells.size()); ++index)
            targets.set(index, Vector2(garden->target_cells[index].x, garden->target_cells[index].y));
        info["target_cells"] = targets;
        PackedInt64Array portals;
        portals.resize(static_cast<int>(garden->portals.size()));
        for (int index = 0; index < static_cast<int>(garden->portals.size()); ++index)
            portals.set(index, encode_portal_handle(garden->portals[index]));
        info["portal_handles"] = portals;
        return info;
    }

    Dictionary NavigationWorld2D::get_portal_info(std::int64_t portal_handle) const
    {
        Dictionary info;
        const ffcore::AreaPortal *portal = world.areas().get_portal(
            decode_portal_handle(portal_handle));
        if (portal == nullptr)
        {
            info["valid"] = false;
            return info;
        }
        info["valid"] = true;
        info["garden_handle"] = encode_area_handle(portal->area);
        info["direction"] = static_cast<int>(portal->direction);
        info["capacity"] = static_cast<int>(portal->capacity);
        PackedVector2Array boundary;
        boundary.resize(static_cast<int>(portal->boundary_cells.size()));
        for (int index = 0; index < static_cast<int>(portal->boundary_cells.size()); ++index)
            boundary.set(index, Vector2(portal->boundary_cells[index].x, portal->boundary_cells[index].y));
        info["boundary_cells"] = boundary;
        PackedVector2Array outside;
        outside.resize(static_cast<int>(portal->outside_cells.size()));
        for (int index = 0; index < static_cast<int>(portal->outside_cells.size()); ++index)
            outside.set(index, Vector2(portal->outside_cells[index].x, portal->outside_cells[index].y));
        info["outside_cells"] = outside;
        return info;
    }

    PackedInt64Array NavigationWorld2D::get_garden_handles() const
    {
        const std::vector<ffcore::AreaHandle> handles = world.areas().active_areas();
        PackedInt64Array result;
        result.resize(static_cast<int>(handles.size()));
        for (int index = 0; index < static_cast<int>(handles.size()); ++index)
            result.set(index, encode_area_handle(handles[index]));
        return result;
    }

    PackedInt64Array NavigationWorld2D::get_portal_handles() const
    {
        const std::vector<ffcore::PortalHandle> handles = world.areas().active_portals();
        PackedInt64Array result;
        result.resize(static_cast<int>(handles.size()));
        for (int index = 0; index < static_cast<int>(handles.size()); ++index)
            result.set(index, encode_portal_handle(handles[index]));
        return result;
    }

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

    Ref<NavigationRoute2D> NavigationWorld2D::plan_enter_garden(
        std::int64_t garden_handle,
        Vector2i world_start,
        Vector2i garden_destination,
        std::int64_t blocker_channel_mask) const
    {
        Ref<NavigationRoute2D> route;
        route.instantiate();
        route->set_core_route(world.plan_enter_area(
            decode_area_handle(garden_handle),
            {world_start.x, world_start.y},
            {garden_destination.x, garden_destination.y},
            static_cast<std::uint64_t>(blocker_channel_mask)));
        return route;
    }

    Ref<NavigationRoute2D> NavigationWorld2D::plan_exit_garden(
        std::int64_t garden_handle,
        Vector2i garden_start,
        Vector2i world_destination,
        std::int64_t blocker_channel_mask) const
    {
        Ref<NavigationRoute2D> route;
        route.instantiate();
        route->set_core_route(world.plan_exit_area(
            decode_area_handle(garden_handle),
            {garden_start.x, garden_start.y},
            {world_destination.x, world_destination.y},
            static_cast<std::uint64_t>(blocker_channel_mask)));
        return route;
    }

    bool NavigationWorld2D::is_route_current(const Ref<NavigationRoute2D> &route) const
    {
        return route.is_valid() && world.is_route_current(route->core_route());
    }
} // namespace godot
