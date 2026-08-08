#include "route_planner.h"

#include "../pathfinding/a_star_solver.h"

namespace ffcore
{
    namespace
    {
        std::vector<Vec2i> solve(const CellSet &walkable, const Vec2i &start, const Vec2i &goal)
        {
            AStarSolver solver;
            solver.set_walkable_cells({walkable.begin(), walkable.end()});
            return solver.find_path(start, goal);
        }

        Vec2i paired_cell(const AreaPortal &portal, const Vec2i &selected, bool entering)
        {
            const std::vector<Vec2i> &source = entering ? portal.outside_cells : portal.boundary_cells;
            const std::vector<Vec2i> &destination = entering ? portal.boundary_cells : portal.outside_cells;
            for (std::size_t index = 0; index < source.size(); ++index)
            {
                if (source[index] == selected)
                    return destination[std::min(index, destination.size() - 1)];
            }
            return destination.front();
        }

        CellSet area_cells(const NavigationArea &area)
        {
            return {area.interior_cells.begin(), area.interior_cells.end()};
        }
    }

    bool RoutePlan::is_current(
        std::uint64_t current_topology_revision,
        const NavigationAreaStore &store) const
    {
        const NavigationArea *current_area = store.get_area(area);
        return status == RouteStatus::Found &&
               topology_revision == current_topology_revision &&
               current_area != nullptr && current_area->revision == area_revision;
    }

    RoutePlan RoutePlanner::plan_enter(
        const NavigationAreaStore &store,
        AreaHandle area_handle,
        const Vec2i &world_start,
        const Vec2i &area_destination,
        const CellSet &world_walkable,
        std::uint64_t topology_revision)
    {
        RoutePlan plan;
        plan.area = area_handle;
        plan.topology_revision = topology_revision;
        const NavigationArea *area = store.get_area(area_handle);
        if (area == nullptr)
            return plan;
        plan.area_revision = area->revision;

        const PortalSelectionResult selection = PortalSelector::select(
            store, *area, world_start, world_walkable, PortalUse::Enter);
        if (!selection.found)
        {
            plan.status = RouteStatus::Unreachable;
            return plan;
        }
        const AreaPortal *portal = store.get_portal(selection.portal);
        const Vec2i boundary = paired_cell(*portal, selection.approach_cell, true);
        const std::vector<Vec2i> world_path = solve(world_walkable, world_start, selection.approach_cell);
        const std::vector<Vec2i> local_path = solve(area_cells(*area), boundary, area_destination);
        if (world_path.empty() || local_path.empty())
        {
            plan.status = RouteStatus::Unreachable;
            return plan;
        }
        plan.segments.push_back({RouteSegmentType::WorldPath, world_path, {}});
        plan.segments.push_back({RouteSegmentType::PortalCrossing, {selection.approach_cell, boundary}, selection.portal});
        plan.segments.push_back({RouteSegmentType::AreaPath, local_path, {}});
        plan.status = RouteStatus::Found;
        return plan;
    }

    RoutePlan RoutePlanner::plan_exit(
        const NavigationAreaStore &store,
        AreaHandle area_handle,
        const Vec2i &area_start,
        const Vec2i &world_destination,
        const CellSet &world_walkable,
        std::uint64_t topology_revision)
    {
        RoutePlan plan;
        plan.area = area_handle;
        plan.topology_revision = topology_revision;
        const NavigationArea *area = store.get_area(area_handle);
        if (area == nullptr)
            return plan;
        plan.area_revision = area->revision;

        const CellSet local_walkable = area_cells(*area);
        const PortalSelectionResult selection = PortalSelector::select(
            store, *area, area_start, local_walkable, PortalUse::Exit);
        if (!selection.found)
        {
            plan.status = RouteStatus::Unreachable;
            return plan;
        }
        const AreaPortal *portal = store.get_portal(selection.portal);
        const Vec2i outside = paired_cell(*portal, selection.approach_cell, false);
        const std::vector<Vec2i> local_path = solve(local_walkable, area_start, selection.approach_cell);
        const std::vector<Vec2i> world_path = solve(world_walkable, outside, world_destination);
        if (local_path.empty() || world_path.empty())
        {
            plan.status = RouteStatus::Unreachable;
            return plan;
        }
        plan.segments.push_back({RouteSegmentType::AreaPath, local_path, {}});
        plan.segments.push_back({RouteSegmentType::PortalCrossing, {selection.approach_cell, outside}, selection.portal});
        plan.segments.push_back({RouteSegmentType::WorldPath, world_path, {}});
        plan.status = RouteStatus::Found;
        return plan;
    }
} // namespace ffcore
