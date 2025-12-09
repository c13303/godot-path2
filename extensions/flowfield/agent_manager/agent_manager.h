#pragma once
#include <vector>
#include <unordered_map>
#include "../core/types.h"
#include "../core/nav_config.h"
namespace ffcore
{
    class FlowField;
}
namespace ffcore
{
    struct AgentGroup
    {
        GroupID id = INVALID_GROUP;
        bool active = false;
        FlowField *flow = nullptr;
        bool has_order = false;
    };

    struct AgentEntry
    {
        int id = -1;
        GroupID group = INVALID_GROUP;
        Vec2 position;
    };

    struct AgentClaimDebug
    {
        int id = -1;
        Vec2 pos;
        Vec2i claimed_tile;
        bool moving = false;
    };

    class AgentManager
    {
    public:
        AgentManager();
        GroupID create_group();
        void add_agent_to_group(int agent_id, GroupID group);
        void remove_agent(int id);
        AgentEntry *get(int id);
        const AgentEntry *get(int id) const;
        FlowField *get_group_flow(GroupID group) const;
        void set_group_flow(GroupID group, FlowField *flow);
        void create_agent_entry(int agent_id, const Vec2 &pos, GroupID group);
        static const GroupID GROUP_IDLE = 0;
        void dissolve_group(GroupID group);
        ffcore::AgentGroup *get_groups() { return groups; }
        const ffcore::AgentGroup *get_groups() const { return groups; }
        bool is_group_active(GroupID g) const;
        bool all_agents_inactive(GroupID g) const;
        void mark_group_finished(GroupID g);
        void mark_group_has_order(GroupID g);
        int count_group_members(GroupID g) const;
        void distribute_tiles_to_agents(GroupID g, const std::vector<Vec2i> &tiles);
        void get_claimed_tiles(GroupID g, std::vector<Vec2i> &out) const;
        void get_group_claim_debug(GroupID g, std::vector<AgentClaimDebug> &out) const;

    private:
        std::vector<AgentEntry> agents;
        std::unordered_map<int, int> id_to_index;
        AgentGroup groups[MAX_GROUPS];
    };

    AgentManager *get_global_agent_manager();
}
