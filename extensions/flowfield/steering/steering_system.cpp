#include "steering_system.h" // Inclusion du header de la classe SteeringSystem
#include <algorithm>         // Pour std::sort et std::min
#include <cstdio>            // Pour les fonctions de debug (printf, etc.)
#include <cmath>             // Pour les fonctions trigonométriques
#include <unordered_map>     // Pour le stockage rapide des cooldowns par id
#include <godot_cpp/variant/utility_functions.hpp>
#include "../core/nav_services.h"
#include "../agent_manager/agent_manager.h"
#include "../flow/flow_field.h"
#include "../grid/spatial_grid.h"
#include "../flow/flow_field_manager.h"
#include <cstdlib>

using namespace ffcore; // Utilisation de l’espace de noms du moteur

/* declaration generale du system pour partage */
static SteeringSystem *g_steering = nullptr;
SteeringSystem *ffcore::get_global_steering_system() { return g_steering; }
SteeringSystem::SteeringSystem()
{

    g_steering = this;
}

static inline Vec2 safe_normalize(const Vec2 &v) // Normalise un vecteur, évite la division par zéro
{
    if (!std::isfinite(v.x) || !std::isfinite(v.y))
        return Vec2(0, 0);
    double l = v.length();
    if (!std::isfinite(l) || l < 1e-6)
        return Vec2(0, 0);
    return v * (1.0 / l);
}

static inline double safe_len(const Vec2 &v) // Renvoie la longueur d’un vecteur, évite les très petites valeurs
{
    if (!std::isfinite(v.x) || !std::isfinite(v.y))
        return 0.0;
    double l = v.length();
    return (!std::isfinite(l) || l < 1e-6) ? 0.0 : l;
}

static inline Vec2 move_toward_vec(const Vec2 &current, const Vec2 &target, double max_delta)
{
    Vec2 diff = target - current;
    double dist = safe_len(diff);
    if (dist <= max_delta || dist <= 1e-6)
        return target;
    return current + diff * (max_delta / dist);
}

static inline Vec2 hashed_unit_dir(int id) // Génère une direction pseudo-aléatoire stable basée sur un id
{
    unsigned h = (unsigned)id * 1664525u + 1013904223u;
    double a = (h & 0xFFFFu) / 65535.0 * 6.28318530718;
    return Vec2(std::cos(a), std::sin(a));
}

static Vec3 hashed_color(int id)
{
    unsigned h = (unsigned)id * 2654435761u + 1013904223u;
    auto chan = [&](unsigned shift) -> double
    {
        return ((h >> shift) & 0xFFu) / 255.0;
    };
    return Vec3{chan(0), chan(8), chan(16)};
}

static std::unordered_map<int, double> g_goal_cooldown; // Cooldown global pour les agents autour des objectifs

static inline Vec2 agent_foot_point(const AgentData &a)
{
    return a.position + Vec2(0, a.profile.foot_offset_y);
}

static inline double agent_fight_query_padding(const AgentData &a)
{
    return std::abs(a.profile.foot_offset_y - a.profile.fight_offset_y) + std::sqrt(a.profile.fight_half_w * a.profile.fight_half_w + a.profile.fight_half_h * a.profile.fight_half_h);
}

static inline Vec2 agent_fight_center(const AgentData &a)
{
    return a.position + Vec2(0, a.profile.fight_offset_y);
}

static inline Vec2 aabb_radial_direction(const Vec2 &origin, const AgentData &agent)
{
    Vec2 closest = closest_point_on_aabb(origin, agent_fight_center(agent), agent.profile.fight_half_w, agent.profile.fight_half_h);
    Vec2 dir = closest - origin;
    if (dir.is_zero())
        dir = agent_fight_center(agent) - origin;
    return dir;
}

AgentProfile SteeringSystem::sanitize_agent_profile(const AgentProfile &profile) const
{
    AgentProfile sanitized = profile;
    const auto &cfg = globalconfig();

    sanitized.crowd_push_strength = std::isfinite(sanitized.crowd_push_strength) ? std::max(0.0, sanitized.crowd_push_strength) : 1.0;
    sanitized.crowd_resist_strength = std::isfinite(sanitized.crowd_resist_strength) ? std::max(0.001, sanitized.crowd_resist_strength) : 1.0;
    sanitized.world_radius = std::isfinite(sanitized.world_radius) && sanitized.world_radius > 0.0 ? sanitized.world_radius : cfg.tile_size * cfg.agent_world_diameter_ratio * 0.5;
    sanitized.foot_offset_y = std::isfinite(sanitized.foot_offset_y) ? sanitized.foot_offset_y : cfg.agent_offset_y;
    if (!std::isfinite(sanitized.foot_offset_y))
        sanitized.foot_offset_y = 0.0;
    sanitized.fight_offset_y = std::isfinite(sanitized.fight_offset_y) ? sanitized.fight_offset_y : 0.0;
    sanitized.fight_half_w = std::isfinite(sanitized.fight_half_w) ? std::max(0.0, sanitized.fight_half_w) : 0.0;
    sanitized.fight_half_h = std::isfinite(sanitized.fight_half_h) ? std::max(0.0, sanitized.fight_half_h) : 0.0;
    if (sanitized.smash_class < 0)
        sanitized.smash_class = 0;

    return sanitized;
}

void SteeringSystem::recompute_hitbox_query_extents()
{
    max_fight_query_padding = 0.0;
    max_world_radius = 0.0;
    for (const auto &agent : agents)
    {
        max_fight_query_padding = std::max(max_fight_query_padding, agent_fight_query_padding(agent));
        max_world_radius = std::max(max_world_radius, agent.profile.world_radius);
    }
}

int SteeringSystem::register_agent(const Vec2 &pos, double max_speed, FlowField *flow) // Enregistre un agent
{
    if (!std::isfinite(pos.x) || !std::isfinite(pos.y))
    {
        godot::UtilityFunctions::printerr(
            "register_agent: non-finite spawn position (", pos.x, ",", pos.y, ")");
        return -1;
    }

    AgentData a;
    a.id = next_id++;
    a.position = pos;
    a.max_speed = globalconfig().agent_max_speed;
    a.flow = flow ? flow : default_flow;
    if (a.flow)
        a.flow->refcount++;
    a.profile = sanitize_agent_profile(a.profile);
    a.debug_color = hashed_color(a.id);
    agents.push_back(a);
    id_to_index[a.id] = (int)agents.size() - 1;
    if (grid)
        grid->insert(a.id, agent_foot_point(a));
    recompute_hitbox_query_extents();
    g_goal_cooldown[a.id] = 0.0;
    return a.id;
}

void SteeringSystem::unregister_agent(int id) // Supprime un agent
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    for (auto &field_entry : bottleneck_reservations)
    {
        for (auto &reservation_entry : field_entry.second)
        {
            BottleneckReservation &reservation = reservation_entry.second;
            if (reservation.owner_id == id)
            {
                reservation.owner_id = -1;
                reservation.time_left = 0.0;
            }
        }
    }

    int idx = it->second;
    if (grid)
        grid->remove(id);

    FlowField *old_flow = agents[idx].flow;
    if (old_flow)
    {
        old_flow->refcount--;
        ffcore::cleanup_flow_if_unused(old_flow);
    }

    int last = (int)agents.size() - 1;
    if (idx != last)
    {
        agents[idx] = agents[last];
        id_to_index[agents[idx].id] = idx;
    }
    agents.pop_back();
    id_to_index.erase(it);
    g_goal_cooldown.erase(id);
    recompute_hitbox_query_extents();
}

void SteeringSystem::reactivate_agents_for_field(FlowField *field)
{
    bottleneck_reservations.erase(field);
    for (auto &a : agents)
    {
        if (a.flow != field)
            continue;
        a.active = true;
    }
}

