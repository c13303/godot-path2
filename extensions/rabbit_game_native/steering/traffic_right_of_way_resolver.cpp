#include "traffic_right_of_way_resolver.h"

#include "CPathLib/grid/spatial_grid.h"
#include <algorithm>
#include <cmath>

namespace
{
    static constexpr double FRONT_CONTACT_MIN_DOT = -0.10;

    inline ffcore::Vec2 agent_foot_point(const ffcore::AgentData &agent)
    {
        return agent.position + ffcore::Vec2(0, agent.profile.foot_offset_y);
    }

    inline ffcore::Vec2 safe_normalize(const ffcore::Vec2 &v)
    {
        if (!std::isfinite(v.x) || !std::isfinite(v.y))
            return ffcore::Vec2(0, 0);
        double length = v.length();
        if (!std::isfinite(length) || length < 1e-6)
            return ffcore::Vec2(0, 0);
        return v * (1.0 / length);
    }

    inline ffcore::Vec2 deterministic_pair_dir(int a, int b)
    {
        unsigned h = static_cast<unsigned>(a) * 1664525u
            ^ static_cast<unsigned>(b) * 1013904223u;
        double angle = (h & 0xFFFFu) / 65535.0 * 6.28318530718;
        return ffcore::Vec2(std::cos(angle), std::sin(angle));
    }

    inline ffcore::Vec2 navigation_intent(const ffcore::AgentData &agent)
    {
        ffcore::Vec2 intent = safe_normalize(agent.debug_desired_dir);
        if (intent.is_zero())
            intent = safe_normalize(agent.debug_nav_dir);
        if (intent.is_zero())
            intent = safe_normalize(agent.velocity);
        return intent;
    }

    inline bool traffic_eligible_base(const ffcore::AgentData &agent)
    {
        return agent.active
            && !agent.paused
            && agent.phase != ffcore::AgentPhase::Drowning
            && !agent.is_propelled
            && !agent.smash_pending
            && agent.profile.world_radius > 0.0
            && agent.traffic_group_id > 0
            && agent.traffic_priority > 0;
    }

    inline const ffcore::AgentData *winner_for_pair(
        const ffcore::AgentData &a,
        const ffcore::AgentData &b)
    {
        if (a.traffic_group_id == b.traffic_group_id)
            return nullptr;
        if (a.traffic_priority != b.traffic_priority)
            return a.traffic_priority > b.traffic_priority ? &a : &b;
        if (a.traffic_group_id != b.traffic_group_id)
            return a.traffic_group_id < b.traffic_group_id ? &a : &b;
        return nullptr;
    }
}

