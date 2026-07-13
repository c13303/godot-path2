#include "projectile_system.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include "../grid/spatial_grid.h"
#include "../steering/steering_system.h"

namespace ffcore
{
    namespace
    {
        constexpr double FORCE_EPSILON = 1e-8;

        double projected_aabb_leading_edge(const Vec2 &origin, const Vec2 &dir, const AgentData &agent)
        {
            Vec2 fight_center = agent.position + Vec2(0, agent.profile.fight_offset_y);
            Vec2 offset = fight_center - origin;
            return offset.dot(dir) -
                   std::abs(dir.x) * agent.profile.fight_half_w -
                   std::abs(dir.y) * agent.profile.fight_half_h;
        }

        double lateral_axis_distance(const Vec2 &origin, const Vec2 &dir, const AgentData &agent)
        {
            Vec2 fight_center = agent.position + Vec2(0, agent.profile.fight_offset_y);
            Vec2 offset = fight_center - origin;
            return std::abs(offset.x * dir.y - offset.y * dir.x);
        }

        bool smash_candidate_is_eligible(const AgentData &agent, int agent_id, int ignored_agent_id, int affected_smash_classes)
        {
            if (agent_id == ignored_agent_id)
                return false;
            if (agent.phase == AgentPhase::Drowning)
                return false;
            if (agent.profile.weapon_immune)
                return false;
            if (affected_smash_classes != 0 && (agent.profile.smash_class & affected_smash_classes) == 0)
                return false;
            return true;
        }
    }

    ProjectileSystem::ProjectileSystem() {}

    void ProjectileSystem::set_static_collision_grid(int origin_x, int origin_y, int width, int height,
                                                     double tile_size, const std::vector<std::uint32_t> &mask)
    {
        static_colliders.origin_x = origin_x;
        static_colliders.origin_y = origin_y;
        static_colliders.width = std::max(0, width);
        static_colliders.height = std::max(0, height);
        static_colliders.tile_size = tile_size > 0.0 ? tile_size : 1.0;
        static_colliders.mask = mask;
    }

    bool ProjectileSystem::raycast_static_colliders(const Vec2 &from, const Vec2 &to,
                                                    std::uint32_t projectile_mask,
                                                    Vec2 &out_impact, Vec2i &out_cell,
                                                    std::uint32_t &out_collider_mask) const
    {
        if (!static_colliders.ready() || projectile_mask == 0)
            return false;

        // If the starting cell already matches, impact immediately at 'from'.
        Vec2i start_cell = static_colliders.world_to_cell(from);
        std::uint32_t start_match = static_colliders.channels_at(start_cell) & projectile_mask;
        if (start_match != 0)
        {
            out_impact = from;
            out_cell = start_cell;
            out_collider_mask = start_match;
            return true;
        }

        // Amanatides-Woo grid traversal across the move segment from->to.
        const double ts = static_colliders.tile_size;
        Vec2i cell = start_cell;
        Vec2i end_cell = static_colliders.world_to_cell(to);

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
        int guard = static_colliders.width + static_colliders.height + 2;
        while (guard-- > 0)
        {
            if (t_max_x < t_max_y)
            {
                if (t_max_x > 1.0)
                    break;
                cell.x += step_x;
                std::uint32_t matched = static_colliders.channels_at(cell) & projectile_mask;
                if (matched != 0)
                {
                    out_impact = from + d * t_max_x;
                    out_cell = cell;
                    out_collider_mask = matched;
                    return true;
                }
                t_max_x += t_delta_x;
            }
            else
            {
                if (t_max_y > 1.0)
                    break;
                cell.y += step_y;
                std::uint32_t matched = static_colliders.channels_at(cell) & projectile_mask;
                if (matched != 0)
                {
                    out_impact = from + d * t_max_y;
                    out_cell = cell;
                    out_collider_mask = matched;
                    return true;
                }
                t_max_y += t_delta_y;
            }
            if (cell == end_cell)
                break;
        }
        return false;
    }

    int ProjectileSystem::find_direct_hit_agent(const ProjectileTypeConfig &cfg, const Projectile &p, const Vec2 &direction) const
    {
        if (!grid || !steering)
            return -1;

        double query_radius = cfg.radius + steering->get_max_fight_query_padding();
        auto neighbors = grid->query_neighbors(p.pos, query_radius);
        int hit_agent_id = -1;
        double best_leading_edge = std::numeric_limits<double>::infinity();
        for (int nid : neighbors)
        {
            const AgentData *agent = steering->get_agent(nid);
            if (!agent)
                continue;
            if (!smash_candidate_is_eligible(*agent, nid, p.owner_agent_id, p.affected_smash_classes))
                continue;

            Vec2 fight_center = agent->position + Vec2(0, agent->profile.fight_offset_y);
            if (!circle_overlaps_aabb(p.pos, cfg.radius, fight_center, agent->profile.fight_half_w, agent->profile.fight_half_h))
                continue;

            double leading_edge = projected_aabb_leading_edge(p.pos, direction, *agent);
            if (leading_edge < best_leading_edge ||
                (leading_edge == best_leading_edge && (hit_agent_id < 0 || nid < hit_agent_id)))
            {
                best_leading_edge = leading_edge;
                hit_agent_id = nid;
            }
        }
        return hit_agent_id;
    }