void SteeringSystem::set_default_flowfield(FlowField *f) { default_flow = f; } // Définit le FlowField par défaut
void SteeringSystem::set_grid(SpatialGrid *g) { grid = g; }                    // Définit la grille spatiale

void SteeringSystem::set_agent_group(int id, GroupID group)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    agents[it->second].group = group;
}

int SteeringSystem::register_agent_with_id(int fixed_id, const Vec2 &pos, double max_speed, FlowField *flow)
{
    if (!std::isfinite(pos.x) || !std::isfinite(pos.y))
    {
        godot::UtilityFunctions::printerr(
            "register_agent_with_id: non-finite spawn position agent=", fixed_id,
            " pos=(", pos.x, ",", pos.y, ")");
        return -1;
    }

    AgentData a;
    a.id = fixed_id;
    a.position = pos;
    a.max_speed = globalconfig().agent_max_speed;
    a.flow = flow;
    if (a.flow)
        a.flow->refcount++;
    a.active = flow != nullptr; // ✅ Inactif si pas de flow
    a.profile = sanitize_agent_profile(a.profile);
    a.debug_color = hashed_color(a.id);

    if (auto *entry = ffcore::get_global_agent_manager()->get(fixed_id))
        a.group = entry->group;
    else
    {
        godot::UtilityFunctions::print("CRITICAL: Agent ", fixed_id, " inexistant dans AgentManager");
        std::abort();
    }

    agents.push_back(a);
    id_to_index[a.id] = (int)agents.size() - 1;

    if (grid)
        grid->insert(a.id, agent_foot_point(a));

    g_goal_cooldown[a.id] = 0.0;
    recompute_hitbox_query_extents();
    /* godot::UtilityFunctions::print("Agent", a.id, " ajouté dans steering system"); */
    return a.id;
}

const AgentData *SteeringSystem::get_agent(int id) const // Retourne un agent par id
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return nullptr;
    return &agents[it->second];
}

