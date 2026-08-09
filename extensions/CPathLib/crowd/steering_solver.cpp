#include "steering_solver.h"

#include <algorithm>
#include <cstddef>
#include <vector>

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

    double SteeringSolver::movement_priority(const CrowdAgentState &agent)
    {
        Vec2 intent = agent.desired_direction.normalized();
        if (intent.is_zero())
            intent = agent.velocity.normalized();
        const Vec2 heading = agent.velocity.normalized();
        if (intent.is_zero() || heading.is_zero())
            return 0.0;
        return std::clamp(heading.dot(intent), 0.0, 1.0);
    }

    Vec2 SteeringSolver::separation(
        const CrowdAgentState &agent,
        const AgentWorld &agents,
        const SpatialGrid &spatial,
        const std::unordered_map<int, AgentHandle> &handles_by_index,
        const SeparationSettings &settings)
    {
        if (agent.profile.separation_radius <= 0.0 || agent.profile.separation_weight <= 0.0)
            return {};
        // separation_radius only decides who is considered. The push itself ramps over
        // the two radii actually touching, so agent size drives the response.
        const std::vector<int> neighbors = spatial.query_neighbors(
            agent.position,
            agent.profile.radius + std::max(
                agent.profile.separation_radius, settings.maximum_agent_radius));

        struct Candidate
        {
            const CrowdAgentState *other;
            double distance;
            double contact_distance;
        };
        std::vector<Candidate> candidates;
        candidates.reserve(neighbors.size());
        for (int index : neighbors)
        {
            const auto handle = handles_by_index.find(index);
            if (handle == handles_by_index.end() || handle->second == agent.handle)
                continue;
            const CrowdAgentState *other = agents.get(handle->second);
            if (other == nullptr)
                continue;
            const double distance = (agent.position - other->position).length();
            if (distance > agent.profile.separation_radius)
                continue;
            const double contact_distance = agent.profile.radius + other->profile.radius;
            if (contact_distance <= 0.0 || distance <= 1e-8 || distance >= contact_distance)
                continue;
            candidates.push_back({other, distance, contact_distance});
        }
        if (candidates.empty())
            return {};

        if (settings.maximum_neighbors > 0 &&
            candidates.size() > static_cast<std::size_t>(settings.maximum_neighbors))
        {
            std::partial_sort(
                candidates.begin(),
                candidates.begin() + settings.maximum_neighbors,
                candidates.end(),
                [](const Candidate &first, const Candidate &second)
                { return first.distance < second.distance; });
            candidates.resize(static_cast<std::size_t>(settings.maximum_neighbors));
        }

        const double self_priority = movement_priority(agent);
        const double priority_bias = std::clamp(settings.priority_bias, 0.0, 1.0);
        Vec2 contribution;
        double yield_sum = 0.0;
        for (const Candidate &candidate : candidates)
        {
            const double overlap = std::max(
                0.0, 1.0 - candidate.distance / candidate.contact_distance);
            const double falloff = overlap * overlap;
            const double pressure = std::max(
                0.0, candidate.other->profile.avoidance_push_strength) /
                std::max(0.001, agent.profile.avoidance_resistance);
            const double yield_multiplier = std::clamp(
                1.0 - (self_priority - movement_priority(*candidate.other)) * priority_bias,
                0.65, 1.35);
            const Vec2 away = (agent.position - candidate.other->position) *
                (1.0 / candidate.distance);
            contribution += away * (falloff * pressure * yield_multiplier);
            yield_sum += yield_multiplier;
        }
        if (contribution.is_zero())
            return {};
        const double yield_scale = std::clamp(
            yield_sum / static_cast<double>(candidates.size()), 0.65, 1.35);
        return contribution.normalized() *
            (agent.profile.separation_weight * yield_scale);
    }
} // namespace ffcore
