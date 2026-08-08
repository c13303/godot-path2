#include "navigation_channel_store.h"

#include <utility>

namespace ffcore
{
    bool NavigationChannelStore::replace_blocker_channel(
        std::uint32_t channel,
        const CellSet &cells,
        bool blocks_navigation,
        bool blocks_physics)
    {
        const auto existing = blocker_channels.find(channel);
        if (existing != blocker_channels.end() &&
            existing->second.blocks_navigation == blocks_navigation &&
            existing->second.blocks_physics == blocks_physics &&
            existing->second.cells == cells)
            return false;
        blocker_channels[channel] = {cells, blocks_navigation, blocks_physics};
        return true;
    }

    bool NavigationChannelStore::clear_blocker_channel(std::uint32_t channel)
    {
        return blocker_channels.erase(channel) != 0;
    }

    bool NavigationChannelStore::set_blocker_cell(
        std::uint32_t channel,
        const Vec2i &cell,
        bool blocked,
        bool blocks_navigation,
        bool blocks_physics)
    {
        auto existing = blocker_channels.find(channel);
        if (existing == blocker_channels.end())
        {
            if (!blocked)
                return false;
            NavigationBlockerChannel created;
            created.blocks_navigation = blocks_navigation;
            created.blocks_physics = blocks_physics;
            created.cells.insert(cell);
            blocker_channels[channel] = std::move(created);
            return true;
        }
        NavigationBlockerChannel &entry = existing->second;
        const bool policy_changed = entry.blocks_navigation != blocks_navigation ||
                                    entry.blocks_physics != blocks_physics;
        entry.blocks_navigation = blocks_navigation;
        entry.blocks_physics = blocks_physics;
        const bool cell_changed = blocked ? entry.cells.insert(cell).second
                                          : entry.cells.erase(cell) != 0;
        return policy_changed || cell_changed;
    }

    void NavigationChannelStore::apply_blockers(
        std::uint64_t channel_mask,
        CellSet &walkable_cells,
        CellSet &physical_wall_cells) const
    {
        for (const auto &channel : blocker_channels)
        {
            if (channel.first >= 64 ||
                (channel_mask & (std::uint64_t(1) << channel.first)) == 0)
                continue;
            for (const Vec2i &cell : channel.second.cells)
            {
                if (channel.second.blocks_navigation)
                    walkable_cells.erase(cell);
                if (channel.second.blocks_physics)
                    physical_wall_cells.insert(cell);
            }
        }
    }

    bool NavigationChannelStore::replace_directional_channel(
        int channel,
        const DirectionalTraversalConstraints &constraints)
    {
        const auto existing = directional_channels.find(channel);
        if (existing != directional_channels.end() && existing->second == constraints)
            return false;
        directional_channels[channel] = constraints;
        return true;
    }

    bool NavigationChannelStore::clear_directional_channel(int channel)
    {
        return directional_channels.erase(channel) != 0;
    }

    const DirectionalTraversalConstraints *NavigationChannelStore::get_directional_channel(
        int channel) const
    {
        const auto existing = directional_channels.find(channel);
        return existing == directional_channels.end() ? nullptr : &existing->second;
    }
} // namespace ffcore
