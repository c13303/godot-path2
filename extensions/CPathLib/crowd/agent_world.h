#pragma once

#include "../core/types.h"
#include "../flow/flow_field_store.h"
#include "../steering/external_velocity_accumulator.h"
#include "crowd_profile_store.h"

#include <cstdint>
#include <vector>

namespace ffcore
{
    struct AgentHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;
        bool is_valid() const { return index != 0; }
        bool operator==(const AgentHandle &other) const
        { return index == other.index && generation == other.generation; }
    };

    enum class NavigationSource
    {
        None,
        FlowField,
        Path,
        Manual
    };

    enum class RouteProgress
    {
        Idle,
        Following,
        Arrived,
        Failed
    };

    struct CrowdAgentState
    {
        AgentHandle handle;
        ProfileHandle profile_handle;
        CrowdAgentProfile profile;
        Vec2 position;
        Vec2 velocity;
        Vec2 manual_direction;
        NavigationSource navigation_source = NavigationSource::None;
        FlowHandle flow_handle;
        RouteProgress route_progress = RouteProgress::Idle;
        std::vector<Vec2> path;
        std::size_t path_index = 0;
        bool paused = false;
        ExternalVelocityAccumulator external_velocity;
    };

    class AgentWorld
    {
    private:
        struct Slot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
            CrowdAgentState state;
        };

        std::vector<Slot> slots = std::vector<Slot>(1);

    public:
        AgentHandle create(const Vec2 &position, const CrowdAgentProfile &profile = {});
        bool remove(AgentHandle handle);
        CrowdAgentState *get(AgentHandle handle);
        const CrowdAgentState *get(AgentHandle handle) const;
        std::vector<AgentHandle> active_handles() const;
        std::size_t size() const;
    };
} // namespace ffcore
