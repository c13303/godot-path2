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

int SteeringSystem::register_agent(const Vec2 &pos, double max_speed, FlowField *flow) // Enregistre un agent
{
    AgentData a;
    a.id = next_id++;
    a.position = pos;
    a.max_speed = globalconfig().agent_max_speed;
    a.flow = flow ? flow : default_flow;
    a.debug_color = hashed_color(a.id);
    agents.push_back(a);
    id_to_index[a.id] = (int)agents.size() - 1;
    const auto &cfg = globalconfig();
    Vec2 offset(0, cfg.agent_offset_y);
    if (grid)
        grid->insert(a.id, pos + offset);
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
    a.max_speed = globalconfig().agent_max_speed;
    a.flow = flow;
    a.active = flow != nullptr; // ✅ Inactif si pas de flow
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

    const auto &cfg = globalconfig();
    Vec2 offset(0, cfg.agent_offset_y);
    if (grid)
        grid->insert(a.id, pos + offset);

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

Vec2 SteeringSystem::apply_walk_with_walls(const Vec2 &from, const Vec2 &step, FlowField *ff)
{
    if (!ff || (step.x == 0.0 && step.y == 0.0))
        return from + step;

    const double max_step = std::max(1.0, ff->tile_size() * 0.25);
    int steps = std::max(1, static_cast<int>(std::ceil(step.length() / max_step)));
    Vec2 pos = from;
    Vec2 sub_step = step * (1.0 / static_cast<double>(steps));

    for (int i = 0; i < steps; ++i)
    {
        Vec2 full = pos + sub_step;
        if (ff->is_cell_navigable(ff->world_to_cell(full)))
        {
            pos = full;
            continue;
        }

        Vec2 only_x(pos.x + sub_step.x, pos.y);
        if (sub_step.x != 0.0 && ff->is_cell_navigable(ff->world_to_cell(only_x)))
        {
            pos = only_x;
            continue;
        }

        Vec2 only_y(pos.x, pos.y + sub_step.y);
        if (sub_step.y != 0.0 && ff->is_cell_navigable(ff->world_to_cell(only_y)))
        {
            pos = only_y;
            continue;
        }

        break;
    }

    return pos;
}

bool SteeringSystem::is_player_footprint_navigable(const Vec2 &bottom_center, FlowField *ff) const
{
    if (!ff)
        return true;

    constexpr double footprint = 32.0;
    constexpr double half = footprint * 0.5;
    constexpr double epsilon = 0.001;

    const Vec2 samples[] = {
        Vec2(bottom_center.x - half + epsilon, bottom_center.y - footprint + epsilon),
        Vec2(bottom_center.x + half - epsilon, bottom_center.y - footprint + epsilon),
        Vec2(bottom_center.x - half + epsilon, bottom_center.y - epsilon),
        Vec2(bottom_center.x + half - epsilon, bottom_center.y - epsilon),
    };

    for (const Vec2 &sample : samples)
    {
        if (!ff->is_cell_navigable(ff->world_to_cell(sample)))
            return false;
    }

    return true;
}

Vec2 SteeringSystem::apply_player_walk_with_walls(const Vec2 &from, const Vec2 &step, FlowField *ff)
{
    if (!ff || (step.x == 0.0 && step.y == 0.0))
        return from + step;

    Vec2 full = from + step;
    if (is_player_footprint_navigable(full, ff))
        return full;

    Vec2 only_x(from.x + step.x, from.y);
    if (step.x != 0.0 && is_player_footprint_navigable(only_x, ff))
        return only_x;

    Vec2 only_y(from.x, from.y + step.y);
    if (step.y != 0.0 && is_player_footprint_navigable(only_y, ff))
        return only_y;

    return from;
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

    if (ff && ff->has_distance_field())
    {
        Vec2i cur = ff->world_to_cell(a.position);
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

    for (int i = 0; i < limit; ++i)
    {
        auto it = id_to_index.find(candidates[i].id);
        const AgentData &n = agents[it->second];

        Vec2 diff = agent.position - n.position;
        double dist = diff.length();
        if (dist < 0.001)
            dist = 0.001;

        double falloff = std::pow(std::max(0.0, 1.0 - dist / cfg.separation_radius), 2.0);

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

    a.dir_code = -1;
}

void SteeringSystem::set_agent_profile(int id, const AgentProfile &profile)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    AgentProfile sanitized = profile;
    sanitized.crowd_push_strength = std::max(0.0, sanitized.crowd_push_strength);
    sanitized.crowd_resist_strength = std::max(0.001, sanitized.crowd_resist_strength);
    if (sanitized.smash_class < 0)
        sanitized.smash_class = 0;

    agents[it->second].profile = sanitized;
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

    if (detach_flow)
    {
        agent.flow = nullptr;
        agent.group = INVALID_GROUP;
    }
}

void SteeringSystem::apply_area_smash(const Vec2 &pos, double radius, const Vec2 &direction, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes)
{
    if (radius <= 0.0 || !grid)
        return;

    auto neighbors = grid->query_neighbors(pos, radius);
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
        if (affected_smash_classes != 0 && (agent.profile.smash_class & affected_smash_classes) == 0)
            continue;

        double dist = (agent.position - pos).length();
        if (dist > radius)
            continue;

        double base = std::max(0.0, 1.0 - dist / radius);
        double attenuation = std::pow(base, safe_falloff);
        apply_smash_impulse(nid, direction, force * attenuation, friction_loss, 0.0, detach_flow, control_suppression, control_suppression_duration);
    }
}

void SteeringSystem::apply_cone_smash(const Vec2 &pos, double radius, const Vec2 &direction, double angle_degrees, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes)
{
    if (radius <= 0.0 || !grid)
        return;

    Vec2 facing = safe_normalize(direction);
    if (facing.is_zero())
        return;

    auto neighbors = grid->query_neighbors(pos, radius);
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
        if (affected_smash_classes != 0 && (agent.profile.smash_class & affected_smash_classes) == 0)
            continue;

        Vec2 to_agent = agent.position - pos;
        double dist = to_agent.length();
        if (dist > radius)
            continue;

        if (angle_degrees < 360.0 && safe_normalize(to_agent).dot(facing) < min_dot)
            continue;

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
    if (radius <= 0.0 || !grid)
        return;

    const auto &cfg = globalconfig();
    auto neighbors = grid->query_neighbors(pos, radius);
    if (neighbors.empty())
        return;

    double stop_radius = radius * std::max(0.0, cfg.shockwave_stop_ratio);
    double stop_time_ms = std::max(0.0, cfg.shockwave_stop_duration_ms);
    if (stop_radius > 0.0 && stop_time_ms > 0.0)
        shockwaves.push_back({pos, stop_radius, stop_time_ms, ignored_agent_id, affected_smash_classes});

    for (int nid : neighbors)
    {
        if (nid == ignored_agent_id)
            continue;

        auto it = id_to_index.find(nid);
        if (it == id_to_index.end())
            continue;

        AgentData &agent = agents[it->second];
        if (affected_smash_classes != 0 && (agent.profile.smash_class & affected_smash_classes) == 0)
            continue;

        Vec2 diff = agent.position - pos;
        double dist = diff.length();
        if (dist > radius)
            continue;

        Vec2 dir = safe_normalize(dist < 1e-3 ? hashed_unit_dir(agent.id) : diff);
        double base = std::max(0.0, 1.0 - dist / radius);
        double attenuation = std::pow(base, std::max(0.0, falloff));

        double wave_speed = std::max(1.0, cfg.shockwave_speed);
        apply_smash_impulse(nid, dir, intensity * attenuation, friction_loss, dist / wave_speed, true, control_suppression, control_suppression_duration);
    }
}

void SteeringSystem::set_agent_never_rest(int id, bool value)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    agents[it->second].never_rest = value;
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
        bool in_shockwave = false;
        if (!a.is_propelled)
        {
            for (const auto &w : shockwaves)
            {
                if (a.id == w.ignored_agent_id)
                    continue;
                if (w.affected_smash_classes != 0 && (a.profile.smash_class & w.affected_smash_classes) == 0)
                    continue;
                if (w.time_left_ms > 0.0 && (a.position - w.pos).length() <= w.radius)
                {
                    in_shockwave = true;
                    break;
                }
            }
        }

        const auto &cfg = globalconfig();
        Vec2 offset(0, cfg.agent_offset_y);
        double active_control_suppression = (a.is_propelled && a.smash_control_suppression_timer > 0.0) ? std::clamp(a.smash_control_suppression, 0.0, 1.0) : 0.0;
        double smash_control_factor = a.is_propelled ? (1.0 - active_control_suppression) : 1.0;

        if (!a.active || !a.flow)
        {
            if (a.control_mode == AgentControlMode::Manual)
            {
                Vec2 manual_dir = in_shockwave ? Vec2(0, 0) : safe_normalize(a.manual_input_dir);
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
                Vec2 new_pos = apply_player_walk_with_walls(a.position, step, nav);
                a.position = new_pos;

                if (nav)
                    ultimate_wall_correction(a, nav, delta);

                grid->update(a.id, old_pos + offset, a.position + offset);
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
            a.position = apply_walk_with_walls(a.position, step, nav);

            if (nav)
                ultimate_wall_correction(a, nav, delta);

            grid->update(a.id, old_pos + offset, a.position + offset);
            a.update_motion_state(delta, cfg);
            continue;
        }

        if (a.control_mode == AgentControlMode::Manual)
        {
            Vec2 manual_dir = in_shockwave ? Vec2(0, 0) : safe_normalize(a.manual_input_dir);
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
            Vec2 new_pos = apply_player_walk_with_walls(a.position, step, nav);
            a.position = new_pos;

            if (nav)
                ultimate_wall_correction(a, nav, delta);

            grid->update(a.id, old_pos + offset, a.position + offset);
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

        Vec2i rel_cell = ff->world_to_cell(a.position + offset);
        Vec2i map_cell(rel_cell.x + ff->get_cell_origin().x, rel_cell.y + ff->get_cell_origin().y);
        if (map_cell != a.last_logged_tile)
        {
            a.last_logged_tile = map_cell;
        }
        Vec2 flow_dir = in_shockwave ? Vec2(0, 0) : safe_normalize(ff->compute_flow_dir(a.position + offset));
        Vec2 nav_dir = (flow_dir.is_zero() && !in_shockwave) ? safe_normalize(to_goal) : flow_dir;

        double t2_speed_target = a.max_speed * std::clamp(cfg.target_T2_param_speed_ratio, 0.0, 1.0);
        double t2_speed_lerp = std::clamp(cfg.target_T2_param_speed_lerp, 0.0, 1.0);

        bool in_t2_zone = target_radius > 0.0 && dist_to_target <= target_radius;

        Vec2 target_velocity;
        {
            Vec2 combined = wall_repel + separation;
            combined += nav_dir * cfg.flow_weight;

            Vec2 desired_dir = safe_normalize(combined);
            if (desired_dir.is_zero() && dist_to_target > 0.0 && !in_shockwave)
                desired_dir = safe_normalize(to_goal);

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
            target_velocity = desired_dir * target_speed;
        }

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
        a.position = apply_walk_with_walls(a.position, step, ff);

        ultimate_wall_correction(a, ff, delta);

        grid->update(a.id, old_pos + offset, a.position + offset);

        a.update_motion_state(delta, cfg, force_motion_state);
    }
}
