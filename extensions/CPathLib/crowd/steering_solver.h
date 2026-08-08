#pragma once

#include "agent_world.h"
#include "../flow/flow_field.h"
#include "../grid/spatial_grid.h"

#include <unordered_map>

namespace ffcore
{
    struct SteeringResult
    {
        Vec2 desired_direction;
        Vec2 separation;
    };

    class SteeringSolver
    {
    public:
        static Vec2 navigation_direction(CrowdAgentState &agent, const FlowField *flow);
        static Vec2 separation(
            const CrowdAgentState &agent,
            const AgentWorld &agents,
            const SpatialGrid &spatial,
            const std::unordered_map<int, AgentHandle> &handles_by_index);
    };
} // namespace ffcore
