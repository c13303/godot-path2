#pragma once

#include "../core/types.h"
#include "../steering/external_velocity_accumulator.h"

#include <cstdint>
#include <limits>
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

    struct CrowdAgentProfile
    {
        double radius = 8.0;
        double maximum_speed = 80.0;
        double acceleration = 400.0;
        double deceleration = 500.0;
        double separation_radius = 20.0;
        double separation_weight = 1.0;
        double arrival_radius = 4.0;
        int terrain_speed_channel = 0;
        std::uint32_t category_mask = std::numeric_limits<std::uint32_t>::max();
    };

    struct CrowdAgentState
    {
        AgentHandle handle;
        CrowdAgentProfile profile;
        Vec2 position;
        Vec2 velocity;
        Vec2 manual_direction;
        NavigationSource navigation_source = NavigationSource::None;
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
