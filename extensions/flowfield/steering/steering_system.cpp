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
#include "../agent_manager/agent_manager.h"
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

void SteeringSystem::set_agent_flow(int id, FlowFieldID flow)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    agents[it->second].flow_id = flow;
}

FlowFieldID SteeringSystem::get_agent_flow(int id) const
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return INVALID_FLOWFIELD;
    return agents[it->second].flow_id;
}

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

    a.position = a.position.lerp(target, softness);
    a.velocity = Vec2(0, 0);
}
// steering_system.cpp
Vec2 SteeringSystem::wall_repulsion_force(const AgentData &a, FlowField *ff)
{
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
                if (L < WALL_AVOID_RADIUS && L > 1e-3)
                {
                    double f = std::pow(1.0 - L / WALL_AVOID_RADIUS, 2.0);
                    r = r + safe_normalize(d) * f;
                }
            }
        }
    if (r.is_zero())
        return r;
    return safe_normalize(r) * WALL_REPEL_STRENGTH;
}

Vec2 SteeringSystem::force_voisine(const AgentData &agent)
{
    if (!grid)
        return Vec2(0, 0);

    std::vector<int> neighbor_ids = grid->query_neighbors(agent.position, SEPARATION_RADIUS);

    struct NeighborDist
    {
        int id;
        double dist_sq;
    };
    std::vector<NeighborDist> candidates;
    candidates.reserve(neighbor_ids.size());

    for (int neighbor_id : neighbor_ids)
    {
        if (neighbor_id == agent.id)
            continue;
        auto it = id_to_index.find(neighbor_id);
        if (it == id_to_index.end())
            continue;

        const AgentData &n = agents[it->second];
        Vec2 diff = agent.position - n.position;
        double dist_sq = diff.length_squared();

        if (dist_sq <= SEPARATION_RADIUS * SEPARATION_RADIUS)
            candidates.push_back({neighbor_id, dist_sq});
    }

    std::sort(candidates.begin(), candidates.end(),
              [](const NeighborDist &a, const NeighborDist &b)
              { return a.dist_sq < b.dist_sq; });

    int limit = std::min((int)candidates.size(), MAX_NEIGHBORS);

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

        double falloff = std::pow(std::max(0.0, 1.0 - dist / SEPARATION_RADIUS), 2.0);
        double weight = n.active ? 1.0 : 2.0;

        separation_force += (diff * (1.0 / dist)) * falloff * weight;
        count++;
    }

    if (count > 0)
        separation_force = separation_force * (1.0 / (double)count);

    if (!separation_force.is_zero())
        separation_force = safe_normalize(separation_force) * SEPARATION_STRENGTH;

    FlowField *ff = agent.flow ? agent.flow : default_flow;
    if (!ff || !ff->is_ready())
        return separation_force;

    Vec2 raw_force = separation_force;

    double probe_dist = std::min(SEPARATION_RADIUS, ff->tile_size() * 0.5);
    Vec2 sep_dir = safe_normalize(separation_force);
    Vec2 probe_pos = agent.position + sep_dir * probe_dist;
    Vec2i probe_cell = ff->world_to_cell(probe_pos);

    if (!ff->is_cell_navigable(probe_cell))
    {
        Vec2 wall_center = ff->cell_to_world(probe_cell);
        Vec2 wall_dir = safe_normalize(wall_center - agent.position);

        double dot = separation_force.dot(wall_dir);
        if (dot > 0.0)
            separation_force -= wall_dir * dot;

        if (!separation_force.is_zero())
            separation_force = safe_normalize(separation_force) * SEPARATION_STRENGTH;
    }

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
    agents[it->second].flow = ff;
    agents[it->second].active = true;
}
void SteeringSystem::update_all(double delta)
{
    if (agents.empty())
        return;
    if (!grid)
        return;

    for (auto &a : agents)
    {
        if (!a.active)
            continue;
        if (!a.flow)
            continue;

        FlowField *ff = a.flow;

        if (!ff)
        {
            godot::UtilityFunctions::print("Agent ", a.id, " n'a pas de flow assigné, SKIP");
            continue;
        }

        if (!ff->is_ready())
        {
            godot::UtilityFunctions::print("Agent ", a.id, " flow non prêt, SKIP");
            continue;
        }

        const Vec2 goal_pos = ff->goal_center_world();
        const double dist_to_target = (a.position - goal_pos).length();

     

        Vec2 wall_repel = wall_repulsion_force(a, ff);
        Vec2 separation = force_voisine(a);
        Vec2 flow_dir = safe_normalize(ff->compute_flow_dir(a.position));
        Vec2 desired_dir = safe_normalize(wall_repel + separation + flow_dir);

       
        double slow_factor = 1.0;

        if (dist_to_target < TARGET_SLOW_RADIUS)
            slow_factor = std::clamp(dist_to_target / TARGET_SLOW_RADIUS, MIN_SPEED_FRACTION, 1.0);

        if (!a.has_arrived && dist_to_target < TARGET_APPROACH_RADIUS)
            a.has_arrived = true;

        if (a.has_arrived && dist_to_target < TARGET_OCCUPY_RADIUS)
        {
            smooth_stop(a.id);
            a.active = false;
           /*  godot::UtilityFunctions::print("Agent ", a.id, " arrived, stopped"); */
            continue;
        }

        Vec2 target_velocity = desired_dir * a.max_speed * slow_factor;
        double smoothing = 0.04;
        a.velocity = a.velocity.lerp(target_velocity, smoothing);

        const double vlen = safe_len(a.velocity);
        if (vlen > a.max_speed)
            a.velocity = a.velocity * (a.max_speed / vlen);

      

        const Vec2 old_pos = a.position;
        Vec2 proposed = a.position + a.velocity * delta;
        Vec2i prop_cell = ff->world_to_cell(proposed);

        a.position = proposed;

     

        ultimate_wall_correction(a, ff, delta);

     

        grid->update(a.id, old_pos, a.position);
    }
}