#include "steering_solver.h"

#include <algorithm>

namespace ffcore
{
    Vec2 SteeringSolver::navigation_direction(CrowdAgentState &agent, const FlowField *flow)
    {
        if (agent.paused)
            return {};
        if (agent.navigation_source == NavigationSource::Manual)
            return agent.manual_direction.normalized();
        if (agent.navigation_source == NavigationSource::FlowField)
            return flow == nullptr ? Vec2() : flow->compute_flow_dir(agent.position).normalized();
        if (agent.navigation_source != NavigationSource::Path)
            return {};

        while (agent.path_index < agent.path.size() &&
               agent.position.distance_to(agent.path[agent.path_index]) <= agent.profile.arrival_radius)
            ++agent.path_index;
        if (agent.path_index >= agent.path.size())
        {
            agent.route_progress = RouteProgress::Arrived;
            return {};
        }
        agent.route_progress = RouteProgress::Following;
        return (agent.path[agent.path_index] - agent.position).normalized();
    }

    Vec2 SteeringSolver::separation(
        const CrowdAgentState &agent,
        const AgentWorld &agents,
        const SpatialGrid &spatial,
        const std::unordered_map<int, AgentHandle> &handles_by_index)
    {
        Vec2 contribution;
        if (agent.profile.separation_radius <= 0.0 || agent.profile.separation_weight <= 0.0)
            return contribution;
        const std::vector<int> neighbors = spatial.query_neighbors(
            agent.position, agent.profile.separation_radius + agent.profile.radius);
        for (int index : neighbors)
        {
            const auto handle = handles_by_index.find(index);
            if (handle == handles_by_index.end() || handle->second == agent.handle)
                continue;
            const CrowdAgentState *other = agents.get(handle->second);
            if (other == nullptr)
                continue;
            const Vec2 away = agent.position - other->position;
            const double distance = away.length();
            const double desired_distance = std::max(
                agent.profile.separation_radius,
                agent.profile.radius + other->profile.radius);
            if (distance <= 1e-8 || distance >= desired_distance)
                continue;
            contribution += away * ((desired_distance - distance) / (desired_distance * distance));
        }
        return contribution * agent.profile.separation_weight;
    }
} // namespace ffcore
