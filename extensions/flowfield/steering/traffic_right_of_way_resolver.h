#pragma once

#include "../core/types.h"
#include "agent.h"
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace ffcore
{
    class SpatialGrid;

    struct TrafficPushRequest
    {
        int target_agent_id = -1;
        Vec2 direction{};
        double force = 0.0;
    };

    class TrafficRightOfWayResolver
    {
    public:
        void update_cooldowns(double delta);
        void remove_agent(int agent_id);

        void collect_push_requests(
            const std::vector<AgentData> &agents,
            const std::unordered_map<int, int> &id_to_index,
            SpatialGrid *grid,
            const std::vector<std::uint8_t> &flow_waiting_by_agent_index,
            double max_world_radius,
            double base_push_force,
            std::vector<TrafficPushRequest> &out_requests);

        void mark_target_pushed(int agent_id, double cooldown_seconds);

    private:
        struct Candidate
        {
            TrafficPushRequest request{};
            int winner_priority = 0;
            std::int64_t winner_group_id = 0;
            double overlap = 0.0;
            int winner_agent_id = -1;
        };

        std::unordered_map<int, double> cooldown_by_target_agent;

        bool is_better_candidate(const Candidate &candidate, const Candidate &existing) const;
    };
} // namespace ffcore
