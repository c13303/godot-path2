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

static inline double clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); } // Limite v entre 0 et 1

/* declaration generale du system pour partage */
static SteeringSystem *g_steering = nullptr;
SteeringSystem *ffcore::get_global_steering_system() { return g_steering; }
SteeringSystem::SteeringSystem()
{

    g_steering = this;
}

static inline Vec2 safe_normalize(const Vec2 &v) // Normalise un vecteur, évite la division par zéro
{
    double l = v.length();
    if (l < 1e-6)
        return Vec2(0, 0);
    return v * (1.0 / l);
}

static inline double safe_len(const Vec2 &v) // Renvoie la longueur d’un vecteur, évite les très petites valeurs
{
    double l = v.length();
    return (l < 1e-6) ? 0.0 : l;
}

static inline Vec2 hashed_unit_dir(int id) // Génère une direction pseudo-aléatoire stable basée sur un id
{
    unsigned h = (unsigned)id * 1664525u + 1013904223u;
    double a = (h & 0xFFFFu) / 65535.0 * 6.28318530718;
    return Vec2(std::cos(a), std::sin(a));
}

static std::unordered_map<int, double> g_goal_cooldown; // Cooldown global pour les agents autour des objectifs

int SteeringSystem::register_agent(const Vec2 &pos, double max_speed, FlowField *flow) // Enregistre un agent
{
    AgentData a;
    a.id = next_id++;
    a.position = pos;
    a.max_speed = max_speed;
    a.flow = flow ? flow : default_flow;
    agents.push_back(a);
    id_to_index[a.id] = (int)agents.size() - 1;
    if (grid)
        grid->insert(a.id, pos);
    g_goal_cooldown[a.id] = 0.0;
    return a.id;
}

void SteeringSystem::unregister_agent(int id) // Supprime un agent
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    int idx = it->second;
    if (grid)
        grid->remove(id);

    int last = (int)agents.size() - 1;
    if (idx != last)
    {
        agents[idx] = agents[last];
        id_to_index[agents[idx].id] = idx;
    }
    agents.pop_back();
    id_to_index.erase(it);
    g_goal_cooldown.erase(id);
}