    void ProjectileSystem::apply_budgeted_projectile_smash(const ProjectileTypeConfig &cfg, const Projectile &p,
                                                           const Vec2 &impact_pos, const Vec2 &impact_dir,
                                                           int direct_hit_agent_id)
    {
        if (!grid || !steering)
            return;
        if (!std::isfinite(impact_pos.x) || !std::isfinite(impact_pos.y) ||
            !std::isfinite(cfg.aoe_radius) || !std::isfinite(cfg.smash_force))
            return;
        if (cfg.aoe_radius <= 0.0)
            return;

        double remaining_budget = std::max(0.0, cfg.smash_force);
        if (remaining_budget <= FORCE_EPSILON)
            return;

        struct SmashCandidate
        {
            int id = -1;
            double distance = 0.0;
            double leading_edge = 0.0;
            double lateral_distance = 0.0;
            bool direct_hit = false;
        };

        std::vector<SmashCandidate> candidates;
        double query_radius = cfg.aoe_radius + steering->get_max_fight_query_padding();
        auto neighbors = grid->query_neighbors(impact_pos, query_radius);
        candidates.reserve(neighbors.size());

        for (int nid : neighbors)
        {
            const AgentData *agent = steering->get_agent(nid);
            if (!agent)
                continue;
            if (!smash_candidate_is_eligible(*agent, nid, p.owner_agent_id, p.affected_smash_classes))
                continue;

            Vec2 fight_center = agent->position + Vec2(0, agent->profile.fight_offset_y);
            double distance = point_aabb_distance(impact_pos, fight_center, agent->profile.fight_half_w, agent->profile.fight_half_h);
            if (distance > cfg.aoe_radius)
                continue;

            candidates.push_back(SmashCandidate{
                nid,
                distance,
                projected_aabb_leading_edge(impact_pos, impact_dir, *agent),
                lateral_axis_distance(impact_pos, impact_dir, *agent),
                nid == direct_hit_agent_id});
        }

        if (candidates.empty())
            return;

        std::sort(candidates.begin(), candidates.end(), [](const SmashCandidate &a, const SmashCandidate &b)
                  {
                      if (a.direct_hit != b.direct_hit)
                          return a.direct_hit;
                      if (a.leading_edge != b.leading_edge)
                          return a.leading_edge < b.leading_edge;
                      if (a.lateral_distance != b.lateral_distance)
                          return a.lateral_distance < b.lateral_distance;
                      return a.id < b.id;
                  });

        double safe_falloff = std::max(0.0, cfg.smash_falloff);
        for (const SmashCandidate &candidate : candidates)
        {
            if (remaining_budget <= FORCE_EPSILON)
                break;

            double base = std::max(0.0, 1.0 - candidate.distance / cfg.aoe_radius);
            double attenuation = std::pow(base, safe_falloff);
            double desired_force = cfg.smash_force * attenuation;
            double allocated_force = std::min(desired_force, remaining_budget);
            if (allocated_force <= FORCE_EPSILON)
                continue;

            steering->apply_smash_impulse(
                candidate.id,
                impact_dir,
                allocated_force,
                cfg.smash_friction_loss,
                0.0,
                cfg.smash_detach_flow,
                cfg.smash_control_suppression,
                cfg.smash_control_suppression_duration);
            remaining_budget -= allocated_force;
        }
    }

    void ProjectileSystem::trigger_end_aoe(const ProjectileTypeConfig &cfg, const Projectile &p,
                                           const Vec2 &at, ImpactKind kind,
                                           std::uint32_t collider_mask,
                                           const Vec2i &collider_cell)
    {
        Vec2 impact_dir = p.vel.normalized();
        if (cfg.end_of_life_aoe_enabled && steering)
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
        // Surface every end event so gameplay can react to generic static
        // collision channels even when this projectile has no end-of-life AoE.
        impact_events.push_back(ProjectileImpact{
            at, impact_dir, cfg.end_of_life_aoe_enabled ? cfg.end_aoe_radius : 0.0,
            static_cast<int>(p.type_id), static_cast<int>(kind),
            collider_mask, collider_cell});
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
                                int affected_smash_classes,
                                const Vec2 &inherited_velocity)
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
        p.vel = ndir * cfg.speed + inherited_velocity;
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

                // Static collision (visual altitude is ignored; uses ground pos).
                // Raycast the ground segment so fast projectiles can't tunnel
                // through thin walls.
                if (cfg.static_collision_mask != 0 && static_colliders.ready())
                {
                    Vec2 impact;
                    Vec2i collider_cell;
                    std::uint32_t collider_mask = 0;
                    if (raycast_static_colliders(prev_pos, p.pos, cfg.static_collision_mask,
                                                 impact, collider_cell, collider_mask))
                    {
                        p.pos = impact;
                        trigger_end_aoe(cfg, p, impact, ImpactKind::Wall,
                                        collider_mask, collider_cell);
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

                Vec2 impact_dir = p.vel.normalized();
                int hit_agent_id = find_direct_hit_agent(cfg, p, impact_dir);

                if (hit_agent_id >= 0 && steering)
                {
                    if (cfg.smash_budget_enabled)
                    {
                        apply_budgeted_projectile_smash(cfg, p, p.pos, impact_dir, hit_agent_id);
                    }
                    else
                    {
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
                    }
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
