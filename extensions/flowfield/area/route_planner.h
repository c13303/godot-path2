#pragma once

#include "portal_selector.h"

namespace ffcore
{
    enum class RouteSegmentType
    {
        WorldPath,
        PortalCrossing,
        AreaPath
    };

    enum class RouteStatus
    {
        Found,
        InvalidInput,
        Unreachable,
        Stale
    };

    struct RouteSegment
    {
        RouteSegmentType type = RouteSegmentType::WorldPath;
        std::vector<Vec2i> cells;
        PortalHandle portal;
    };

    struct RoutePlan
    {
        RouteStatus status = RouteStatus::InvalidInput;
        AreaHandle area;
        std::vector<RouteSegment> segments;
        std::uint64_t topology_revision = 0;
        std::uint64_t area_revision = 0;

        bool is_current(std::uint64_t current_topology_revision,
                        const NavigationAreaStore &store) const;
    };

    class RoutePlanner
    {
    public:
        static RoutePlan plan_enter(
            const NavigationAreaStore &store,
            AreaHandle area,
            const Vec2i &world_start,
            const Vec2i &area_destination,
            const CellSet &world_walkable,
            std::uint64_t topology_revision);

        static RoutePlan plan_exit(
            const NavigationAreaStore &store,
            AreaHandle area,
            const Vec2i &area_start,
            const Vec2i &world_destination,
            const CellSet &world_walkable,
            std::uint64_t topology_revision);
    };
} // namespace ffcore