namespace ffcore
{
void TrafficRightOfWayResolver::update_cooldowns(double delta)
{
    if (cooldown_by_target_agent.empty())
        return;

    for (auto it = cooldown_by_target_agent.begin(); it != cooldown_by_target_agent.end();)
    {
        it->second -= delta;
        if (it->second <= 0.0)
            it = cooldown_by_target_agent.erase(it);
        else
            ++it;
    }
}

void TrafficRightOfWayResolver::remove_agent(int agent_id)
{
    cooldown_by_target_agent.erase(agent_id);
}

bool TrafficRightOfWayResolver::is_better_candidate(const Candidate &candidate, const Candidate &existing) const
{
    if (candidate.winner_priority != existing.winner_priority)
        return candidate.winner_priority > existing.winner_priority;
    if (candidate.winner_group_id != existing.winner_group_id)
        return candidate.winner_group_id < existing.winner_group_id;
    if (std::abs(candidate.overlap - existing.overlap) > 1e-6)
        return candidate.overlap > existing.overlap;
    return candidate.winner_agent_id < existing.winner_agent_id;
}

void TrafficRightOfWayResolver::collect_push_requests(
    const std::vector<AgentData> &agents,
    const std::unordered_map<int, int> &id_to_index,
    SpatialGrid *grid,
    const std::vector<std::uint8_t> &flow_waiting_by_agent_index,
    double max_world_radius,
    double base_push_force,
    std::vector<TrafficPushRequest> &out_requests)
{
    out_requests.clear();
    if (!grid || base_push_force <= 0.0)
        return;

    std::unordered_map<int, Candidate> best_by_target;

    for (int i = 0; i < static_cast<int>(agents.size()); ++i)
    {
        const AgentData &agent = agents[i];
        if (!traffic_eligible_base(agent))
            continue;
        if (i < static_cast<int>(flow_waiting_by_agent_index.size()) && flow_waiting_by_agent_index[i] != 0)
            continue;

        const Vec2 agent_foot = agent_foot_point(agent);
        std::vector<int> neighbor_ids = grid->query_neighbors(agent_foot, agent.profile.world_radius + max_world_radius);
        for (int neighbor_id : neighbor_ids)
        {
            if (agent.id >= neighbor_id)
                continue;

            auto neighbor_it = id_to_index.find(neighbor_id);
            if (neighbor_it == id_to_index.end())
                continue;

            const int neighbor_index = neighbor_it->second;
            const AgentData &neighbor = agents[neighbor_index];
            if (!traffic_eligible_base(neighbor))
                continue;
            if (neighbor_index < static_cast<int>(flow_waiting_by_agent_index.size()) && flow_waiting_by_agent_index[neighbor_index] != 0)
                continue;

            const AgentData *winner = winner_for_pair(agent, neighbor);
            if (!winner)
                continue;
            const AgentData *loser = winner->id == agent.id ? &neighbor : &agent;
            if (cooldown_by_target_agent.find(loser->id) != cooldown_by_target_agent.end())
                continue;
            if (!winner->flow && !winner->path_active)
                continue;

            Vec2 winner_intent = navigation_intent(*winner);
            if (winner_intent.is_zero())
                continue;

            const Vec2 winner_foot = agent_foot_point(*winner);
            const Vec2 loser_foot = agent_foot_point(*loser);
            Vec2 winner_to_loser = loser_foot - winner_foot;
            double distance = winner_to_loser.length();
            Vec2 push_dir = distance > 1e-6
                ? winner_to_loser * (1.0 / distance)
                : deterministic_pair_dir(winner->id, loser->id);
            if (winner_intent.dot(push_dir) < FRONT_CONTACT_MIN_DOT)
                continue;

            double sum_radius = winner->profile.world_radius + loser->profile.world_radius;
            if (sum_radius <= 0.0)
                continue;
            double overlap = sum_radius - distance;
            if (overlap <= 0.0)
                continue;

            double overlap_ratio = std::clamp(overlap / sum_radius, 0.0, 1.0);
            double force_scale = 0.5 + 0.5 * overlap_ratio;

            Candidate candidate;
            candidate.request.target_agent_id = loser->id;
            candidate.request.direction = push_dir;
            candidate.request.force = base_push_force * force_scale;
            candidate.winner_priority = winner->traffic_priority;
            candidate.winner_group_id = winner->traffic_group_id;
            candidate.overlap = overlap;
            candidate.winner_agent_id = winner->id;

            auto existing = best_by_target.find(loser->id);
            if (existing == best_by_target.end() || is_better_candidate(candidate, existing->second))
                best_by_target[loser->id] = candidate;
        }
    }

    out_requests.reserve(best_by_target.size());
    for (const auto &entry : best_by_target)
        out_requests.push_back(entry.second.request);

    std::sort(out_requests.begin(), out_requests.end(),
        [](const TrafficPushRequest &a, const TrafficPushRequest &b) {
            return a.target_agent_id < b.target_agent_id;
        });
}

void TrafficRightOfWayResolver::mark_target_pushed(int agent_id, double cooldown_seconds)
{
    if (agent_id < 0 || cooldown_seconds <= 0.0)
        return;
    cooldown_by_target_agent[agent_id] = cooldown_seconds;
}
} // namespace ffcore
