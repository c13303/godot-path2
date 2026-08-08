#pragma once

#include "navigation_area.h"
#include "../flow/flow_field_algorithms.h"

#include <limits>

namespace ffcore
{
    enum class PortalUse
    {
        Enter,
        Exit
    };

    struct PortalSelectionResult
    {
        PortalHandle portal;
        Vec2i approach_cell;
        double route_cost = std::numeric_limits<double>::infinity();
        bool found = false;
    };

    class PortalSelector
    {
    public:
        static PortalSelectionResult select(
            const NavigationAreaStore &store,
            const NavigationArea &area,
            const Vec2i &start,
            const CellSet &walkable_cells,
            PortalUse use,
            const DirectionalTraversalConstraints &constraints = {});
    };
} // namespace ffcore
