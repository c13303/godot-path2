#pragma once
#include <vector>
#include <unordered_map>
#include "../core/types.h"
#include "../core/nav_types.h"
#include "agent_group.h"
#include "../core/nav_config.h"


namespace ffcore
{
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
        AgentGroup *get_group(GroupID id);
        int create_agent(const Vec2 &pos, GroupID group);
        void remove_agent(int id);
        AgentEntry *get(int id);
        const AgentEntry *get(int id) const;

        void set_group_flow(GroupID group, FlowFieldID flow);
        FlowFieldID get_group_flow(GroupID group) const;

    private:
        std::vector<AgentEntry> agents;
        std::unordered_map<int, int> id_to_index;
        int next_id = 1;
        AgentGroup groups[MAX_GROUPS];
    };

    AgentManager *get_global_agent_manager();

}
