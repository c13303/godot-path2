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
        int add_agent_to_group(const Vec2 &pos, GroupID group);
        void remove_agent(int id);
        AgentEntry *get(int id);
        const AgentEntry *get(int id) const;

        void set_group_flow(GroupID group, FlowFieldID flow);
        FlowFieldID get_group_flow(GroupID group) const;
        GroupID create_group_with_flow(const ffcore::Vec2 &goal_world_pos);

    private:
        std::vector<AgentEntry> agents;
        std::unordered_map<int, int> id_to_index;
        int next_id = 1;
        AgentGroup groups[MAX_GROUPS];
    };

    AgentManager *get_global_agent_manager();

}