static Vec2 project_to_navigable(FlowField *ff, const Vec2 &from, const Vec2 &to) // Trouve un point atteignable entre from et to
{
    Vec2 a = from;
    Vec2 b = to;
    if (!ff->is_cell_navigable(ff->world_to_cell(a)))
        a = ff->cell_to_world(ff->world_to_cell(a));
    if (ff->is_cell_navigable(ff->world_to_cell(b)))
        return b;

    Vec2 lo = a, hi = b;
    for (int i = 0; i < 10; ++i)
    {
        Vec2 mid = lo + (hi - lo) * 0.5;
        if (ff->is_cell_navigable(ff->world_to_cell(mid)))
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}

bool SteeringSystem::is_agent_footprint_navigable(const Vec2 &body_position, const AgentProfile &profile, FlowField *ff) const
{
    if (!ff)
        return true;

    Vec2 center = body_position + Vec2(0, profile.foot_offset_y);
    double radius = std::max(0.0, profile.world_radius);
    Vec2i center_cell = ff->world_to_cell(center);

    if (radius <= 0.0)
        return ff->is_cell_navigable(center_cell);

    const double tile = ff->tile_size();
    const double half_tile = tile * 0.5;
    const double epsilon = 1e-6;
    const int scan_radius = std::max(1, static_cast<int>(std::ceil((radius + half_tile) / tile)));

    for (int dy = -scan_radius; dy <= scan_radius; ++dy)
    {
        for (int dx = -scan_radius; dx <= scan_radius; ++dx)
        {
            Vec2i cell(center_cell.x + dx, center_cell.y + dy);
            if (ff->is_cell_navigable(cell))
                continue;

            Vec2 wall_center = ff->cell_to_world(cell);
            double distance = point_aabb_distance(center, wall_center, half_tile, half_tile);
            if (distance < radius - epsilon)
                return false;
        }
    }

    return true;
}

static bool wall_contact_normal_for_footprint(const Vec2 &body_position, const AgentProfile &profile, FlowField *ff, Vec2 &out_normal)
{
    if (!ff)
        return false;

    Vec2 center = body_position + Vec2(0, profile.foot_offset_y);
    double radius = std::max(0.0, profile.world_radius);
    if (radius <= 0.0)
        return false;

    Vec2i center_cell = ff->world_to_cell(center);
    const double tile = ff->tile_size();
    const double half_tile = tile * 0.5;
    const double epsilon = 1e-6;
    const int scan_radius = std::max(1, static_cast<int>(std::ceil((radius + half_tile) / tile)));

    Vec2 normal_sum(0, 0);
    double total_weight = 0.0;

    for (int dy = -scan_radius; dy <= scan_radius; ++dy)
    {
        for (int dx = -scan_radius; dx <= scan_radius; ++dx)
        {
            Vec2i cell(center_cell.x + dx, center_cell.y + dy);
            if (ff->is_cell_navigable(cell))
                continue;

            Vec2 wall_center = ff->cell_to_world(cell);
            Vec2 closest = closest_point_on_aabb(center, wall_center, half_tile, half_tile);
            Vec2 away = center - closest;
            double distance = safe_len(away);
            if (distance >= radius - epsilon)
                continue;

            Vec2 normal = distance > epsilon ? away * (1.0 / distance) : safe_normalize(center - wall_center);
            if (normal.is_zero())
                continue;

            double penetration = std::max(epsilon, radius - distance);
            normal_sum += normal * penetration;
            total_weight += penetration;
        }
    }

    if (total_weight <= 0.0 || normal_sum.is_zero())
        return false;

    out_normal = safe_normalize(normal_sum);
    return !out_normal.is_zero();
}

static Vec2 slide_step_against_wall(const Vec2 &step, const Vec2 &wall_normal)
{
    double into_wall = step.dot(wall_normal);
    if (into_wall >= -1e-6)
        return Vec2(0, 0);

    Vec2 slide = step - wall_normal * into_wall;
    if (slide.length_squared() < 1e-8)
        return Vec2(0, 0);
    return slide;
}

Vec2 SteeringSystem::apply_walk_with_walls(const AgentData &agent, const Vec2 &step, FlowField *ff)
{
    if (!std::isfinite(agent.position.x) || !std::isfinite(agent.position.y) || !std::isfinite(step.x) || !std::isfinite(step.y))
    {
        godot::UtilityFunctions::printerr(
            "apply_walk_with_walls: non-finite movement agent=", agent.id,
            " pos=(", agent.position.x, ",", agent.position.y, ")",
            " step=(", step.x, ",", step.y, ")");
        return agent.position;
    }

    if (!ff || (step.x == 0.0 && step.y == 0.0))
        return agent.position + step;

    const double max_step = std::max(1.0, ff->tile_size() * 0.25);
    int steps = std::max(1, static_cast<int>(std::ceil(step.length() / max_step)));
    Vec2 pos = agent.position;
    Vec2 sub_step = step * (1.0 / static_cast<double>(steps));
    const int slide_iterations = 3;
    const int sweep_iterations = 8;
    const double min_step_len2 = 1e-8;

    for (int i = 0; i < steps; ++i)
    {
        Vec2 before_slide = pos;
        Vec2 remaining = sub_step;
        bool moved_or_slid = false;

        for (int slide_iter = 0; slide_iter < slide_iterations; ++slide_iter)
        {
            if (remaining.length_squared() < min_step_len2)
                break;

            Vec2 full = pos + remaining;
            if (is_agent_footprint_navigable(full, agent.profile, ff))
            {
                pos = full;
                moved_or_slid = true;
                remaining = Vec2(0, 0);
                break;
            }

            double lo = 0.0;
            double hi = 1.0;
            for (int sweep_iter = 0; sweep_iter < sweep_iterations; ++sweep_iter)
            {
                double mid = (lo + hi) * 0.5;
                Vec2 mid_pos = pos + remaining * mid;
                if (is_agent_footprint_navigable(mid_pos, agent.profile, ff))
                    lo = mid;
                else
                    hi = mid;
            }

            if (lo > 0.0)
            {
                pos = pos + remaining * lo;
                moved_or_slid = true;
            }

            Vec2 blocked_pos = pos + remaining * (hi - lo);
            Vec2 wall_normal(0, 0);
            if (!wall_contact_normal_for_footprint(blocked_pos, agent.profile, ff, wall_normal))
                break;

            Vec2 unused_step = remaining * (1.0 - lo);
            Vec2 slide_step = slide_step_against_wall(unused_step, wall_normal);
            if (slide_step.length_squared() < min_step_len2)
                break;

            remaining = slide_step;
        }

        if (moved_or_slid)
            continue;

        pos = before_slide;

        Vec2 only_x(pos.x + sub_step.x, pos.y);
        if (sub_step.x != 0.0 && is_agent_footprint_navigable(only_x, agent.profile, ff))
        {
            pos = only_x;
            continue;
        }

        Vec2 only_y(pos.x, pos.y + sub_step.y);
        if (sub_step.y != 0.0 && is_agent_footprint_navigable(only_y, agent.profile, ff))
        {
            pos = only_y;
            continue;
        }

        break;
    }

    return pos;
}

void SteeringSystem::ultimate_wall_correction(AgentData &a, FlowField *ff, double delta)
{
    Vec2 footprint_center = agent_foot_point(a);
    Vec2i cell = ff->world_to_cell(footprint_center);
    if (is_agent_footprint_navigable(a.position, a.profile, ff))
        return;

    Vec2 wall_center = ff->cell_to_world(cell);

    // Hard clamp intégré : sécurité absolue
    Vec2i check = ff->world_to_cell(footprint_center);

    /*     godot::UtilityFunctions::print("Hard Bounce Triggered"); */

    Vec2i safe = ff->find_nearest_navigable(check);
    Vec2 safe_center = ff->cell_to_world(safe);

    Vec2 wall_normal = safe_normalize(footprint_center - wall_center);
    Vec2 tangent(-wall_normal.y, wall_normal.x);

    double softness = 0.2;
    Vec2 target_foot = safe_center + tangent * (ff->tile_size() * 0.05);
    Vec2 target = target_foot - Vec2(0, a.profile.foot_offset_y);

    // Collision murale : annuler la poussée pour éviter de re-rentrer immédiatement
    a.smash_force = Vec2(0, 0);

    a.position = a.position.lerp(target, softness);
    a.velocity = Vec2(0, 0);
    a.smash_force = Vec2(0, 0);
    a.smash_friction = -1.0;
}
// steering_system.cpp
Vec2 SteeringSystem::wall_repulsion_force(const AgentData &a, FlowField *ff)
{
    const auto &cfg = globalconfig();
    Vec2 footprint_center = agent_foot_point(a);

    if (ff && ff->has_distance_field())
    {
        Vec2i cur = ff->world_to_cell(footprint_center);
        Vec2 grad = ff->distance_gradient_at_cell(cur);
        if (!grad.is_zero())
        {
            double dist_world = static_cast<double>(ff->distance_at_cell(cur)) * ff->tile_size();
            if (dist_world < cfg.wall_avoid_radius)
            {
                double falloff = std::pow(std::max(0.0, 1.0 - dist_world / cfg.wall_avoid_radius), 2.0);
                return safe_normalize(grad) * (cfg.wall_repel_strength * falloff);
            }
        }
    }

    Vec2i cur = ff->world_to_cell(footprint_center);
    Vec2 r(0, 0);
    for (int dx = -1; dx <= 1; ++dx)
        for (int dy = -1; dy <= 1; ++dy)
        {
            if (dx == 0 && dy == 0)
                continue;
            Vec2i n{cur.x + dx, cur.y + dy};
            if (!ff->is_cell_navigable(n))
            {
                Vec2 d = footprint_center - ff->cell_to_world(n);
                double L = d.length();
                if (L < cfg.wall_avoid_radius && L > 1e-3)
                {
                    double f = std::pow(1.0 - L / cfg.wall_avoid_radius, 2.0);
                    r = r + safe_normalize(d) * f;
                }
            }
        }
    if (r.is_zero())
        return r;
    return safe_normalize(r) * cfg.wall_repel_strength;
}

Vec2 SteeringSystem::force_voisine(const AgentData &agent)
{
    const auto &cfg = globalconfig();
    if (!grid)
        return Vec2(0, 0);

    Vec2 agent_foot = agent_foot_point(agent);
    std::vector<int> neighbor_ids = grid->query_neighbors(agent_foot, agent.profile.world_radius + max_world_radius);

    struct NeighborDist
    {
        int id;
        double dist_sq;
    };
    std::vector<NeighborDist> candidates;
    candidates.reserve(neighbor_ids.size());

    for (int nid : neighbor_ids)
    {
        if (nid == agent.id)
            continue;

        auto it = id_to_index.find(nid);
        if (it == id_to_index.end())
            continue;

        const AgentData &n = agents[it->second];

        double sum_radius = agent.profile.world_radius + n.profile.world_radius;
        if (sum_radius <= 0.0)
            continue;

        Vec2 diff = agent_foot - agent_foot_point(n);
        double dist_sq = diff.length_squared();

        if (dist_sq <= sum_radius * sum_radius)
            candidates.push_back({nid, dist_sq});
    }

    std::sort(candidates.begin(), candidates.end(),
              [](const NeighborDist &a, const NeighborDist &b)
              { return a.dist_sq < b.dist_sq; });

    int limit = std::min((int)candidates.size(), cfg.max_neighbors);

    Vec2 separation_force(0, 0);
    int count = 0;

    for (int i = 0; i < limit; ++i)
    {
        auto it = id_to_index.find(candidates[i].id);
        const AgentData &n = agents[it->second];

        double sum_radius = agent.profile.world_radius + n.profile.world_radius;
        if (sum_radius <= 0.0)
            continue;

        Vec2 diff = agent_foot - agent_foot_point(n);
        double dist = diff.length();
        if (dist < 0.001)
            dist = 0.001;

        double falloff = std::pow(std::max(0.0, 1.0 - dist / sum_radius), 2.0);

        double weight = 1.0;
        double resist = std::max(0.001, agent.profile.crowd_resist_strength);
        weight *= std::max(0.0, n.profile.crowd_push_strength) / resist;

        separation_force = separation_force + (diff * (1.0 / dist)) * falloff * weight;
        count++;
    }

    if (count > 0)
        separation_force = separation_force * (1.0 / (double)count);

    if (!separation_force.is_zero())
        separation_force = safe_normalize(separation_force) * cfg.separation_strength;

    return separation_force;
}

void SteeringSystem::apply_bottleneck_traffic(AgentData &agent, FlowField *ff, Vec2 &target_velocity, double delta)
{
    (void)target_velocity;
    (void)delta;

    if (!ff)
        return;

    const auto &cfg = globalconfig();
    if (cfg.effective_debug_disable_bottlenecks())
    {
        agent.active_bottleneck = -1;
        agent.completed_bottleneck = -1;
        agent.debug_in_bottleneck_state = false;
        agent.debug_bottleneck_wait = false;
        return;
    }

    Vec2 foot = agent_foot_point(agent);
    Vec2i cell = ff->world_to_cell(foot);

    int core_index = ff->bottleneck_core_at_cell(cell);
    if (core_index >= 0)
    {
        BottleneckReservation &reservation = bottleneck_reservations[ff][core_index];
        reservation.owner_id = agent.id;
        reservation.time_left = cfg.bottleneck_reservation_seconds;
        return;
    }

    if (agent.active_bottleneck >= 0)
    {
        auto field_it = bottleneck_reservations.find(ff);
        if (field_it != bottleneck_reservations.end())
        {
            auto reservation_it = field_it->second.find(agent.active_bottleneck);
            if (reservation_it != field_it->second.end())
            {
                const BottleneckReservation &reservation = reservation_it->second;
                agent.debug_bottleneck_wait = reservation.owner_id >= 0 && reservation.owner_id != agent.id;
            }
        }
    }

    // Zone-level yielding is intentionally disabled until the reservation model
    // can choose the front-most entrant reliably. Bottleneck zones remain useful
    // for debug and later traffic-rule tuning, but must not block entry.
    return;
}

Vec2 SteeringSystem::desired_velocity_for_flow(const AgentData &agent, FlowField *ff, const Vec2 &nav_dir, const Vec2 &wall_repel, const Vec2 &separation, double target_speed) const
{
    const auto &cfg = globalconfig();
    Vec2 nav = safe_normalize(nav_dir);
    if (nav.is_zero())
    {
        Vec2 fallback = safe_normalize(wall_repel + separation);
        return fallback * target_speed;
    }

    Vec2 correction = wall_repel + separation;
    Vec2i cell = ff ? ff->world_to_cell(agent_foot_point(agent)) : Vec2i(-1, -1);
    bool in_bottleneck_area = !cfg.effective_debug_disable_bottlenecks() &&
                              ff && (ff->bottleneck_core_at_cell(cell) >= 0 || ff->bottleneck_zone_at_cell(cell) >= 0);

    if (in_bottleneck_area)
    {
        double forward = correction.dot(nav);
        Vec2 lateral = correction - nav * forward;

        if (forward < 0.0)
            forward = 0.0;

        double max_forward = cfg.flow_weight;
        double max_lateral = cfg.flow_weight * 0.6;

        if (forward > max_forward)
            forward = max_forward;

        double lateral_len = safe_len(lateral);
        if (lateral_len > max_lateral && lateral_len > 1e-6)
            lateral = lateral * (max_lateral / lateral_len);

        Vec2 desired = safe_normalize(nav * cfg.flow_weight + nav * forward + lateral);
        if (desired.is_zero())
            desired = nav;
        return desired * target_speed;
    }

    Vec2 desired = safe_normalize(correction + nav * cfg.flow_weight);
    if (desired.is_zero())
        desired = nav;
    return desired * target_speed;
}

void SteeringSystem::set_agent_flow_ptr(int id, FlowField *ff)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
    {
        godot::UtilityFunctions::print("❌ Agent ", id, " introuvable dans SteeringSystem");
        std::abort();
        return;
    }
    AgentData &a = agents[it->second];

    FlowField *old = a.flow;

    if (old)
    {
        old->refcount--;
        ffcore::cleanup_flow_if_unused(old);
    }

    a.flow = ff;

    if (ff)
        ff->refcount++; // incrément nouveau FF

    a.active = (ff != nullptr);
    a.was_in_t2 = false;
    a.target_radius_timer = 0.0;
    a.lost_timer = 0.0;
    a.active_bottleneck = -1;
    a.completed_bottleneck = -1;
    a.debug_in_bottleneck_state = false;
    a.debug_bottleneck_wait = false;

    a.dir_code = -1;
}