void SteeringSystem::reactivate_agents_for_field(FlowField *field)
{
    for (auto &a : agents)
    {
        if (a.flow != field)
            continue;
        a.active = true;
        a.has_arrived = false;
        a.is_first = false;
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
    AgentData a;
    a.id = fixed_id;
    a.position = pos;
    a.max_speed = max_speed;
    a.flow = flow;
    a.active = flow != nullptr; // ✅ Inactif si pas de flow

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
        grid->insert(a.id, pos);

    g_goal_cooldown[a.id] = 0.0;
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

void SteeringSystem::ultimate_wall_correction(AgentData &a, FlowField *ff, double delta)
{
    Vec2i cell = ff->world_to_cell(a.position);
    if (ff->is_cell_navigable(cell))
        return;

    Vec2i best_cell = ff->find_nearest_navigable(cell);
    Vec2 wall_center = ff->cell_to_world(cell);
    Vec2 free_center = ff->cell_to_world(best_cell);
    Vec2 dir = safe_normalize(free_center - wall_center);

    // Hard clamp intégré : sécurité absolue
    Vec2i check = ff->world_to_cell(a.position);

    /*     godot::UtilityFunctions::print("Hard Bounce Triggered"); */

    Vec2i safe = ff->find_nearest_navigable(check);
    Vec2 safe_center = ff->cell_to_world(safe);

    Vec2 wall_normal = safe_normalize(a.position - wall_center);
    Vec2 tangent(-wall_normal.y, wall_normal.x);

    double softness = 0.2;
    Vec2 target = safe_center + tangent * (ff->tile_size() * 0.05);

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
    Vec2i cur = ff->world_to_cell(a.position);
    Vec2 r(0, 0);
    for (int dx = -1; dx <= 1; ++dx)
        for (int dy = -1; dy <= 1; ++dy)
        {
            if (dx == 0 && dy == 0)
                continue;
            Vec2i n{cur.x + dx, cur.y + dy};
            if (!ff->is_cell_navigable(n))
            {
                Vec2 d = a.position - ff->cell_to_world(n);
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

    std::vector<int> neighbor_ids = grid->query_neighbors(agent.position, cfg.separation_radius);

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

        Vec2 diff = agent.position - n.position;
        double dist_sq = diff.length_squared();

        if (dist_sq <= cfg.separation_radius * cfg.separation_radius)
            candidates.push_back({nid, dist_sq});
    }

    std::sort(candidates.begin(), candidates.end(),
              [](const NeighborDist &a, const NeighborDist &b)
              { return a.dist_sq < b.dist_sq; });

    int limit = std::min((int)candidates.size(), cfg.max_neighbors);

    Vec2 separation_force(0, 0);
    int count = 0;

    bool self_has_flow = (agent.flow != nullptr);

    for (int i = 0; i < limit; ++i)
    {
        auto it = id_to_index.find(candidates[i].id);
        const AgentData &n = agents[it->second];

        Vec2 diff = agent.position - n.position;
        double dist = diff.length();
        if (dist < 0.001)
            dist = 0.001;

        double falloff = std::pow(std::max(0.0, 1.0 - dist / cfg.separation_radius), 2.0);

        bool other_has_flow = (n.flow != nullptr);

        double weight = 1.0;
        if (self_has_flow && !other_has_flow)
            weight *= 2.0;
        if (!self_has_flow && other_has_flow)
            weight *= 0.5;

        separation_force = separation_force + (diff * (1.0 / dist)) * falloff * weight;
        count++;
    }

    if (count > 0)
        separation_force = separation_force * (1.0 / (double)count);

    if (!separation_force.is_zero())
        separation_force = safe_normalize(separation_force) * cfg.separation_strength;

    return separation_force;
}

void SteeringSystem::smooth_stop(int id)
{

    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    AgentData &a = agents[it->second];

    if (!a.active)
        return;

    a.velocity = Vec2(0, 0);

    /// TODO actual smooth instead of violent
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
    // Reset arrival state when assigning a new flow so agents can arrive again.
    if (ff != nullptr)
    {
        a.has_arrived = false;
        a.is_first = false;
    }
    else
    {
        // Clearing flow also clears arrival flags so future orders can trigger correctly.
        a.has_arrived = false;
        a.is_first = false;
    }
}

void SteeringSystem::apply_explosion(const Vec2 &pos, double radius, double intensity, double friction_loss)
{
    if (radius <= 0.0 || !grid)
        return;

    const auto &cfg = globalconfig();
    auto neighbors = grid->query_neighbors(pos, radius);
    if (neighbors.empty())
        return;

    double stop_radius = radius * std::max(0.0, cfg.shockwave_stop_ratio);
    double stop_time_ms = std::max(0.0, cfg.shockwave_stop_duration_ms);
    if (stop_radius > 0.0 && stop_time_ms > 0.0)
        shockwaves.push_back({pos, stop_radius, stop_time_ms});

    for (int nid : neighbors)
    {
        auto it = id_to_index.find(nid);
        if (it == id_to_index.end())
            continue;

        AgentData &agent = agents[it->second];

        Vec2 diff = agent.position - pos;
        double dist = diff.length();
        if (dist > radius)
            continue;

        Vec2 dir = safe_normalize(dist < 1e-3 ? hashed_unit_dir(agent.id) : diff);
        double base = std::max(0.0, 1.0 - dist / radius);
        double attenuation = std::pow(base, std::max(0.0, cfg.explosion_falloff));

        Vec2 smash = dir * (intensity * attenuation);

        double len = safe_len(smash);
        if (len > cfg.smash_cap)
            smash = smash * (cfg.smash_cap / len);

        double wave_speed = std::max(1.0, cfg.shockwave_speed);
        agent.smash_delay = dist / wave_speed;
        agent.pending_smash = smash;
        agent.pending_smash_friction = std::clamp(friction_loss, 0.0, 1.0);
        agent.smash_pending = true;
        agent.smash_force = Vec2(0, 0);
        agent.smash_just_reset = false;

        agent.is_propelled = false;
        agent.propelled_timer = 0.0;

        if (!agent.active)
        {
            agent.active = true;
            agent.has_arrived = false;
            agent.is_first = false;
        }
        agent.flow = nullptr;
        agent.group = INVALID_GROUP;
    }
}

void SteeringSystem::set_agent_claimed_tile(int id, const Vec2i &tile)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    agents[it->second].claimed_tile = tile;
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

    // Mettre à jour les shockwaves persistantes
    for (auto &w : shockwaves)
        w.time_left_ms -= delta * 1000.0;
    shockwaves.erase(std::remove_if(shockwaves.begin(), shockwaves.end(),
                                    [](const Shockwave &w)
                                    { return w.time_left_ms <= 0.0; }),
                     shockwaves.end());

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
                a.smash_pending = false;
                a.smash_just_reset = true;
            }
        }
    }

    for (auto &a : agents)
    {
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
                a.velocity = Vec2(0, 0);
            }
        }
        else
        {
            a.smash_force = Vec2(0, 0);
        }
    }

    std::unordered_map<GroupID, int> group_sizes;
    group_sizes.reserve(agents.size());
    for (const auto &a : agents)
        group_sizes[a.group]++;

    for (auto &a : agents)
    {
        FlowField *nav = a.flow ? a.flow : default_flow;

        Vec2 wall_repel(0, 0);
        if (nav)
            wall_repel = wall_repulsion_force(a, nav);

        Vec2 separation = force_voisine(a);
        bool in_shockwave = false;
        if (!a.is_propelled)
        {
            for (const auto &w : shockwaves)
            {
                if (w.time_left_ms > 0.0 && (a.position - w.pos).length() <= w.radius)
                {
                    in_shockwave = true;
                    break;
                }
            }
        }

        if (!a.active || !a.flow)
        {
            if (!a.is_propelled)
            {
                Vec2 combined = wall_repel + separation;

                Vec2 local_dir = safe_normalize(combined);
                if (local_dir.is_zero())
                {
                    continue;
                }
                Vec2 target_velocity = local_dir * a.max_speed * cfg.min_speed_fraction;
                a.velocity = a.velocity.lerp(target_velocity, cfg.lerp_general);
            }
            // si propulsé, on conserve la velocity existante (déjà amortie)

            Vec2 old_pos = a.position;
            a.position = a.position + a.velocity * delta;

            if (nav)
                ultimate_wall_correction(a, nav, delta);

            grid->update(a.id, old_pos, a.position);
            continue;
        }

        FlowField *ff = a.flow;
        if (!ff || !ff->is_ready())
            continue;

        Vec2 goal_pos = ff->goal_center_world();
        Vec2 to_goal = goal_pos - a.position;
        double dist_to_target = safe_len(to_goal);

        Vec2 flow_dir = in_shockwave ? Vec2(0, 0) : safe_normalize(ff->compute_flow_dir(a.position));
        bool reached_goal_cell = flow_dir.is_zero(); // fallback when flow dir vanishes near/at goal
        Vec2 nav_dir = (flow_dir.is_zero() && !in_shockwave) ? safe_normalize(to_goal) : flow_dir;

        int group_size = 1;
        if (auto it_count = group_sizes.find(a.group); it_count != group_sizes.end() && it_count->second > 0)
            group_size = it_count->second;

        double t1_radius = (cfg.tile_size * cfg.target_T1_param_tile_ratio) * std::sqrt((double)group_size);
        double t2_radius = t1_radius + cfg.target_T2_param_margin;
        double t2_speed_target = a.max_speed * std::clamp(cfg.target_T2_param_speed_ratio, 0.0, 1.0);
        double t2_speed_lerp = std::clamp(cfg.target_T2_param_speed_lerp, 0.0, 1.0);
        double arrival_stop_speed = std::max(0.1, t2_speed_target * 0.25);

        bool now_in_t2 = dist_to_target <= t2_radius;
        if (now_in_t2 && !a.was_in_t2)
        {
            godot::UtilityFunctions::print("Agent ", a.id, " entered T2 (dist=", dist_to_target, ", r=", t2_radius, ")");
        }
        a.was_in_t2 = now_in_t2;

        Vec2 target_velocity;
        if (a.is_propelled)
        {
            target_velocity = a.velocity; // velocity déjà amortie par friction
        }
        else
        {
            Vec2 combined = wall_repel + separation;
            combined += nav_dir * cfg.flow_weight;

            Vec2 desired_dir = safe_normalize(combined);
            if (desired_dir.is_zero() && dist_to_target > t2_radius && !in_shockwave)
            {
                // Keep pushing toward the goal so we never stall before entering slowdown zones
                desired_dir = safe_normalize(to_goal);
            }
            if (desired_dir.is_zero() && dist_to_target > 0.0 && !in_shockwave)
            {
                desired_dir = safe_normalize(to_goal);
            }
            double target_speed = a.max_speed;
            if (dist_to_target <= t1_radius)
            {
                double t = (t1_radius <= 1e-6) ? 0.0 : dist_to_target / t1_radius;
                target_speed = a.max_speed * clamp01(t);
            }
            else if (dist_to_target <= t2_radius)
            {
                double current_speed = safe_len(a.velocity);
                double desired = current_speed + (t2_speed_target - current_speed) * t2_speed_lerp;
                // avoid going under target; keep monotonic toward target
                if (current_speed > t2_speed_target)
                    target_speed = std::max(t2_speed_target, desired);
                else
                    target_speed = t2_speed_target;
            }
            target_velocity = desired_dir * target_speed;
        }

        if (!a.has_arrived && dist_to_target <= t1_radius && safe_len(a.velocity) <= arrival_stop_speed)
        {
            a.has_arrived = true;
        }

        bool can_complete = a.has_arrived && (dist_to_target <= t1_radius || reached_goal_cell);

        if (can_complete)
        {
            smooth_stop(a.id);
            a.is_first = false;

            ff->refcount--;
            ff->arrived_count++;

            a.flow = nullptr;
            ffcore::cleanup_flow_if_unused(ff);

            a.active = false;

            if (auto *mgr = ffcore::get_global_agent_manager())
                if (auto *entry = mgr->get(a.id))
                    if (mgr->is_group_active(entry->group) &&
                        mgr->all_agents_inactive(entry->group))
                        mgr->mark_group_finished(entry->group);

            continue;
        }

        if (a.is_propelled)
        {
            a.velocity = target_velocity; // on conserve la vélocité propulsée (déjà amortie)
        }
        else
        {
            a.velocity = a.velocity.lerp(target_velocity, cfg.lerp_general);
        }

        if (!a.is_propelled)
        {
            double vlen = safe_len(a.velocity);
            if (vlen > a.max_speed)
                a.velocity = a.velocity * (a.max_speed / vlen);
        }

        Vec2 old_pos = a.position;
        a.position = a.position + a.velocity * delta;

        ultimate_wall_correction(a, ff, delta);

        grid->update(a.id, old_pos, a.position);
    }
}
