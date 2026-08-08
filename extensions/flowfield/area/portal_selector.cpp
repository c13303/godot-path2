#include "portal_selector.h"

#include <cmath>

namespace ffcore
{
    PortalSelectionResult PortalSelector::select(
        const NavigationAreaStore &store,
        const NavigationArea &area,
        const Vec2i &start,
        const CellSet &walkable_cells,
        PortalUse use,
        const DirectionalTraversalConstraints &constraints)
    {
        PortalSelectionResult best;
        constexpr double COST_EPSILON = 1e-9;
        for (PortalHandle handle : area.portals)
        {
            const AreaPortal *portal = store.get_portal(handle);
            if (portal == nullptr)
                continue;
            if (use == PortalUse::Enter && portal->direction == PortalDirection::ExitOnly)
                continue;
            if (use == PortalUse::Exit && portal->direction == PortalDirection::EnterOnly)
                continue;

            const std::vector<Vec2i> &approaches =
                use == PortalUse::Enter ? portal->outside_cells : portal->boundary_cells;
            for (const Vec2i &approach : approaches)
            {
                const IntegrationCosts costs = FlowFieldAlgorithms::compute_integration_costs(
                    walkable_cells, approach, &constraints);
                const auto start_cost = costs.find(start);
                if (start_cost == costs.end() || !std::isfinite(start_cost->second))
                    continue;
                const bool lower_cost = start_cost->second + COST_EPSILON < best.route_cost;
                const bool stable_tie = std::abs(start_cost->second - best.route_cost) <= COST_EPSILON &&
                                        (!best.portal.is_valid() || handle.index < best.portal.index);
                if (lower_cost || stable_tie)
                {
                    best.portal = handle;
                    best.approach_cell = approach;
                    best.route_cost = start_cost->second;
                    best.found = true;
                }
            }
        }
        return best;
    }
} // namespace ffcore
