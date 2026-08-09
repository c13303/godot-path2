#pragma once

#include "../core/types.h"
#include "../flow/flow_field_store.h"
#include "../steering/external_velocity_accumulator.h"
#include "../steering/directional_motion_field_store.h"
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
        Manual,
        DirectionalField
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
        /// Last frame's steering direction. Read by separation to tell which agents are
        /// already making progress; written at the end of each update.
        Vec2 desired_direction;
        NavigationSource navigation_source = NavigationSource::None;
        FlowHandle flow_handle;
        DirectionalMotionFieldHandle directional_field_handle;
        RouteProgress route_progress = RouteProgress::Idle;
        std::vector<Vec2> path;
        std::size_t path_index = 0;
        bool paused = false;
        bool allow_impulses_while_paused = false;
        bool navigation_suspended = false;
        bool forces_enabled = true;
        bool continue_at_flow_goal = false;
        double flow_goal_timer = 0.0;
        double zero_flow_retry_remaining = 0.0;
        bool zero_flow_retry_started = false;
        double blocked_motion_seconds = 0.0;
        int completed_bottleneck = -1;
        bool bottleneck_waiting = false;
        std::int64_t traffic_group_token = 0;
        int traffic_priority = 0;
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
        std::uint32_t generation_at(std::uint32_t index) const;
        std::size_t size() const;
    };
} // namespace ffcore
