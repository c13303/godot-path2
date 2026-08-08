#include "navigation_area.h"

#include <algorithm>

namespace ffcore
{
    AreaHandle NavigationAreaStore::create_area(
        const std::vector<Vec2i> &interior_cells,
        const std::vector<Vec2i> &target_cells)
    {
        if (interior_cells.empty())
            return {};
        std::uint32_t index = 1;
        while (index < areas.size() && areas[index].occupied)
            ++index;
        if (index == areas.size())
            areas.push_back({});
        AreaSlot &slot = areas[index];
        slot.occupied = true;
        slot.value = NavigationArea();
        slot.value.id = {index, slot.generation};
        slot.value.interior_cells = interior_cells;
        slot.value.target_cells = target_cells;
        slot.value.revision = 1;
        return slot.value.id;
    }

    bool NavigationAreaStore::remove_area(AreaHandle handle)
    {
        AreaSlot *slot = handle.index < areas.size() ? &areas[handle.index] : nullptr;
        if (slot == nullptr || !slot->occupied || slot->generation != handle.generation)
            return false;
        const std::vector<PortalHandle> owned_portals = slot->value.portals;
        for (PortalHandle portal : owned_portals)
            remove_portal(portal);
        slot->occupied = false;
        slot->value = NavigationArea();
        ++slot->generation;
        return true;
    }

    const NavigationArea *NavigationAreaStore::get_area(AreaHandle handle) const
    {
        if (handle.index >= areas.size())
            return nullptr;
        const AreaSlot &slot = areas[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.value : nullptr;
    }

    PortalHandle NavigationAreaStore::create_portal(
        AreaHandle area,
        const std::vector<Vec2i> &boundary_cells,
        const std::vector<Vec2i> &outside_cells,
        PortalDirection direction,
        std::uint32_t capacity)
    {
        if (get_area(area) == nullptr || boundary_cells.empty() || outside_cells.empty())
            return {};
        std::uint32_t index = 1;
        while (index < portals.size() && portals[index].occupied)
            ++index;
        if (index == portals.size())
            portals.push_back({});
        PortalSlot &slot = portals[index];
        slot.occupied = true;
        slot.value = AreaPortal();
        slot.value.id = {index, slot.generation};
        slot.value.area = area;
        slot.value.boundary_cells = boundary_cells;
        slot.value.outside_cells = outside_cells;
        slot.value.direction = direction;
        slot.value.capacity = std::max<std::uint32_t>(1, capacity);
        AreaSlot &area_slot = areas[area.index];
        area_slot.value.portals.push_back(slot.value.id);
        ++area_slot.value.revision;
        return slot.value.id;
    }

    bool NavigationAreaStore::remove_portal(PortalHandle handle)
    {
        PortalSlot *slot = handle.index < portals.size() ? &portals[handle.index] : nullptr;
        if (slot == nullptr || !slot->occupied || slot->generation != handle.generation)
            return false;
        if (slot->value.area.index < areas.size())
        {
            AreaSlot &area_slot = areas[slot->value.area.index];
            if (area_slot.occupied && area_slot.generation == slot->value.area.generation)
            {
                auto &owned = area_slot.value.portals;
                owned.erase(std::remove(owned.begin(), owned.end(), handle), owned.end());
                ++area_slot.value.revision;
            }
        }
        slot->occupied = false;
        slot->value = AreaPortal();
        ++slot->generation;
        return true;
    }

    const AreaPortal *NavigationAreaStore::get_portal(PortalHandle handle) const
    {
        if (handle.index >= portals.size())
            return nullptr;
        const PortalSlot &slot = portals[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.value : nullptr;
    }
} // namespace ffcore
