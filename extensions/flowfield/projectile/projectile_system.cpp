#include "projectile_system.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include "../grid/spatial_grid.h"
#include "../steering/steering_system.h"

namespace ffcore
{
    ProjectileSystem::ProjectileSystem() {}

    void ProjectileSystem::set_wall_grid(int origin_x, int origin_y, int width, int height,
                                         double tile_size, const std::vector<std::uint8_t> &mask)
    {
        walls.origin_x = origin_x;
        walls.origin_y = origin_y;
        walls.width = std::max(0, width);
        walls.height = std::max(0, height);
        walls.tile_size = tile_size > 0.0 ? tile_size : 1.0;
        walls.mask = mask;
    }

    bool ProjectileSystem::raycast_walls(const Vec2 &from, const Vec2 &to, Vec2 &out_impact) const
    {
        if (!walls.ready())
            return false;

        // If the starting cell is already a wall, impact immediately at 'from'.
        if (walls.is_wall_cell(walls.world_to_cell(from)))
        {
            out_impact = from;
            return true;
        }

        // Amanatides-Woo grid traversal across the move segment from->to.
        const double ts = walls.tile_size;
        Vec2i cell = walls.world_to_cell(from);
        Vec2i end_cell = walls.world_to_cell(to);

        Vec2 d = to - from;
        int step_x = d.x > 0.0 ? 1 : (d.x < 0.0 ? -1 : 0);
        int step_y = d.y > 0.0 ? 1 : (d.y < 0.0 ? -1 : 0);

        // Distance (in t, 0..1) to cross one cell along each axis.
        double t_delta_x = (step_x != 0) ? std::abs(ts / d.x) : std::numeric_limits<double>::infinity();
        double t_delta_y = (step_y != 0) ? std::abs(ts / d.y) : std::numeric_limits<double>::infinity();

        // t to reach the first cell boundary along each axis.
        auto next_boundary = [&](double origin, double dir, int c) -> double
        {
            if (dir == 0.0)
                return std::numeric_limits<double>::infinity();
            double cell_min = (c + (dir > 0.0 ? 1 : 0)) * ts;
            return (cell_min - origin) / dir;
        };
        double t_max_x = next_boundary(from.x, d.x, cell.x);
        double t_max_y = next_boundary(from.y, d.y, cell.y);

        // Walk until we pass the destination cell. Bound the loop defensively.
        int guard = walls.width + walls.height + 2;
        while (guard-- > 0)
        {
            if (t_max_x < t_max_y)
            {
                if (t_max_x > 1.0)
                    break;
                cell.x += step_x;
                if (walls.is_wall_cell(cell))
                {
                    out_impact = from + d * t_max_x;
                    return true;
                }
                t_max_x += t_delta_x;
            }
            else
            {
                if (t_max_y > 1.0)
                    break;
                cell.y += step_y;
                if (walls.is_wall_cell(cell))
                {
                    out_impact = from + d * t_max_y;
                    return true;
                }
                t_max_y += t_delta_y;
            }
            if (cell == end_cell)
                break;
        }
        return false;
    }

    void ProjectileSystem::trigger_end_aoe(const ProjectileTypeConfig &cfg, const Projectile &p, const Vec2 &at, ImpactKind kind)
    {
        if (!cfg.end_of_life_aoe_enabled)
            return;
        Vec2 impact_dir = p.vel.normalized();
        if (steering)
        {
            steering->apply_area_smash(
                at,
                cfg.end_aoe_radius,
                impact_dir,
                cfg.end_aoe_force,
                cfg.end_aoe_friction_loss,
                cfg.end_aoe_falloff,
                cfg.end_aoe_detach_flow,
                cfg.end_aoe_control_suppression,
                cfg.end_aoe_control_suppression_duration,
                p.owner_agent_id,
                p.affected_smash_classes);
            steering->apply_area_damage(
                at,
                cfg.end_aoe_radius,
                p.owner_agent_id,
                p.affected_smash_classes,
                cfg.damage);
        }
        // Surface the AoE so GDScript can render it (one-frame event buffer).
        impact_events.push_back(ProjectileImpact{
            at, impact_dir, cfg.end_aoe_radius,
            static_cast<int>(p.type_id), static_cast<int>(kind)});
    }

    int ProjectileSystem::register_type(const ProjectileTypeConfig &cfg)
    {
        int type_id = static_cast<int>(types.size());
        types.push_back(cfg);

        int sz = std::max(1, cfg.pool_size);
        pools.emplace_back();
        pools.back().resize(static_cast<std::size_t>(sz));

        meta.emplace_back();
        TypePool &tp = meta.back();
        tp.free_list.reserve(static_cast<std::size_t>(sz));
        for (int i = sz - 1; i >= 0; --i)
            tp.free_list.push_back(static_cast<std::uint16_t>(i));

        return type_id;
    }

    std::uint16_t ProjectileSystem::checkout_slot(int type_id)
    {
        TypePool &tp = meta[type_id];
        std::vector<Projectile> &pool = pools[type_id];

        if (!tp.free_list.empty())
        {
            std::uint16_t idx = tp.free_list.back();
            tp.free_list.pop_back();
            return idx;
        }

        // recycle oldest active slot (lowest fire_seq among active)
        std::uint16_t oldest_idx = 0;
        std::uint64_t oldest_seq = UINT64_MAX;
        bool found = false;
        for (std::size_t i = 0; i < pool.size(); ++i)
        {
            if (pool[i].active && pool[i].fire_seq < oldest_seq)
            {
                oldest_seq = pool[i].fire_seq;
                oldest_idx = static_cast<std::uint16_t>(i);
                found = true;
            }
        }
        (void)found;
        return oldest_idx;
    }

