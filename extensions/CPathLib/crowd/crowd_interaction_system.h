#pragma once

#include "agent_world.h"
#include "impulse_system.h"
#include "../grid/spatial_grid.h"

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace ffcore
{
    struct CrowdInteractionConfig
    {
        bool contact_push_enabled = true;
        int contact_impulse_priority = 50;
        bool right_of_way_enabled = true;
        double right_of_way_push_speed = 216.0;
        double right_of_way_cooldown = 0.18;
        double right_of_way_control_suppression = 0.18;
        int right_of_way_impulse_priority = 10;
    };

    struct CrowdInteractionImpulse
    {
        AgentHandle agent;
        ImpulseRequest impulse;
    };

    class CrowdInteractionSystem
    {
    private:
        std::unordered_map<std::uint64_t,
            std::unordered_map<std::uint64_t, double>> contact_cooldowns;
        std::unordered_map<std::uint64_t, double> right_of_way_cooldowns;

        static std::uint64_t key(AgentHandle handle);
        static Vec2 pair_direction(AgentHandle first, AgentHandle second,
                                   const Vec2 &difference);
        void update_cooldowns(double delta);

    public:
        std::vector<CrowdInteractionImpulse> collect(
            double delta, const AgentWorld &agents, const SpatialGrid &spatial,
            const CrowdInteractionConfig &config);
        void remove_agent(AgentHandle handle);
    };
} // namespace ffcore