void SteeringSystem::set_agent_profile(int id, const AgentProfile &profile)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    AgentData &agent = agents[it->second];
    Vec2 old_foot = agent_foot_point(agent);
    agent.profile = sanitize_agent_profile(profile);
    // A valid profile max_speed overrides the global agent_max_speed for this agent.
    if (std::isfinite(agent.profile.max_speed) && agent.profile.max_speed > 0.0)
        agent.max_speed = agent.profile.max_speed;
    if (grid)
        grid->update(agent.id, old_foot, agent_foot_point(agent));
    recompute_hitbox_query_extents();
}

void SteeringSystem::set_agent_control_mode(int id, int mode)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    AgentData &a = agents[it->second];
    a.control_mode = (mode == static_cast<int>(AgentControlMode::Manual))
                         ? AgentControlMode::Manual
                         : AgentControlMode::FlowField;

    if (a.control_mode == AgentControlMode::FlowField)
    {
        a.manual_input_dir = Vec2(0, 0);
    }
    else
    {
        a.active = true;
    }
}

void SteeringSystem::set_agent_input(int id, const Vec2 &direction)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    AgentData &a = agents[it->second];
    a.manual_input_dir = safe_normalize(direction);
}

void SteeringSystem::set_agent_manual_motion(int id, double acceleration, double deceleration)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    AgentData &a = agents[it->second];
    a.manual_acceleration = std::max(0.0, acceleration);
    a.manual_deceleration = std::max(0.0, deceleration);
}

void SteeringSystem::apply_smash_impulse(int id, const Vec2 &direction, double force, double friction_loss, double delay, bool detach_flow, double control_suppression, double control_suppression_duration)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    AgentData &agent = agents[it->second];
    if (agent.profile.weapon_immune)
        return;
    if (!std::isfinite(direction.x) || !std::isfinite(direction.y) || !std::isfinite(force))
    {
        godot::UtilityFunctions::printerr(
            "apply_smash_impulse: invalid input agent=", id,
            " direction=(", direction.x, ",", direction.y, ") force=", force);
        return;
    }
    Vec2 dir = safe_normalize(direction.is_zero() ? hashed_unit_dir(agent.id) : direction);
    Vec2 smash = dir * std::max(0.0, force);

    const auto &cfg = globalconfig();
    double len = safe_len(smash);
    if (len > cfg.smash_cap)
        smash = smash * (cfg.smash_cap / len);

    agent.smash_delay = std::max(0.0, delay);
    agent.pending_smash = smash;
    agent.pending_smash_friction = std::clamp(friction_loss, 0.0, 1.0);
    agent.pending_smash_control_suppression = std::clamp(control_suppression, 0.0, 1.0);
    agent.pending_smash_control_suppression_duration = std::max(0.0, control_suppression_duration);
    agent.smash_pending = true;
    agent.smash_force = Vec2(0, 0);
    agent.smash_just_reset = false;

    agent.is_propelled = false;
    agent.propelled_timer = 0.0;

    if (!agent.active)
        agent.active = true;

    (void)detach_flow;
}

void SteeringSystem::apply_area_smash(const Vec2 &pos, double radius, const Vec2 &direction, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes)
{
    if (!std::isfinite(pos.x) || !std::isfinite(pos.y) || !std::isfinite(radius) || !std::isfinite(force))
    {
        godot::UtilityFunctions::printerr(
            "apply_area_smash: invalid input pos=(", pos.x, ",", pos.y, ") radius=", radius, " force=", force);
        return;
    }
    if (radius <= 0.0 || !grid)
        return;

    auto neighbors = grid->query_neighbors(pos, radius + max_fight_query_padding);
    if (neighbors.empty())
        return;

    double safe_falloff = std::max(0.0, falloff);
    for (int nid : neighbors)
    {
        if (nid == ignored_agent_id)
            continue;

        auto it = id_to_index.find(nid);
        if (it == id_to_index.end())
            continue;

        const AgentData &agent = agents[it->second];
        if (agent.profile.weapon_immune)
            continue;
        if (affected_smash_classes != 0 && (agent.profile.smash_class & affected_smash_classes) == 0)
            continue;

        Vec2 fight_center = agent_fight_center(agent);
        double dist = point_aabb_distance(pos, fight_center, agent.profile.fight_half_w, agent.profile.fight_half_h);
        if (dist > radius)
            continue;

        double base = std::max(0.0, 1.0 - dist / radius);
        double attenuation = std::pow(base, safe_falloff);
        apply_smash_impulse(nid, direction, force * attenuation, friction_loss, 0.0, detach_flow, control_suppression, control_suppression_duration);
    }
}

