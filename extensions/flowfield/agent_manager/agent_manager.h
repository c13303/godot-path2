#pragma once
#include <vector>
#include <unordered_map>
#include "../core/types.h"
#include "../core/nav_config.h"

namespace ffcore
{
    struct AgentGroup
    {
        GroupID id = INVALID_GROUP;
        bool active = false;
        FlowFieldID flow_id = INVALID_FLOWFIELD;
    };

    struct AgentEntry
    {
        int id = -1;
        GroupID group = INVALID_GROUP;
        Vec2 position;
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
        FlowFieldID get_group_flow(GroupID group) const;
        void set_group_flow(GroupID group, FlowFieldID fid);
        void create_agent_entry(int agent_id, const Vec2 &pos, GroupID group);

    private:
        std::vector<AgentEntry> agents;
        std::unordered_map<int, int> id_to_index;
        AgentGroup groups[MAX_GROUPS];
    };

    AgentManager *get_global_agent_manager();
}
