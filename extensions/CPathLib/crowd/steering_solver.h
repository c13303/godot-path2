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

    struct SeparationSettings
    {
        /// Only the N closest neighbours push. 0 considers every neighbour, which
        /// makes the cost of a dense pack grow with its depth.
        int maximum_neighbors = 0;
        /// How strongly an agent yields to neighbours that are making better
        /// progress toward their own goal. 0 disables the bias.
        double priority_bias = 0.0;
        /// Largest radius in the world, used to size the neighbour query so a big
        /// agent is never missed by a small one.
        double maximum_agent_radius = 0.0;
    };

    class SteeringSolver
    {
    public:
        static Vec2 navigation_direction(CrowdAgentState &agent, const FlowField *flow);
        /// Unit-direction push away from crowding neighbours, scaled to exactly
        /// `separation_weight`. The magnitude is deliberately independent of how many
        /// neighbours are pressing so crowd depth cannot overwhelm the other steering
        /// inputs; only the direction reflects the crowd. Neighbours push from
        /// `separation_radius` inward, ramping quadratically to full strength.
        static Vec2 separation(
            const CrowdAgentState &agent,
            const AgentWorld &agents,
            const SpatialGrid &spatial,
            const std::unordered_map<int, AgentHandle> &handles_by_index,
            const SeparationSettings &settings);

    private:
        /// 0..1 measure of how well an agent's motion matches what it wanted, used to
        /// let agents that are already progressing hold their line.
        static double movement_priority(const CrowdAgentState &agent);
    };
} // namespace ffcore
