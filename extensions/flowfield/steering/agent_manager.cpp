#include "agent_manager.h"
#include "../core/nav_config.h"
#include <godot_cpp/variant/utility_functions.hpp>

namespace ffcore
{
    static AgentManager *g_agent_manager = nullptr;

    AgentManager::AgentManager()
    {
        g_agent_manager = this;

        for (GroupID i = 1; i < MAX_GROUPS; i++)
        {
            groups[i].id = i;
            groups[i].active = false;
            groups[i].flow_id = INVALID_FLOWFIELD;
        }
    }

    AgentManager *get_global_agent_manager()
    {
        return g_agent_manager;
    }

    GroupID AgentManager::create_group()
    {
        for (GroupID i = 1; i < MAX_GROUPS; i++)
        {
            if (!groups[i].active)
            {
                groups[i].active = true;
                groups[i].flow_id = INVALID_FLOWFIELD;
                return i;
            }
        }
        return INVALID_GROUP;
    }

    AgentGroup *AgentManager::get_group(GroupID id)
    {
        if (id == INVALID_GROUP || id >= MAX_GROUPS)
            return nullptr;
        return &groups[id];
    }

    int AgentManager::create_agent(const Vec2 &pos, GroupID group)
    {
        int id = next_id++;

        AgentEntry e;
        e.id = id;
        e.group = group;
        e.position = pos;

        id_to_index[id] = agents.size();
        agents.push_back(e);

        return id;
    }

    void AgentManager::remove_agent(int id)
    {
        auto it = id_to_index.find(id);
        if (it == id_to_index.end())
            return;

        int idx = it->second;
        int last = agents.size() - 1;

        if (idx != last)
        {
            agents[idx] = agents[last];
            id_to_index[agents[idx].id] = idx;
        }

        agents.pop_back();
        id_to_index.erase(it);
    }

    AgentEntry *AgentManager::get(int id)
    {
        auto it = id_to_index.find(id);
        if (it == id_to_index.end())
            return nullptr;
        return &agents[it->second];
    }

    const AgentEntry *AgentManager::get(int id) const
    {
        auto it = id_to_index.find(id);
        if (it == id_to_index.end())
            return nullptr;
        return &agents[it->second];
    }

    void AgentManager::set_group_flow(GroupID group, FlowFieldID flow)
    {
        if (group == INVALID_GROUP || group >= MAX_GROUPS)
            return;
        groups[group].flow_id = flow;
    }

    FlowFieldID AgentManager::get_group_flow(GroupID group) const
    {
        if (group == INVALID_GROUP || group >= MAX_GROUPS)
            return INVALID_FLOWFIELD;
        return groups[group].flow_id;
    }

}
