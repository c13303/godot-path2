#pragma once

#include "../core/types.h"

#include <cstdint>
#include <vector>

namespace ffcore
{
    struct AreaHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;
        bool is_valid() const { return index != 0; }
        bool operator==(const AreaHandle &other) const
        { return index == other.index && generation == other.generation; }
    };

    struct PortalHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;
        bool is_valid() const { return index != 0; }
        bool operator==(const PortalHandle &other) const
        { return index == other.index && generation == other.generation; }
    };

    enum class PortalDirection
    {
        Both,
        EnterOnly,
        ExitOnly
    };

    struct NavigationArea
    {
        AreaHandle id;
        std::vector<Vec2i> interior_cells;
        std::vector<Vec2i> target_cells;
        std::vector<PortalHandle> portals;
        std::uint64_t revision = 0;
    };

    struct AreaPortal
    {
        PortalHandle id;
        AreaHandle area;
        std::vector<Vec2i> boundary_cells;
        std::vector<Vec2i> outside_cells;
        PortalDirection direction = PortalDirection::Both;
        std::uint32_t capacity = 1;
    };

    class NavigationAreaStore
    {
    private:
        struct AreaSlot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
            NavigationArea value;
        };
        struct PortalSlot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
            AreaPortal value;
        };

        std::vector<AreaSlot> areas = std::vector<AreaSlot>(1);
        std::vector<PortalSlot> portals = std::vector<PortalSlot>(1);

    public:
        AreaHandle create_area(const std::vector<Vec2i> &interior_cells,
                               const std::vector<Vec2i> &target_cells = {});
        bool remove_area(AreaHandle handle);
        const NavigationArea *get_area(AreaHandle handle) const;

        PortalHandle create_portal(AreaHandle area,
                                   const std::vector<Vec2i> &boundary_cells,
                                   const std::vector<Vec2i> &outside_cells,
                                   PortalDirection direction = PortalDirection::Both,
                                   std::uint32_t capacity = 1);
        bool remove_portal(PortalHandle handle);
        const AreaPortal *get_portal(PortalHandle handle) const;
    };
} // namespace ffcore