void SteeringSystem::apply_cone_smash(const Vec2 &pos, double radius, const Vec2 &direction, double angle_degrees, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes)
{
    if (!std::isfinite(pos.x) || !std::isfinite(pos.y) || !std::isfinite(radius) || !std::isfinite(direction.x) || !std::isfinite(direction.y) || !std::isfinite(force))
    {
        godot::UtilityFunctions::printerr(
            "apply_cone_smash: invalid input pos=(", pos.x, ",", pos.y, ")",
            " direction=(", direction.x, ",", direction.y, ") radius=", radius, " force=", force);
        return;
    }
    if (radius <= 0.0 || !grid)
        return;

    Vec2 facing = safe_normalize(direction);
    if (facing.is_zero())
        return;

    auto neighbors = grid->query_neighbors(pos, radius + max_fight_query_padding);
    if (neighbors.empty())
        return;

    double half_angle = std::clamp(angle_degrees, 0.0, 360.0) * 0.5;
    double min_dot = std::cos(half_angle * 3.14159265358979323846 / 180.0);
    double safe_falloff = std::max(0.0, falloff);

    for (int nid : neighbors)
    {
        if (nid == ignored_agent_id)
            continue;

        auto it = id_to_index.find(nid);
        if (it == id_to_index.end())
            continue;

        const AgentData &agent = agents[it->second];
        if (agent.profile.weapon_immune)
            continue;
        if (affected_smash_classes != 0 && (agent.profile.smash_class & affected_smash_classes) == 0)
            continue;

        Vec2 fight_center = agent_fight_center(agent);
        Vec2 nearest = closest_point_on_aabb(pos, fight_center, agent.profile.fight_half_w, agent.profile.fight_half_h);
        Vec2 to_agent = nearest - pos;
        double dist = to_agent.length();
        if (dist > radius)
            continue;

        if (angle_degrees < 360.0 && dist > 1e-3)
        {
            Vec2 angle_dir = to_agent.is_zero() ? fight_center - pos : to_agent;
            if (!angle_dir.is_zero() && safe_normalize(angle_dir).dot(facing) < min_dot)
                continue;
        }

        double base = std::max(0.0, 1.0 - dist / radius);
        double attenuation = std::pow(base, safe_falloff);
        apply_smash_impulse(nid, facing, force * attenuation, friction_loss, 0.0, detach_flow, control_suppression, control_suppression_duration);
    }
}

void SteeringSystem::apply_explosion(const Vec2 &pos, double radius, double intensity, double friction_loss)
{
    apply_explosion_filtered(pos, radius, intensity, friction_loss, globalconfig().explosion_falloff, -1, 1.0, globalconfig().propelled_duration, 0);
}

void SteeringSystem::apply_explosion_filtered(const Vec2 &pos, double radius, double intensity, double friction_loss, double falloff, int ignored_agent_id, double control_suppression, double control_suppression_duration, int affected_smash_classes)
{
    if (!std::isfinite(pos.x) || !std::isfinite(pos.y) || !std::isfinite(radius) || !std::isfinite(intensity))
    {
        godot::UtilityFunctions::printerr(
            "apply_explosion_filtered: invalid input pos=(", pos.x, ",", pos.y, ") radius=", radius, " intensity=", intensity);
        return;
    }
    if (radius <= 0.0 || !grid)
        return;

    auto neighbors = grid->query_neighbors(pos, radius + max_fight_query_padding);
    if (neighbors.empty())
        return;

    double safe_falloff = std::max(0.0, falloff);
    for (int nid : neighbors)
    {
        if (nid == ignored_agent_id)
            continue;

        auto it = id_to_index.find(nid);
        if (it == id_to_index.end())
            continue;

        AgentData &agent = agents[it->second];
        if (agent.profile.weapon_immune)
            continue;
        if (affected_smash_classes != 0 && (agent.profile.smash_class & affected_smash_classes) == 0)
            continue;

        Vec2 diff = aabb_radial_direction(pos, agent);
        double dist = point_aabb_distance(pos, agent_fight_center(agent), agent.profile.fight_half_w, agent.profile.fight_half_h);
        if (dist > radius)
            continue;

        Vec2 dir = safe_normalize(diff.is_zero() ? hashed_unit_dir(agent.id) : diff);
        double base = std::max(0.0, 1.0 - dist / radius);
        double attenuation = std::pow(base, safe_falloff);

        apply_smash_impulse(nid, dir, intensity * attenuation, friction_loss, 0.0, true, control_suppression, control_suppression_duration);
    }
}

void SteeringSystem::spawn_aoe_zone(const Vec2 &pos, const Vec2 &direction, double radius, double angle_degrees, double duration, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes, const Vec2 &follow_offset)
{
    if (!std::isfinite(pos.x) || !std::isfinite(pos.y) || !std::isfinite(direction.x) || !std::isfinite(direction.y) || !std::isfinite(radius) || !std::isfinite(duration) || !std::isfinite(force) || !std::isfinite(follow_offset.x) || !std::isfinite(follow_offset.y))
    {
        godot::UtilityFunctions::printerr(
            "spawn_aoe_zone: invalid input pos=(", pos.x, ",", pos.y, ")",
            " direction=(", direction.x, ",", direction.y, ")",
            " radius=", radius, " duration=", duration, " force=", force,
            " follow_offset=(", follow_offset.x, ",", follow_offset.y, ")");
        return;
    }
    if (radius <= 0.0 || duration <= 0.0)
        return;

    ActiveAoE zone;
    zone.pos = pos;
    zone.follow_offset = follow_offset;
    double clamped_angle = std::clamp(angle_degrees, 0.0, 360.0);
    if (clamped_angle < 360.0)
    {
        Vec2 facing = safe_normalize(direction);
        if (facing.is_zero())
            return;
        zone.direction = facing;
    }
    else
    {
        zone.direction = Vec2(0, 0);
    }
    zone.radius = radius;
    zone.angle_degrees = clamped_angle;
    zone.force = force;
    zone.friction_loss = friction_loss;
    zone.falloff = std::max(0.0, falloff);
    zone.detach_flow = detach_flow;
    zone.control_suppression = control_suppression;
    zone.control_suppression_duration = control_suppression_duration;
    zone.ignored_agent_id = ignored_agent_id;
    zone.owner_id = ignored_agent_id; // the swing's source agent: zone follows it while alive
    zone.affected_smash_classes = affected_smash_classes;
    zone.time_left = duration;

    active_aoes.push_back(std::move(zone));
}

void SteeringSystem::set_agent_never_rest(int id, bool value)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    agents[it->second].never_rest = value;
}

void SteeringSystem::set_agent_phase(int id, AgentPhase phase, float eating_seconds)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    AgentData &a = agents[it->second];
    a.phase = phase;
    a.eating_seconds = eating_seconds;
}

void SteeringSystem::set_agent_path(int id, const std::vector<Vec2> &waypoints_world)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    AgentData &a = agents[it->second];
    a.path_waypoints = waypoints_world;
    a.path_index = 0;
    a.path_active = !waypoints_world.empty();
    a.path_arrived = waypoints_world.empty();
    a.active = true;
    a.lost_timer = 0.0;
    a.target_radius_timer = 0.0;
    a.active_bottleneck = -1;
    a.completed_bottleneck = -1;
}

