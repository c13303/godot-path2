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

    static Vec2i nearest_navigable(const ffcore::FlowField *ff, const Vec2i &cell)
    {
        if (ff->is_cell_navigable(cell))
            return cell;
        Vec2i best = cell;
        int max_r = 3;
        for (int r = 1; r <= max_r; ++r)
        {
            for (int dx = -r; dx <= r; ++dx)
                for (int dy = -r; dy <= r; ++dy)
                {
                    Vec2i c{cell.x + dx, cell.y + dy};
                    if (!ff->is_cell_navigable(c))
                        continue;
                    if (dx * dx + dy * dy < (best.x - cell.x) * (best.x - cell.x) + (best.y - cell.y) * (best.y - cell.y))
                        best = c;
                }
        }
        return best;
    }

    void AgentManager::distribute_tiles_to_agents(GroupID g)
    {
        if (g == INVALID_GROUP || g == GROUP_IDLE)
            return;

        SteeringSystem *steering = ffcore::get_global_steering_system();
        if (!steering)
            return;

        const ffcore::FlowField *ref_flow = nullptr;
        FormationFootprint fp = compute_group_footprint(g);
        double angle = fp.angle;
        double cos_a = std::cos(angle);
        double sin_a = std::sin(angle);
        Vec2 origin = fp.origin;
        double tsize = ffcore::globalconfig().tile_size;

        for (const auto &a : agents)
        {
            if (a.group != g)
                continue;
            if (const auto *ad = steering->get_agent(a.id))
            {
                if (ad->flow)
                {
                    ref_flow = ad->flow;
                    if (ad->flow->tile_size() > 0.0)
                        tsize = ad->flow->tile_size();
                    break;
                }
            }
        }

        if (!ref_flow)
            return;

        struct AgentTile
        {
            int id;
            Vec2i tile;
            double rx = 0.0;
            double ry = 0.0;
        };

        std::vector<AgentTile> group_agents;
        group_agents.reserve(agents.size());
        for (const auto &a : agents)
            if (a.group == g)
                if (const auto *ad = steering->get_agent(a.id))
                {
                    Vec2 foot = ad->position + Vec2(0, ffcore::globalconfig().agent_offset_y);
                    Vec2i rel = ad->flow ? ad->flow->world_to_cell(foot) : Vec2i((int)std::round(foot.x / tsize), (int)std::round(foot.y / tsize));
                    Vec2i map_cell = ad->flow ? Vec2i(rel.x + ad->flow->get_cell_origin().x, rel.y + ad->flow->get_cell_origin().y) : rel;
                    Vec2 world_center = ad->flow ? ad->flow->cell_to_world(rel) : Vec2(map_cell.x * tsize, map_cell.y * tsize);
                    Vec2 d = world_center - origin;
                    double rx = cos_a * d.x + sin_a * d.y;
                    double ry = sin_a * d.x - cos_a * d.y; // adjust for Godot Y-down
                    group_agents.push_back({a.id, map_cell, rx, ry});
                }

        if (group_agents.empty())
            return;

        int fw = std::max(1, fp.w);
        int fh = std::max(1, fp.h);
        double tile_size = ref_flow->tile_size();
        Vec2 goal_center = ref_flow->goal_center_world();

        struct SlotRot
        {
            Vec2i cell;
            double rx;
            double ry;
        };
        std::vector<SlotRot> slots;
        slots.reserve((size_t)fw * (size_t)fh);
        for (int jy = 0; jy < fh; ++jy)
            for (int ix = 0; ix < fw; ++ix)
            {
                double lx = (ix - fw * 0.5 + 0.5) * tile_size;
                double ly = (jy - fh * 0.5 + 0.5) * tile_size;
                double rxw = cos_a * lx - sin_a * ly;
                double ryw = sin_a * lx + cos_a * ly;
                Vec2 world = goal_center + Vec2(rxw, ryw);
                Vec2i rel = ref_flow->world_to_cell(world);
                Vec2i nav = nearest_navigable(ref_flow, rel);
                Vec2 nav_world = ref_flow->cell_to_world(nav);
                Vec2 d = nav_world - origin;
                double rx = cos_a * d.x + sin_a * d.y;
                double ry = sin_a * d.x - cos_a * d.y;
                Vec2i map_cell(nav.x + ref_flow->get_cell_origin().x, nav.y + ref_flow->get_cell_origin().y);
                slots.push_back({map_cell, rx, ry});
            }

        size_t count = std::min(group_agents.size(), slots.size());
        std::vector<bool> slot_used(slots.size(), false);
        std::vector<Vec2i> assigned_tiles;
        for (size_t i = 0; i < count; ++i)
        {
            const auto &agt = group_agents[i];
            double best_cost = 1e18;
            int best_idx = -1;
            for (size_t j = 0; j < slots.size(); ++j)
            {
                if (slot_used[j])
                    continue;
                double dx = agt.rx - slots[j].rx;
                double dy = agt.ry - slots[j].ry;
                double cost = dx * dx + dy * dy;
                if (cost < best_cost)
                {
                    best_cost = cost;
                    best_idx = (int)j;
                }
            }
            if (best_idx >= 0)
            {
                slot_used[best_idx] = true;
                steering->set_agent_claimed_tile(agt.id, slots[best_idx].cell);
                assigned_tiles.push_back(slots[best_idx].cell);
            }
        }

        if (ref_flow)
        {
            double max_d2 = 0.0;
            std::vector<Vec2i> t2_tiles = assigned_tiles;
            Vec2 goal_center = ref_flow->goal_center_world();
            for (const auto &c : t2_tiles)
            {
                Vec2i rel(c.x - ref_flow->get_cell_origin().x, c.y - ref_flow->get_cell_origin().y);
                double d2 = (ref_flow->cell_to_world(rel) - goal_center).length_squared();
                if (d2 > max_d2)
                    max_d2 = d2;
            }
            double radius = std::sqrt(max_d2) + std::max(0.0, ffcore::globalconfig().target_T2_param_margin);
            const_cast<FlowField *>(ref_flow)->set_t2_tiles(std::move(t2_tiles), radius);
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