    bool ProjectileSystem::fire(int type_id,
                                const Vec2 &pos,
                                const Vec2 &dir,
                                int owner_agent_id,
                                int affected_smash_classes)
    {
        if (type_id < 0 || type_id >= static_cast<int>(types.size()))
            return false;

        const ProjectileTypeConfig &cfg = types[type_id];

        Vec2 ndir = dir.normalized();
        if (ndir.is_zero())
            return false;

        std::uint16_t idx = checkout_slot(type_id);
        Projectile &p = pools[type_id][idx];

        p.pos = pos;
        p.vel = ndir * cfg.speed;
        p.lifetime_remaining = cfg.lifetime;
        p.owner_agent_id = owner_agent_id;
        p.affected_smash_classes = affected_smash_classes;
        p.type_id = static_cast<std::uint16_t>(type_id);
        p.active = 1;
        p.fire_seq = next_fire_seq++;
        return true;
    }

    void ProjectileSystem::update(double delta)
    {
        if (!grid || delta <= 0.0)
            return;

        // Impact events live for exactly one update; GDScript drains them after.
        impact_events.clear();

        for (std::size_t t = 0; t < pools.size(); ++t)
        {
            const ProjectileTypeConfig &cfg = types[t];
            std::vector<Projectile> &pool = pools[t];
            TypePool &tp = meta[t];

            for (std::size_t i = 0; i < pool.size(); ++i)
            {
                Projectile &p = pool[i];
                if (!p.active)
                    continue;

                Vec2 prev_pos = p.pos;
                p.pos += p.vel * delta;

                // Wall collision (visual altitude is ignored; uses ground pos).
                // Raycast the ground segment so fast projectiles can't tunnel
                // through thin walls.
                if (cfg.stopped_by_walls && walls.ready())
                {
                    Vec2 impact;
                    if (raycast_walls(prev_pos, p.pos, impact))
                    {
                        p.pos = impact;
                        trigger_end_aoe(cfg, p, impact, ImpactKind::Wall);
                        p.active = 0;
                        tp.free_list.push_back(static_cast<std::uint16_t>(i));
                        continue;
                    }
                }

                p.lifetime_remaining -= delta;
                if (p.lifetime_remaining <= 0.0)
                {
                    trigger_end_aoe(cfg, p, p.pos, ImpactKind::Expiry);
                    p.active = 0;
                    tp.free_list.push_back(static_cast<std::uint16_t>(i));
                    continue;
                }

                double query_radius = cfg.radius + (steering ? steering->get_max_fight_query_padding() : 0.0);
                auto neighbors = grid->query_neighbors(p.pos, query_radius);
                bool hit = false;
                for (int nid : neighbors)
                {
                    if (nid == p.owner_agent_id)
                        continue;

                    // We don't have direct agent lookup here; let SteeringSystem do
                    // the faction/immune filtering inside apply_area_smash. To detect
                    // contact we still need a position — query the steering system.
                    const AgentData *a = steering ? steering->get_agent(nid) : nullptr;
                    if (!a)
                        continue;
                    if (a->profile.weapon_immune)
                        continue;
                    if (p.affected_smash_classes != 0 &&
                        (a->profile.smash_class & p.affected_smash_classes) == 0)
                        continue;

                    Vec2 fight_center = a->position + Vec2(0, a->profile.fight_offset_y);
                    if (circle_overlaps_aabb(p.pos, cfg.radius, fight_center, a->profile.fight_half_w, a->profile.fight_half_h))
                    {
                        hit = true;
                        break;
                    }
                }

                if (hit && steering)
                {
                    Vec2 impact_dir = p.vel.normalized();
                    steering->apply_area_smash(
                        p.pos,
                        cfg.aoe_radius,
                        impact_dir,
                        cfg.smash_force,
                        cfg.smash_friction_loss,
                        cfg.smash_falloff,
                        cfg.smash_detach_flow,
                        cfg.smash_control_suppression,
                        cfg.smash_control_suppression_duration,
                        p.owner_agent_id,
                        p.affected_smash_classes);
                    steering->apply_area_damage(
                        p.pos,
                        cfg.aoe_radius,
                        p.owner_agent_id,
                        p.affected_smash_classes,
                        cfg.damage);

                    impact_events.push_back(ProjectileImpact{
                        p.pos, impact_dir, cfg.aoe_radius,
                        static_cast<int>(p.type_id), static_cast<int>(ImpactKind::Agent)});

                    p.active = 0;
                    tp.free_list.push_back(static_cast<std::uint16_t>(i));
                }
            }
        }
    }

    std::size_t ProjectileSystem::active_count(int type_id) const
    {
        if (type_id < 0 || type_id >= static_cast<int>(pools.size()))
            return 0;
        std::size_t n = 0;
        for (const auto &p : pools[type_id])
            if (p.active)
                ++n;
        return n;
    }
}
