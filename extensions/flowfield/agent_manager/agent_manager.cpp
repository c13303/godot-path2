#include "agent_manager.h"
#include "../core/nav_config.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include "../flow/flow_field_manager.h"
#include "../flow/flow_field.h"
#include "../steering/steering_system.h"
#include "../godot/flow_field_native.h"
#include "../core/types.h"
#include "../core/nav_services.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
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
        }

        groups[GROUP_IDLE].id = GROUP_IDLE;
        groups[GROUP_IDLE].active = true; // ← empêche create_group() de l’utiliser
        groups[GROUP_IDLE].flow = nullptr;
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
                groups[i].flow = nullptr;
                groups[i].has_order = false;

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

    void AgentManager::set_group_flow(GroupID group, FlowField *flow)
    {
        if (group == INVALID_GROUP || group >= MAX_GROUPS)
        {
            godot::UtilityFunctions::print("Set Group Flow INVALID GROUP");
            std::abort();
        }

        groups[group].flow = flow;
        groups[group].has_order = true;

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
        if (group == GROUP_IDLE || group == INVALID_GROUP)
            return;

        for (auto &a : agents)
            if (a.group == group)
                a.group = GROUP_IDLE;

        /* godot::UtilityFunctions::print("Dissolution groupe ", group); */

        groups[group].active = false;
        groups[group].has_order = false;
        groups[group].flow = nullptr;
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

    void AgentManager::distribute_tiles_to_agents(GroupID g, FlowField &flow)
    {
        flow.set_t2_tiles({}, 0.0);
        if (g == INVALID_GROUP || g == GROUP_IDLE || !flow.is_ready() || !flow.has_goal())
            return;

        SteeringSystem *steering = ffcore::get_global_steering_system();
        if (!steering)
            return;

        const Vec2i origin = flow.get_cell_origin();
        const Vec2i goal_rel = flow.get_goal_cell();
        const Vec2i goal_map(goal_rel.x + origin.x, goal_rel.y + origin.y);

        auto encode = [](const Vec2i &c) -> int64_t
        { return (int64_t(c.x) << 32) ^ (uint32_t)c.y; };

        std::unordered_set<int64_t> blocked;
        blocked.reserve(agents.size() * 2 + 1);
        for (const auto &a : agents)
        {
            if (a.group == g)
                continue;
            if (const auto *ad = steering->get_agent(a.id))
            {
                Vec2i ct = ad->claimed_tile;
                if (ct.x < -100000 || ct.y < -100000)
                    continue;
                blocked.insert(encode(ct));
            }
        }

        struct AgentTile
        {
            int id;
            Vec2i map_cell;
        };

        std::vector<AgentTile> group_agents;
        group_agents.reserve(agents.size());
        for (const auto &a : agents)
            if (a.group == g)
                if (const auto *ad = steering->get_agent(a.id))
                {
                    Vec2 foot = ad->position + Vec2(0, ffcore::globalconfig().agent_offset_y);
                    Vec2i rel = flow.world_to_cell(foot);
                    Vec2i map_cell(rel.x + origin.x, rel.y + origin.y);
                    group_agents.push_back({a.id, map_cell});
                }

        if (group_agents.empty())
            return;

        std::sort(group_agents.begin(), group_agents.end(), [](const AgentTile &lhs, const AgentTile &rhs)
                  {
                      if (lhs.map_cell.y == rhs.map_cell.y)
                          return lhs.map_cell.x < rhs.map_cell.x;
                      return lhs.map_cell.y < rhs.map_cell.y;
                  });

        int n = (int)group_agents.size();
        int w = (int)std::ceil(std::sqrt((double)n));
        int h = (int)std::ceil((double)n / std::max(1, w));

        int start_x = goal_map.x - w / 2;
        int start_y = goal_map.y - h / 2;

        std::vector<Vec2i> tiles;
        tiles.reserve(n);
        for (int jy = 0; jy < h && (int)tiles.size() < n; ++jy)
            for (int ix = 0; ix < w && (int)tiles.size() < n; ++ix)
            {
                Vec2i map_cell(start_x + ix, start_y + jy);
                if (blocked.count(encode(map_cell)))
                    continue;
                Vec2i rel(map_cell.x - origin.x, map_cell.y - origin.y);
                if (!flow.is_cell_navigable(rel))
                    continue;
                tiles.push_back(map_cell);
            }

        double radius = 0.0;
        if (!tiles.empty())
        {
            Vec2 goal_center = flow.goal_center_world();
            double max_d2 = 0.0;
            for (const auto &c : tiles)
            {
                Vec2i rel(c.x - origin.x, c.y - origin.y);
                double d2 = (flow.cell_to_world(rel) - goal_center).length_squared();
                if (d2 > max_d2)
                    max_d2 = d2;
            }
            const auto &cfg = globalconfig();
            radius = std::sqrt(max_d2) + std::max(0.0, cfg.target_T2_param_margin);
        }

        flow.set_t2_tiles(tiles, radius);
        if (tiles.empty())
            return;

        size_t count = std::min(group_agents.size(), tiles.size());
        for (size_t i = 0; i < count; ++i)
        {
            int agent_id = group_agents[i].id;
            const Vec2i &tile = tiles[i];
            steering->set_agent_claimed_tile(agent_id, tile);
        }
    }

    void AgentManager::get_claimed_tiles(GroupID g, std::vector<Vec2i> &out) const
    {
        out.clear();
        if (g == INVALID_GROUP || g == GROUP_IDLE)
            return;

        SteeringSystem *steering = ffcore::get_global_steering_system();
        if (!steering)
            return;

        for (const auto &a : agents)
        {
            if (a.group != g)
                continue;
            const auto *ad = steering->get_agent(a.id);
            if (!ad)
                continue;
            // claimed_tile uses sentinel (-999999, -999999) when unset
            if (ad->claimed_tile.x < -100000 || ad->claimed_tile.y < -100000)
                continue;
            out.push_back(ad->claimed_tile);
        }
    }

    void AgentManager::get_group_claim_debug(GroupID g, std::vector<AgentClaimDebug> &out) const
    {
        out.clear();
        if (g == INVALID_GROUP || g == GROUP_IDLE)
            return;

        SteeringSystem *steering = ffcore::get_global_steering_system();
        if (!steering)
            return;

        out.reserve(agents.size());
        for (const auto &a : agents)
        {
            if (a.group != g)
                continue;
            if (const auto *ad = steering->get_agent(a.id))
            {
                if (ad->claimed_tile.x < -100000 || ad->claimed_tile.y < -100000)
                    continue;
                AgentClaimDebug dbg;
                dbg.id = a.id;
                dbg.pos = ad->position;
                dbg.claimed_tile = ad->claimed_tile;
                dbg.moving = ad->moving;
                dbg.color = ad->debug_color;
                out.push_back(dbg);
            }
        }
    }

    ffcore::FormationFootprint AgentManager::compute_group_footprint(GroupID g)
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
        fp.origin = Vec2(cx, cy);

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
        double angle = 0.5 * std::atan2(2.0 * cov_xy, cov_xx - cov_yy);
        // stabilize sign vs previous
        auto &grp = groups[g];
        if (grp.angle_initialized)
        {
            Vec2 prev_axis(std::cos(grp.last_angle), std::sin(grp.last_angle));
            Vec2 new_axis(std::cos(angle), std::sin(angle));
            double dot = prev_axis.x * new_axis.x + prev_axis.y * new_axis.y;
            if (dot < 0.0)
                angle += 3.14159265358979323846;
            // hysteresis: keep old angle if change is small
            double delta = std::abs(angle - grp.last_angle);
            while (delta > 3.14159265358979323846)
                delta -= 3.14159265358979323846;
            if (delta < (15.0 * 3.14159265358979323846 / 180.0))
                angle = grp.last_angle;
        }
        fp.angle = angle;
        grp.last_angle = angle;
        grp.angle_initialized = true;
        grp.last_origin = fp.origin;

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
