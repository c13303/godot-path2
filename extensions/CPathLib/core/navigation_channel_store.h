#pragma once

#include "../flow/flow_field_algorithms.h"

#include <cstdint>
#include <unordered_map>

namespace ffcore
{
    struct NavigationBlockerChannel
    {
        CellSet cells;
        bool blocks_navigation = true;
        bool blocks_physics = true;
    };

    class NavigationChannelStore
    {
    private:
        std::unordered_map<std::uint32_t, NavigationBlockerChannel> blocker_channels;
        std::unordered_map<int, DirectionalTraversalConstraints> directional_channels;

    public:
        bool replace_blocker_channel(std::uint32_t channel,
                                     const CellSet &cells,
                                     bool blocks_navigation,
                                     bool blocks_physics);
        bool clear_blocker_channel(std::uint32_t channel);
        bool set_blocker_cell(std::uint32_t channel, const Vec2i &cell, bool blocked,
                              bool blocks_navigation, bool blocks_physics);
        void apply_blockers(std::uint64_t channel_mask,
                            CellSet &walkable_cells,
                            CellSet &physical_wall_cells) const;
        std::size_t blocker_channel_count() const { return blocker_channels.size(); }

        bool replace_directional_channel(int channel,
                                         const DirectionalTraversalConstraints &constraints);
        bool clear_directional_channel(int channel);
        const DirectionalTraversalConstraints *get_directional_channel(int channel) const;
        std::size_t directional_channel_count() const { return directional_channels.size(); }
    };
} // namespace ffcore
