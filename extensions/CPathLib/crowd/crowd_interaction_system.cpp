#include "crowd_interaction_system.h"

#include <algorithm>
#include <cmath>
#include <iterator>

namespace ffcore
{
    std::uint64_t CrowdInteractionSystem::key(AgentHandle handle)
    {
        return (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index;
    }

    Vec2 CrowdInteractionSystem::pair_direction(
        AgentHandle first, AgentHandle second, const Vec2 &difference)
    {
        if (!difference.is_zero())
            return difference.normalized();
        const std::uint32_t hash = first.index * 1664525u ^ second.index * 1013904223u;
        const double angle = static_cast<double>(hash & 0xffffu) / 65535.0 *
            6.283185307179586;
        return {std::cos(angle), std::sin(angle)};
    }

    void CrowdInteractionSystem::update_cooldowns(double delta)
    {
        for (auto outer = contact_cooldowns.begin(); outer != contact_cooldowns.end();)
        {
            for (auto inner = outer->second.begin(); inner != outer->second.end();)
            {
                inner->second -= delta;
                inner = inner->second <= 0.0 ? outer->second.erase(inner) : std::next(inner);
            }
            outer = outer->second.empty() ? contact_cooldowns.erase(outer) : std::next(outer);
        }
        for (auto iterator = right_of_way_cooldowns.begin();
             iterator != right_of_way_cooldowns.end();)
        {
            iterator->second -= delta;
            iterator = iterator->second <= 0.0
                ? right_of_way_cooldowns.erase(iterator) : std::next(iterator);
        }
    }

    std::vector<CrowdInteractionImpulse> CrowdInteractionSystem::collect(
        double delta, const AgentWorld &agents, const SpatialGrid &spatial,
        const CrowdInteractionConfig &config)
    {
        std::vector<CrowdInteractionImpulse> result;
        if (!std::isfinite(delta) || delta <= 0.0)
            return result;
        update_cooldowns(delta);
        const std::vector<AgentHandle> handles = agents.active_handles();
        double maximum_radius = 0.0;
        for (AgentHandle handle : handles)
        {
            const CrowdAgentState *agent = agents.get(handle);
            if (agent != nullptr)
                maximum_radius = std::max(maximum_radius, agent->profile.radius);
        }
        for (AgentHandle first_handle : handles)
        {
            const CrowdAgentState *first = agents.get(first_handle);
            if (first == nullptr || first->paused)
                continue;
            const double query_radius = first->profile.radius + maximum_radius;
            for (int neighbor_index : spatial.query_neighbors(first->position, query_radius))
            {
                if (neighbor_index <= static_cast<int>(first_handle.index))
                    continue;
                const AgentHandle second_handle = {
                    static_cast<std::uint32_t>(neighbor_index),
                    agents.generation_at(static_cast<std::uint32_t>(neighbor_index))};
                const CrowdAgentState *second = agents.get(second_handle);
                if (second == nullptr || second->paused)
                    continue;
                const double combined_radius = first->profile.radius + second->profile.radius;
                const Vec2 difference = second->position - first->position;
                const double distance = difference.length();
                if (combined_radius <= 0.0 || distance > combined_radius)
                    continue;
                const Vec2 direction = pair_direction(first_handle, second_handle, difference);

                const std::uint64_t first_key = key(first_handle);
                const std::uint64_t second_key = key(second_handle);
                const bool contact_cooling = contact_cooldowns[first_key].find(second_key) !=
                    contact_cooldowns[first_key].end();
                if (config.contact_push_enabled && !contact_cooling)
                {
                    const double first_pressure = first->profile.contact_push_strength /
                        std::max(0.001, second->profile.contact_push_resistance);
                    const double second_pressure = second->profile.contact_push_strength /
                        std::max(0.001, first->profile.contact_push_resistance);
                    const double net = first_pressure - second_pressure;
                    if (std::abs(net) >= 0.001)
                    {
                        const bool push_second = net > 0.0;
                        const CrowdAgentState *target = push_second ? second : first;
                        ImpulseRequest impulse;
                        impulse.velocity = (push_second ? direction : -direction) * std::abs(net);
                        impulse.decay_per_second = target->profile.contact_impulse_decay;
                        impulse.control_suppression_seconds =
                            target->profile.contact_control_suppression;
                        impulse.priority = config.contact_impulse_priority;
                        result.push_back({push_second ? second_handle : first_handle, impulse});
                        const double cooldown = std::max(
                            first->profile.contact_push_cooldown,
                            second->profile.contact_push_cooldown);
                        contact_cooldowns[first_key][second_key] = cooldown;
                        contact_cooldowns[second_key][first_key] = cooldown;
                    }
                }

                if (!config.right_of_way_enabled ||
                    first->traffic_group_token == 0 || second->traffic_group_token == 0 ||
                    first->traffic_group_token == second->traffic_group_token ||
                    first->traffic_priority == second->traffic_priority)
                    continue;
                const bool first_wins = first->traffic_priority > second->traffic_priority;
                const CrowdAgentState *winner = first_wins ? first : second;
                const AgentHandle loser_handle = first_wins ? second_handle : first_handle;
                if (right_of_way_cooldowns.find(key(loser_handle)) !=
                    right_of_way_cooldowns.end())
                    continue;
                Vec2 intent = winner->velocity.normalized();
                if (winner->navigation_source == NavigationSource::Manual)
                    intent = winner->manual_direction.normalized();
                const Vec2 winner_to_loser = first_wins ? direction : -direction;
                if (intent.is_zero() || intent.dot(winner_to_loser) < -0.10)
                    continue;
                const double overlap_ratio = std::clamp(
                    (combined_radius - distance) / combined_radius, 0.0, 1.0);
                ImpulseRequest impulse;
                impulse.velocity = winner_to_loser *
                    (config.right_of_way_push_speed * (0.5 + 0.5 * overlap_ratio));
                impulse.decay_per_second = 0.65;
                impulse.control_suppression_seconds =
                    config.right_of_way_control_suppression;
                impulse.priority = config.right_of_way_impulse_priority;
                result.push_back({loser_handle, impulse});
                right_of_way_cooldowns[key(loser_handle)] = config.right_of_way_cooldown;
            }
        }
        return result;
    }

    void CrowdInteractionSystem::remove_agent(AgentHandle handle)
    {
        const std::uint64_t handle_key = key(handle);
        contact_cooldowns.erase(handle_key);
        right_of_way_cooldowns.erase(handle_key);
        for (auto &entry : contact_cooldowns)
            entry.second.erase(handle_key);
    }
} // namespace ffcore