void SteeringSystem::clear_agent_path(int id)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    AgentData &a = agents[it->second];
    a.path_waypoints.clear();
    a.path_index = 0;
    a.path_active = false;
    a.path_arrived = false;
}

bool SteeringSystem::agent_path_arrived(int id) const
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return false;
    return agents[it->second].path_arrived;
}

void SteeringSystem::update_all(double delta)
{
    if (agents.empty())
        return;
    if (!grid)
        return;

    const auto &cfg = globalconfig();

    // friction_factor = taux de perte de vitesse par seconde (1.0 => 100 % perdu en 1s)
    double loss_per_sec = std::clamp(cfg.friction_factor, 0.0, 1.0);

    for (auto &field_entry : bottleneck_reservations)
    {
        for (auto &reservation_entry : field_entry.second)
        {
            BottleneckReservation &reservation = reservation_entry.second;
            if (reservation.owner_id >= 0)
            {
                reservation.time_left -= delta;
                if (reservation.time_left <= 0.0)
                    reservation.owner_id = -1;
            }
        }
    }

    for (auto &zone : active_aoes)
    {
        // Zone follows its owner: re-read the source agent's live position each tick so the
        // hitbox sweeps with the player. If the owner despawned, keep the last known position.
        if (zone.owner_id >= 0)
        {
            auto owner_it = id_to_index.find(zone.owner_id);
            if (owner_it != id_to_index.end())
                zone.pos = agents[owner_it->second].position + zone.follow_offset;
        }
        auto neighbors = grid->query_neighbors(zone.pos, zone.radius + max_fight_query_padding);
        for (int nid : neighbors)
        {
            if (nid == zone.ignored_agent_id)
                continue;
            if (zone.hit_ids.count(nid) != 0)
                continue;

            auto it = id_to_index.find(nid);
            if (it == id_to_index.end())
                continue;

            AgentData &agent = agents[it->second];
            if (agent.profile.weapon_immune)
                continue;
            if (zone.affected_smash_classes != 0 && (agent.profile.smash_class & zone.affected_smash_classes) == 0)
                continue;

            Vec2 diff = aabb_radial_direction(zone.pos, agent);
            Vec2 fight_center = agent_fight_center(agent);
            double dist = point_aabb_distance(zone.pos, fight_center, agent.profile.fight_half_w, agent.profile.fight_half_h);
            if (dist > zone.radius)
                continue;

            Vec2 impulse_dir;
            if (zone.angle_degrees >= 360.0)
            {
                impulse_dir = safe_normalize(diff.is_zero() ? hashed_unit_dir(agent.id) : diff);
            }
            else
            {
                double half_angle = zone.angle_degrees * 0.5;
                double min_dot = std::cos(half_angle * 3.14159265358979323846 / 180.0);
                Vec2 nearest = closest_point_on_aabb(zone.pos, fight_center, agent.profile.fight_half_w, agent.profile.fight_half_h);
                Vec2 angle_dir = nearest - zone.pos;
                if (angle_dir.is_zero())
                    angle_dir = fight_center - zone.pos;
                if (dist > 1e-3 && !angle_dir.is_zero() && safe_normalize(angle_dir).dot(zone.direction) < min_dot)
                    continue;
                impulse_dir = zone.direction;
            }

            double base = std::max(0.0, 1.0 - dist / zone.radius);
            double attenuation = std::pow(base, zone.falloff);

            apply_smash_impulse(nid, impulse_dir, zone.force * attenuation, zone.friction_loss, 0.0, zone.detach_flow, zone.control_suppression, zone.control_suppression_duration);
            zone.hit_ids.insert(nid);
        }

        zone.time_left -= delta;
    }
    active_aoes.erase(std::remove_if(active_aoes.begin(), active_aoes.end(),
                                     [](const ActiveAoE &z) { return z.time_left <= 0.0; }),
                      active_aoes.end());

    for (auto &a : agents)
    {
        if (a.smash_pending)
        {
            a.smash_delay -= delta;
            if (a.smash_delay <= 0.0)
            {
                a.smash_force = a.pending_smash;
                a.pending_smash = Vec2(0, 0);
                a.smash_friction = a.pending_smash_friction;
                a.pending_smash_friction = -1.0;
                a.smash_control_suppression = a.pending_smash_control_suppression;
                a.pending_smash_control_suppression = 1.0;
                a.smash_control_suppression_timer = a.pending_smash_control_suppression_duration;
                a.pending_smash_control_suppression_duration = 0.0;
                a.smash_pending = false;
                a.smash_just_reset = true;
            }
        }
    }

    for (auto &a : agents)
    {
        if (a.smash_control_suppression_timer > 0.0)
            a.smash_control_suppression_timer = std::max(0.0, a.smash_control_suppression_timer - delta);

        if (a.smash_just_reset)
        {
            a.smash_just_reset = false;
            if (!a.smash_force.is_zero())
            {
                a.velocity = a.smash_force; // impulsion initiale
                a.is_propelled = true;
                a.propelled_timer = cfg.propelled_duration;
            }
            a.smash_force = Vec2(0, 0);
        }
        else if (a.is_propelled)
        {
            double loss = (a.smash_friction >= 0.0) ? std::clamp(a.smash_friction, 0.0, 1.0) : loss_per_sec;
            double vel_damp = std::pow(1.0 - loss, delta);
            a.velocity = a.velocity * vel_damp; // dissipation sur la vitesse
            a.propelled_timer -= delta;

            double vlen = safe_len(a.velocity);
            if (a.propelled_timer <= 0.0 || vlen < cfg.smash_min_cutoff)
            {
                a.is_propelled = false;
                a.propelled_timer = 0.0;
                a.smash_force = Vec2(0, 0);
                a.smash_friction = -1.0;
                a.smash_control_suppression = 1.0;
                a.smash_control_suppression_timer = 0.0;
                a.velocity = Vec2(0, 0);
            }
        }
        else
        {
            a.smash_force = Vec2(0, 0);
        }
    }

    for (auto &a : agents)
    {
        const bool is_manual = a.control_mode == AgentControlMode::Manual;
        FlowField *nav = a.flow ? a.flow : default_flow;
        if (nav && !nav->is_ready())
            nav = nullptr;

        bool force_motion_state = false;

        Vec2 wall_repel(0, 0);
        if (nav)
            wall_repel = wall_repulsion_force(a, nav);

        Vec2 separation = force_voisine(a);

        const auto &cfg = globalconfig();
        Vec2 offset(0, a.profile.foot_offset_y);
        double active_control_suppression = (a.is_propelled && a.smash_control_suppression_timer > 0.0) ? std::clamp(a.smash_control_suppression, 0.0, 1.0) : 0.0;
        double smash_control_factor = a.is_propelled ? (1.0 - active_control_suppression) : 1.0;

        // Path-follow branch: desired direction comes from the path's current waypoint,
        // not the flow field. wall_repel/separation/smash physics still apply.
        if (a.path_active && a.control_mode != AgentControlMode::Manual)
        {
            // Advance waypoint while close enough to the current one.
            const double waypoint_radius = (nav ? nav->tile_size() : cfg.tile_size) * 0.5;
            const Vec2 foot = a.position + offset;
            while (a.path_index < (int)a.path_waypoints.size())
            {
                Vec2 to_wp = a.path_waypoints[a.path_index] - foot;
                if (safe_len(to_wp) <= waypoint_radius)
                    a.path_index++;
                else
                    break;
            }

            if (a.path_index >= (int)a.path_waypoints.size())
            {
                a.path_active = false;
                a.path_arrived = true;
                if (!a.is_propelled)
                {
                    Vec2 target_velocity = Vec2(0, 0);
                    a.velocity = a.velocity.lerp(target_velocity, cfg.lerp_general);
                }
                Vec2 old_pos = a.position;
                Vec2 step = a.velocity * delta;
                a.position = apply_walk_with_walls(a, step, nav);
                if (nav)
                    ultimate_wall_correction(a, nav, delta);
                grid->update(a.id, old_pos + offset, agent_foot_point(a));
                a.update_motion_state(delta, cfg);
                continue;
            }

            Vec2 to_wp = a.path_waypoints[a.path_index] - foot;
            Vec2 nav_dir = safe_normalize(to_wp);

            Vec2 target_velocity = desired_velocity_for_flow(a, nav, nav_dir, wall_repel, separation, a.max_speed);
            Vec2 desired_dir = safe_normalize(target_velocity);
            if (desired_dir.is_zero())
                desired_dir = nav_dir;

            a.debug_nav_dir = nav_dir;
            a.debug_wall_repel = wall_repel;
            a.debug_separation = separation;
            a.debug_desired_dir = desired_dir;
            a.debug_target_velocity = target_velocity;

            if (!a.is_propelled)
            {
                a.velocity = a.velocity.lerp(target_velocity, cfg.lerp_general);
                double vlen = safe_len(a.velocity);
                if (vlen > a.max_speed)
                    a.velocity = a.velocity * (a.max_speed / vlen);
            }

            Vec2 old_pos = a.position;
            Vec2 move_velocity = a.is_propelled ? a.velocity + target_velocity * smash_control_factor : a.velocity;
            Vec2 step = move_velocity * delta;
            a.position = apply_walk_with_walls(a, step, nav);
            if (nav)
                ultimate_wall_correction(a, nav, delta);
            grid->update(a.id, old_pos + offset, agent_foot_point(a));
            a.update_motion_state(delta, cfg);
            continue;
        }

        if (!a.active || !a.flow)
        {
            if (a.control_mode == AgentControlMode::Manual)
            {
                Vec2 manual_dir = safe_normalize(a.manual_input_dir);
                Vec2 correction = separation;
                Vec2 target_velocity = manual_dir.is_zero()
                                           ? safe_normalize(correction) * a.max_speed * cfg.min_speed_fraction
                                           : manual_dir * a.max_speed + correction;
                if (!a.is_propelled)
                {
                    double accel = manual_dir.is_zero() ? a.manual_deceleration : a.manual_acceleration;
                    a.velocity = move_toward_vec(a.velocity, target_velocity, accel * delta);
                }

                if (!a.is_propelled)
                {
                    double vlen = safe_len(a.velocity);
                    if (vlen > a.max_speed)
                        a.velocity = a.velocity * (a.max_speed / vlen);
                }

                Vec2 old_pos = a.position;
                Vec2 move_velocity = a.is_propelled ? a.velocity + target_velocity * smash_control_factor : a.velocity;
                Vec2 step = move_velocity * delta;
                Vec2 new_pos = apply_walk_with_walls(a, step, nav);
                a.position = new_pos;

                if (nav)
                    ultimate_wall_correction(a, nav, delta);

                grid->update(a.id, old_pos + offset, agent_foot_point(a));
                a.update_motion_state(delta, cfg);
                continue;
            }

            if (!a.is_propelled)
            {
                Vec2 combined = wall_repel + separation;

                Vec2 local_dir = safe_normalize(combined);
                if (local_dir.is_zero())
                {
                    /*  godot::UtilityFunctions::print("Agent dont recevied force"); */
                    Vec2 target_velocity = Vec2(0, 0);
                    a.velocity = a.velocity.lerp(target_velocity, cfg.lerp_general);
                    a.update_motion_state(delta, cfg);
                    continue;
                }
                Vec2 target_velocity = local_dir * a.max_speed * cfg.min_speed_fraction; /// velocity if moved by others
                /*   Vec2 target_velocity = Vec2(0, 0); */
                a.velocity = a.velocity.lerp(target_velocity, cfg.lerp_general);
            }
            // si propulsé, on conserve la velocity existante (déjà amortie)

            Vec2 old_pos = a.position;
            Vec2 step = a.velocity * delta;
            a.position = apply_walk_with_walls(a, step, nav);

            if (nav)
                ultimate_wall_correction(a, nav, delta);

            grid->update(a.id, old_pos + offset, agent_foot_point(a));
            a.update_motion_state(delta, cfg);
            continue;
        }

        if (a.control_mode == AgentControlMode::Manual)
        {
            Vec2 manual_dir = safe_normalize(a.manual_input_dir);
            Vec2 correction = separation;
            Vec2 target_velocity = manual_dir.is_zero()
                                       ? safe_normalize(correction) * a.max_speed * cfg.min_speed_fraction
                                       : manual_dir * a.max_speed + correction;
            if (!a.is_propelled)
            {
                double accel = manual_dir.is_zero() ? a.manual_deceleration : a.manual_acceleration;
                a.velocity = move_toward_vec(a.velocity, target_velocity, accel * delta);
            }

            if (!a.is_propelled)
            {
                double vlen = safe_len(a.velocity);
                if (vlen > a.max_speed)
                    a.velocity = a.velocity * (a.max_speed / vlen);
            }

            Vec2 old_pos = a.position;
            Vec2 move_velocity = a.is_propelled ? a.velocity + target_velocity * smash_control_factor : a.velocity;
            Vec2 step = move_velocity * delta;
            Vec2 new_pos = apply_walk_with_walls(a, step, nav);
            a.position = new_pos;

            if (nav)
                ultimate_wall_correction(a, nav, delta);

            grid->update(a.id, old_pos + offset, agent_foot_point(a));
            a.update_motion_state(delta, cfg);
            continue;
        }

        FlowField *ff = a.flow;
        if (!ff || !ff->is_ready())
        {
            Vec2 target_velocity = Vec2(0, 0);
            a.velocity = a.velocity.lerp(target_velocity, cfg.lerp_general);
            a.update_motion_state(delta, cfg);
            continue;
        }

        if (a.lost_timer > 0.0)
        {
            a.lost_timer = std::max(0.0, a.lost_timer - delta);
            a.velocity = a.velocity.lerp(Vec2(0, 0), cfg.lerp_general);
            a.update_motion_state(delta, cfg);
            continue;
        }

        Vec2 goal_pos = ff->goal_center_world();
        Vec2 to_goal = goal_pos - (a.position + offset);
        double dist_to_target = safe_len(to_goal);
        double target_radius = ff->get_ff_target_radius();
        if (target_radius > 0.0 && !a.never_rest)
        {
            int group_size = 0;
            if (a.group != INVALID_GROUP)
            {
                if (auto *mgr = ffcore::get_global_agent_manager())
                    group_size = mgr->count_group_members(a.group);
            }

            if (group_size <= 2 && dist_to_target <= ff->tile_size() * 0.5)
            {
                a.reset();
                force_motion_state = true;
                continue;
            }

            if (dist_to_target <= target_radius && a.target_radius_timer <= 0.0)
            {
                a.target_radius_timer =
                    cfg.target_radius_time_before_stop + group_size * cfg.target_radius_time_group_size_ratio;
            }

            if (a.target_radius_timer > 0.0)
            {
                a.target_radius_timer -= delta;
                if (a.target_radius_timer <= 0.0)
                {
                    a.reset();
                    force_motion_state = true;
                    continue;
                }
            }
        }

        Vec2 sample_pos = a.position + offset;
        if (!std::isfinite(sample_pos.x) || !std::isfinite(sample_pos.y))
        {
            godot::UtilityFunctions::printerr(
                "SteeringSystem::update_all: non-finite flow sample agent=", a.id,
                " group=", a.group,
                " pos=(", a.position.x, ",", a.position.y, ")",
                " offset=(", offset.x, ",", offset.y, ")",
                " velocity=(", a.velocity.x, ",", a.velocity.y, ")",
                " flow=", ff != nullptr);
            a.velocity = Vec2(0, 0);
            a.update_motion_state(delta, cfg, true);
            continue;
        }

        Vec2i rel_cell = ff->world_to_cell(sample_pos);
        Vec2i map_cell(rel_cell.x + ff->get_cell_origin().x, rel_cell.y + ff->get_cell_origin().y);
        a.debug_bottleneck_core = ff->bottleneck_core_at_cell(rel_cell);
        a.debug_bottleneck_zone = ff->bottleneck_zone_at_cell(rel_cell);
        a.debug_bottleneck_wait = false;
        if (map_cell != a.last_logged_tile)
        {
            a.last_logged_tile = map_cell;
        }
        Vec2 flow_dir = safe_normalize(ff->compute_flow_dir(sample_pos));
        const double lost_goal_margin = std::max(ff->tile_size() * 0.5, target_radius);
        if (flow_dir.is_zero() && dist_to_target > lost_goal_margin)
        {
            a.lost_timer = std::max(0.0, cfg.lost_retry_seconds);
            a.velocity = Vec2(0, 0);
            a.update_motion_state(delta, cfg, true);
            continue;
        }
        Vec2 nav_dir = flow_dir.is_zero() ? safe_normalize(to_goal) : flow_dir;
        if (!flow_dir.is_zero())
        {
            int step_x = static_cast<int>(std::round(flow_dir.x));
            int step_y = static_cast<int>(std::round(flow_dir.y));
            Vec2i next_cell(rel_cell.x + step_x, rel_cell.y + step_y);
            if (ff->is_cell_navigable(next_cell))
            {
                Vec2 next_center = ff->cell_to_world(next_cell);
                Vec2 center_dir = safe_normalize(next_center - (a.position + offset));
                if (!center_dir.is_zero())
                    nav_dir = center_dir;
            }
        }

        if (cfg.effective_debug_disable_bottlenecks())
        {
            a.active_bottleneck = -1;
            a.completed_bottleneck = -1;
            a.debug_in_bottleneck_state = false;
            a.debug_bottleneck_wait = false;
        }
        else
        {
            int next_bottleneck = ff->next_bottleneck_at_cell(rel_cell);
            if (next_bottleneck != a.completed_bottleneck)
                a.completed_bottleneck = -1;

            if (a.active_bottleneck >= 0)
            {
                const BottleneckInfo *active = ff->bottleneck_at(a.active_bottleneck);
                double current_cost = ff->route_cost_at_cell(rel_cell);
                bool close_enough_to_door = false;
                if (active)
                {
                    Vec2 door_center = ff->cell_to_world(active->cell);
                    double release_radius = ff->tile_size() * 0.5;
                    close_enough_to_door = safe_len(door_center - (a.position + offset)) <= release_radius;
                }

                if (!active || current_cost < active->route_cost || close_enough_to_door)
                {
                    if (active)
                        a.completed_bottleneck = a.active_bottleneck;
                    a.active_bottleneck = -1;
                }
            }

            if (a.active_bottleneck < 0)
            {
                const BottleneckInfo *next = ff->bottleneck_at(next_bottleneck);
                if (next && next_bottleneck != a.completed_bottleneck)
                {
                    double current_cost = ff->route_cost_at_cell(rel_cell);
                    if (current_cost >= next->route_cost)
                        a.active_bottleneck = next_bottleneck;
                }
            }

            a.debug_in_bottleneck_state = a.active_bottleneck >= 0;
            if (a.active_bottleneck >= 0)
            {
                const BottleneckInfo *active = ff->bottleneck_at(a.active_bottleneck);
                if (active)
                {
                    Vec2 door_center = ff->cell_to_world(active->cell);
                    Vec2 to_door = door_center - (a.position + offset);
                    Vec2 door_dir = safe_normalize(to_door);
                    if (!door_dir.is_zero())
                        nav_dir = door_dir;
                }
            }
        }

        double t2_speed_target = a.max_speed * std::clamp(cfg.target_T2_param_speed_ratio, 0.0, 1.0);
        double t2_speed_lerp = std::clamp(cfg.target_T2_param_speed_lerp, 0.0, 1.0);

        bool in_t2_zone = target_radius > 0.0 && dist_to_target <= target_radius;

        Vec2 target_velocity;
        Vec2 desired_dir;
        {
            double target_speed = a.max_speed;
            if (in_t2_zone)
            {
                double current_speed = safe_len(a.velocity);
                double desired = current_speed + (t2_speed_target - current_speed) * t2_speed_lerp;
                if (current_speed > t2_speed_target)
                    target_speed = std::max(t2_speed_target, desired);
                else
                    target_speed = t2_speed_target;
            }
            target_velocity = desired_velocity_for_flow(a, ff, nav_dir, wall_repel, separation, target_speed);
            desired_dir = safe_normalize(target_velocity);
            if (desired_dir.is_zero() && dist_to_target > 0.0)
                desired_dir = safe_normalize(to_goal);
        }

        a.debug_nav_dir = nav_dir;
        a.debug_wall_repel = wall_repel;
        a.debug_separation = separation;
        a.debug_desired_dir = desired_dir;
        a.debug_target_velocity = target_velocity;

        // Wall-stuck detector: wants to move into geometry it can't traverse.
        // Crowd-throttled agents (separation dominates) are intentionally ignored.
        if (!a.is_propelled && !desired_dir.is_zero() && cfg.wall_stuck_detect_seconds > 0.0)
        {
            double wall_mag = safe_len(wall_repel);
            double sep_mag = safe_len(separation);
            double v_along = a.velocity.x * desired_dir.x + a.velocity.y * desired_dir.y;
            bool not_progressing = v_along < a.max_speed * cfg.wall_stuck_velocity_ratio;
            bool wall_dominates = wall_mag > cfg.wall_stuck_wall_vs_sep_ratio * sep_mag && wall_mag > 1e-3;
            if (not_progressing && wall_dominates)
            {
                a.stuck_in_wall_accum += delta;
                if (a.stuck_in_wall_accum >= cfg.wall_stuck_detect_seconds)
                {
                    a.lost_timer = std::max(0.0, cfg.lost_retry_seconds);
                    a.stuck_in_wall_accum = 0.0;
                    a.velocity = Vec2(0, 0);
                    a.update_motion_state(delta, cfg, true);
                    continue;
                }
            }
            else
            {
                a.stuck_in_wall_accum = 0.0;
            }
        }
        else
        {
            a.stuck_in_wall_accum = 0.0;
        }

        apply_bottleneck_traffic(a, ff, target_velocity, delta);

        if (!a.is_propelled)
        {
            double blend = in_t2_zone ? t2_speed_lerp : cfg.lerp_general;
            blend = std::clamp(blend, 0.0, 1.0);
            a.velocity = a.velocity.lerp(target_velocity, blend);
        }

        if (!a.is_propelled)
        {
            double vlen = safe_len(a.velocity);
            if (vlen > a.max_speed)
                a.velocity = a.velocity * (a.max_speed / vlen);
        }

        Vec2 old_pos = a.position;
        Vec2 move_velocity = a.is_propelled ? a.velocity + target_velocity * smash_control_factor : a.velocity;
        Vec2 step = move_velocity * delta;
        a.position = apply_walk_with_walls(a, step, ff);

        ultimate_wall_correction(a, ff, delta);

        grid->update(a.id, old_pos + offset, agent_foot_point(a));

        a.update_motion_state(delta, cfg, force_motion_state);

    }
}
