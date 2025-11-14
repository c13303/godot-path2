#include "agent_manager.h"
#include "../core/nav_config.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include "../flow/flow_field_manager.h"
#include "../steering/steering_system.h"
#include "../godot/flow_field_native.h"
#include "../core/types.h"
#include "../core/nav_services.h"
#include <cstdlib>

namespace ffcore
{
    static AgentManager *g_agent_manager = nullptr;
    static AgentManager GLOBAL_INSTANCE;

    AgentManager::AgentManager()
    {
        g_agent_manager = this;

        for (GroupID i = 1; i < MAX_GROUPS; i++)
        {
            groups[i].id = i;
            groups[i].active = false;
            groups[i].flow_id = INVALID_FLOWFIELD;
            groups[i].has_order = false;
        }

        groups[GROUP_IDLE].id = GROUP_IDLE;
        groups[GROUP_IDLE].active = true; // ← empêche create_group() de l’utiliser
        groups[GROUP_IDLE].flow_id = INVALID_FLOWFIELD;
        groups[GROUP_IDLE].has_order = false;
    }

    AgentManager *get_global_agent_manager()
    {
        return g_agent_manager;
    }

    void AgentManager::create_agent_entry(int agent_id, const Vec2 &pos, GroupID group)
    {
        AgentEntry e;
        e.id = agent_id;
        e.group = group;
        e.position = pos;

        id_to_index[agent_id] = agents.size();
        agents.push_back(e);
    }

    GroupID AgentManager::create_group()
    {
        for (GroupID i = 1; i < MAX_GROUPS; i++)
        {
            if (!groups[i].active)
            {
                groups[i].active = true;
                groups[i].flow_id = INVALID_FLOWFIELD;
                groups[i].has_order = false;

                return i;
            }
        }
        return INVALID_GROUP;
    }

    // Dans agent_manager.cpp
    void AgentManager::add_agent_to_group(int agent_id, GroupID group)
    {
        auto it = id_to_index.find(agent_id);
        if (it == id_to_index.end())
        {
            godot::UtilityFunctions::print("❌ Agent ", agent_id, " introuvable");
            return;
        }

        agents[it->second].group = group;
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

    FlowFieldID AgentManager::get_group_flow(GroupID group) const
    {
        if (group == INVALID_GROUP || group >= MAX_GROUPS)
            return INVALID_FLOWFIELD;
        return groups[group].flow_id;
    }

    void AgentManager::set_group_flow(GroupID group, FlowFieldID fid)
    {
        if (group == INVALID_GROUP || group >= MAX_GROUPS)
        {
            godot::UtilityFunctions::print("Set GRoup FLow INVALID GROUP sa mere");
            std::abort();
            return;
        }

        groups[group].flow_id = fid;
        groups[group].has_order = true;

        // ✅ Synchroniser avec le SteeringSystem
        FlowField *ff = ffcore::flowfields()->get(fid);
        if (!ff)
        {
            godot::UtilityFunctions::print("ERREUR: FlowField ", fid, " introuvable pour groupe ", group);
            std::abort();
            return;
        }

        SteeringSystem *steering = ffcore::get_global_steering_system();
        if (!steering)
        {
            godot::UtilityFunctions::print("ERREUR: SteeringSystem non disponible");
            std::abort();
            return;
        }

        // Mettre à jour tous les agents de ce groupe
        int count = 0;
        for (const auto &agent : agents)
        {
            if (agent.group == group)
            {
                steering->set_agent_flow_ptr(agent.id, ff);
                count++;
            }
        }
    }

    void AgentManager::dissolve_group(GroupID group)
    {
        if (group == GROUP_IDLE || group == INVALID_GROUP)
            return;

        for (auto &a : agents)
            if (a.group == group)
                a.group = GROUP_IDLE;

        groups[group].active = false;
        groups[group].has_order = false;
        groups[group].flow_id = INVALID_FLOWFIELD;
    }

    static GroupID current_selected_group = GROUP_IDLE;



}
