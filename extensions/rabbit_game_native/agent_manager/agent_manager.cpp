#include "agent_manager.h"
#include "../core/nav_config.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include "../flow/flow_field_manager.h"
#include "CPathLib/flow/flow_field.h"
#include "../steering/steering_system.h"
#include "../godot/flow_field_native.h"
#include "CPathLib/core/types.h"
#include "../core/nav_services.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <optional>
#include <utility>
#include <unordered_set>

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
            groups[i].flow = nullptr;
            groups[i].has_order = false;
            groups[i].flow_wait = GROUP_FLOW_WAIT_NONE;
            groups[i].lifecycle_generation = 0;
        }

        groups[GROUP_IDLE].id = GROUP_IDLE;
        groups[GROUP_IDLE].active = true; // ← empêche create_group() de l’utiliser
        groups[GROUP_IDLE].flow = nullptr;
        groups[GROUP_IDLE].has_order = false;
        groups[GROUP_IDLE].flow_wait = GROUP_FLOW_WAIT_NONE;
        groups[GROUP_IDLE].lifecycle_generation = 0;
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
                groups[i].flow = nullptr;
                groups[i].has_order = false;
                groups[i].flow_wait = GROUP_FLOW_WAIT_NONE;
                ++groups[i].lifecycle_generation;

                return i;
            }
        }
        return INVALID_GROUP;
    }

    void AgentManager::add_agent_to_group(int agent_id, GroupID group)
    {
        auto it = id_to_index.find(agent_id);
        if (it == id_to_index.end())
        {
            godot::UtilityFunctions::print("❌ Agent ", agent_id, " introuvable");
            return;
        }

        // Mise à jour du groupe
        agents[it->second].group = group;
        if (auto *steering = ffcore::get_global_steering_system())
            steering->set_agent_group(agent_id, group);

        // Réaffectation du FlowField si le groupe a déjà un flow actif
        FlowField *ff = groups[group].flow;

        if (ff)
        {
            ffcore::SteeringSystem *steering = ffcore::get_global_steering_system();
            steering->set_agent_flow_ptr(agent_id, ff);
        }
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

    void AgentManager::debug_collect_agent_ids(std::vector<int> &out) const
    {
        out.clear();
        out.reserve(id_to_index.size());
        for (const auto &entry : id_to_index)
            out.push_back(entry.first);
        std::sort(out.begin(), out.end());
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

    FlowField *AgentManager::get_group_flow(GroupID group) const
    {
        if (group == INVALID_GROUP || group >= MAX_GROUPS)
            return nullptr;
        return groups[group].flow;
    }

    void AgentManager::set_group_flow(GroupID group, FlowField *flow)
    {
        if (group == INVALID_GROUP || group >= MAX_GROUPS)
        {
            godot::UtilityFunctions::print("Set Group Flow INVALID GROUP");
            std::abort();
        }

        FlowField *old_group_flow = groups[group].flow;
        groups[group].flow = flow;
        groups[group].has_order = true;

        if (old_group_flow != flow)
            ffcore::cleanup_flow_if_unused(old_group_flow);

        FlowField *ff = flow;
        if (!ff)
        {
            godot::UtilityFunctions::print("ERREUR: FlowField null pour groupe ", group);
            std::abort();
        }

        SteeringSystem *steering = ffcore::get_global_steering_system();
        if (!steering)
        {
            godot::UtilityFunctions::print("ERREUR: SteeringSystem non disponible");
            std::abort();
        }

        for (const auto &agent : agents)
            if (agent.group == group)
                steering->set_agent_flow_ptr(agent.id, ff);
    }

    void AgentManager::dissolve_group(GroupID group)
    {
        if (group == GROUP_IDLE || group == INVALID_GROUP || group >= MAX_GROUPS)
            return;

        FlowField *old_group_flow = groups[group].flow;
        groups[group].flow = nullptr;
        SteeringSystem *steering = ffcore::get_global_steering_system();
        bool detached_any = false;
        for (auto &a : agents)
        {
            if (a.group == group)
            {
                if (steering)
                {
                    steering->set_agent_flow_ptr(a.id, nullptr);
                    detached_any = true;
                }
                a.group = GROUP_IDLE;
            }
        }

        if (!detached_any)
            ffcore::cleanup_flow_if_unused(old_group_flow);

        /* godot::UtilityFunctions::print("Dissolution groupe ", group); */

        groups[group].active = false;
        groups[group].has_order = false;
        groups[group].flow_wait = GROUP_FLOW_WAIT_NONE;
        ++groups[group].lifecycle_generation;
    }

    void AgentManager::set_group_flow_wait(GroupID group, int state)
    {
        if (group == INVALID_GROUP || group >= MAX_GROUPS)
            return;
        groups[group].flow_wait = state;
    }

    int AgentManager::get_group_flow_wait(GroupID group) const
    {
        if (group == INVALID_GROUP || group >= MAX_GROUPS)
            return GROUP_FLOW_WAIT_NONE;
        return groups[group].flow_wait;
    }

    std::uint64_t AgentManager::get_group_generation(GroupID group) const
    {
        if (group == INVALID_GROUP || group >= MAX_GROUPS)
            return 0;
        return groups[group].lifecycle_generation;
    }

    static GroupID current_selected_group = GROUP_IDLE;

    bool AgentManager::is_group_active(GroupID g) const
    {
        if (g == GROUP_IDLE || g >= MAX_GROUPS)
            return false;
        return groups[g].active;
    }

    bool AgentManager::all_agents_inactive(GroupID g) const
    {
        if (g == GROUP_IDLE || g >= MAX_GROUPS)
            return true;

        SteeringSystem *steering = ffcore::get_global_steering_system();

        for (const auto &a : agents)
        {
            if (a.group != g)
                continue;

            if (!steering)
                return false;

            const ffcore::AgentData *ad = steering->get_agent(a.id);
            if (ad && ad->active)
                return false;
        }
        return true;
    }

    void AgentManager::mark_group_finished(GroupID g)
    {
        if (g == GROUP_IDLE || g >= MAX_GROUPS)
            return;

        groups[g].has_order = false;
    }

    void AgentManager::mark_group_has_order(GroupID g)
    {
        if (g == GROUP_IDLE || g >= MAX_GROUPS)
            return;

        groups[g].has_order = true;
    }

    int AgentManager::count_group_members(GroupID g) const
    {
        if (g == INVALID_GROUP)
            return 0;

        int count = 0;
        for (const auto &a : agents)
            if (a.group == g)
                ++count;
        return count;
    }

    int AgentManager::count_groups_referencing_flow(const FlowField *flow) const
    {
        if (!flow)
            return 0;

        int count = 0;
        for (GroupID group = 1; group < MAX_GROUPS; group++)
        {
            if (groups[group].active && groups[group].flow == flow)
                ++count;
        }
        return count;
    }

    ffcore::FormationFootprint AgentManager::compute_group_footprint(GroupID g) const
    {
        FormationFootprint fp;
        if (g == INVALID_GROUP || g == GROUP_IDLE)
            return fp;

        SteeringSystem *steering = ffcore::get_global_steering_system();
        if (!steering)
            return fp;

        double minx = 1e18, miny = 1e18, maxx = -1e18, maxy = -1e18;
        double cx = 0.0, cy = 0.0;
        int count = 0;
        for (const auto &a : agents)
        {
            if (a.group != g)
                continue;
            if (const auto *ad = steering->get_agent(a.id))
            {
                minx = std::min(minx, ad->position.x);
                miny = std::min(miny, ad->position.y);
                maxx = std::max(maxx, ad->position.x);
                maxy = std::max(maxy, ad->position.y);
                cx += ad->position.x;
                cy += ad->position.y;
                ++count;
            }
        }
        if (count == 0)
            return fp;

        cx /= count;
        cy /= count;

        // principal axis via covariance
        double cov_xx = 0.0, cov_xy = 0.0, cov_yy = 0.0;
        for (const auto &a : agents)
        {
            if (a.group != g)
                continue;
            if (const auto *ad = steering->get_agent(a.id))
            {
                double dx = ad->position.x - cx;
                double dy = ad->position.y - cy;
                cov_xx += dx * dx;
                cov_xy += dx * dy;
                cov_yy += dy * dy;
            }
        }
        if (count > 0)
        {
            cov_xx /= count;
            cov_xy /= count;
            cov_yy /= count;
        }
        // angle of principal axis (largest eigenvalue)
        fp.angle = 0.5 * std::atan2(2.0 * cov_xy, cov_xx - cov_yy);

        // bounding box in rotated frame
        double cos_a = std::cos(fp.angle);
        double sin_a = std::sin(fp.angle);
        double rminx = 1e18, rminy = 1e18, rmaxx = -1e18, rmaxy = -1e18;
        for (const auto &a : agents)
        {
            if (a.group != g)
                continue;
            if (const auto *ad = steering->get_agent(a.id))
            {
                double dx = ad->position.x - cx;
                double dy = ad->position.y - cy;
                double rx = cos_a * dx + sin_a * dy;
                double ry = -sin_a * dx + cos_a * dy;
                rminx = std::min(rminx, rx);
                rmaxx = std::max(rmaxx, rx);
                rminy = std::min(rminy, ry);
                rmaxy = std::max(rmaxy, ry);
            }
        }

        double tsize = std::max(1.0, ffcore::globalconfig().tile_size);
        fp.w = std::max(1, (int)std::round((rmaxx - rminx) / tsize) + 1);
        fp.h = std::max(1, (int)std::round((rmaxy - rminy) / tsize) + 1);
        return fp;
    }

}
