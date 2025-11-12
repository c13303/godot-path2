#include "steering_system.h" // Inclusion du header de la classe SteeringSystem
#include <algorithm>         // Pour std::sort et std::min
#include <cstdio>            // Pour les fonctions de debug (printf, etc.)
#include <cmath>             // Pour les fonctions trigonométriques
#include <unordered_map>     // Pour le stockage rapide des cooldowns par id

using namespace ffcore; // Utilisation de l’espace de noms du moteur

static inline double clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); } // Limite v entre 0 et 1

/* declaration generale du system pour partage */
static SteeringSystem *g_steering = nullptr;
SteeringSystem *ffcore::get_global_steering_system() { return g_steering; }
SteeringSystem::SteeringSystem() { g_steering = this; }

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

void SteeringSystem::soft_wall_correction(AgentData &a, FlowField *ff, double delta) // Corrige la position d’un agent s’il est dans un mur
{
    Vec2i cell = ff->world_to_cell(a.position);
    if (ff->is_cell_navigable(cell))
        return;

    Vec2i best_cell = cell;
    double best_dist = 1e12;

    for (int dx = -1; dx <= 1; ++dx)
        for (int dy = -1; dy <= 1; ++dy)
        {
            Vec2i n = {cell.x + dx, cell.y + dy};
            if (!ff->is_cell_navigable(n))
                continue;
            double d = (ff->cell_to_world(n) - a.position).length();
            if (d < best_dist)
            {
                best_dist = d;
                best_cell = n;
            }
        }

    if (best_cell == cell)
        return;

    Vec2 wall_center = ff->cell_to_world(cell);
    Vec2 free_center = ff->cell_to_world(best_cell);
    Vec2 dir = safe_normalize(free_center - wall_center);

    Vec2 target_pos = free_center - dir * (ff->tile_size() * 0.5 - 0.05);
    double blend = std::clamp(delta * 4.0, 0.0, 0.25);
    a.position = a.position.lerp(target_pos, blend);

    double toward_wall = a.velocity.dot(dir);
    if (toward_wall > 0.0)
        a.velocity = a.velocity - dir * toward_wall;
}
Vec2 SteeringSystem::compute_separation_force(const AgentData &agent)
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
        const AgentData &neighbor = agents[it->second];

        Vec2 diff = agent.position - neighbor.position;
        double dist_sq = diff.length_squared();
        if (dist_sq <= SEPARATION_RADIUS * SEPARATION_RADIUS)
            candidates.push_back({neighbor_id, dist_sq});
    }

    std::sort(candidates.begin(), candidates.end(),
              [](const NeighborDist &a, const NeighborDist &b)
              { return a.dist_sq < b.dist_sq; });

    int limit = std::min(static_cast<int>(candidates.size()), MAX_NEIGHBORS);

    Vec2 separation_force(0, 0);
    int count = 0;

    for (int i = 0; i < limit; ++i)
    {
        auto it = id_to_index.find(candidates[i].id);
        const AgentData &neighbor = agents[it->second];

        Vec2 diff = agent.position - neighbor.position;
        double dist = diff.length();
        if (dist < 0.001)
            dist = 0.001;

        double falloff = std::pow(std::max(0.0, 1.0 - dist / SEPARATION_RADIUS), 2.0);
        double weight = neighbor.active ? 1.0 : 2.0;

        separation_force = separation_force + (diff * (1.0 / dist)) * falloff * weight;
        count++;
    }

    if (count > 0)
        separation_force = separation_force * (1.0 / (double)count);

    if (!separation_force.is_zero())
        separation_force = safe_normalize(separation_force) * SEPARATION_STRENGTH;

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

void SteeringSystem::update_all(double delta)
{
    if (!grid)
        return;

    for (auto &a : agents)
    {
        if (!a.active)
            continue;

        FlowField *ff = a.flow ? a.flow : default_flow;
        if (!ff || !ff->is_ready())
            continue;

        const Vec2 goal_pos = ff->goal_center_world();
        const double dist_to_target = (a.position - goal_pos).length();

        Vec2i cur_cell = ff->world_to_cell(a.position);
        if (!ff->is_cell_navigable(cur_cell))
            a.position = ff->cell_to_world(cur_cell);
        cur_cell = ff->world_to_cell(a.position);

        Vec2 wall_repel(0, 0);
        for (int dx = -1; dx <= 1; ++dx)
            for (int dy = -1; dy <= 1; ++dy)
            {
                if (dx == 0 && dy == 0)
                    continue;
                Vec2i ncell{cur_cell.x + dx, cur_cell.y + dy};
                if (!ff->is_cell_navigable(ncell))
                {
                    Vec2 away = a.position - ff->cell_to_world(ncell);
                    double d = away.length();
                    if (d < WALL_AVOID_RADIUS && d > 1e-3)
                    {
                        double k = (1.0 - d / WALL_AVOID_RADIUS) * WALL_REPEL_STRENGTH;
                        wall_repel = wall_repel + away * (k / d);
                    }
                }
            }

        Vec2 separation = compute_separation_force(a);
        Vec2 flow_dir = safe_normalize(ff->sample_dir_world(a.position));
        Vec2 desired_dir = safe_normalize(wall_repel + separation + flow_dir);

        if (desired_dir.is_zero())
            desired_dir = hashed_unit_dir(a.id);

        double slow_factor = 1.0;
        if (dist_to_target < TARGET_SLOW_RADIUS)
            slow_factor = std::clamp(dist_to_target / TARGET_SLOW_RADIUS, MIN_SPEED_FRACTION, 1.0);

        if (!a.has_arrived && dist_to_target < TARGET_APPROACH_RADIUS)
            a.has_arrived = true;

        if (a.has_arrived && dist_to_target < TARGET_OCCUPY_RADIUS)
        {
            smooth_stop(a.id);
            a.active = false;
            continue;
        }

        Vec2 target_velocity = desired_dir * a.max_speed * slow_factor;
        a.velocity = a.velocity.lerp(target_velocity, 0.15);

        const double vlen = safe_len(a.velocity);
        if (vlen > a.max_speed)
            a.velocity = a.velocity * (a.max_speed / vlen);

        const Vec2 old_pos = a.position;
        Vec2 proposed = a.position + a.velocity * delta;
        Vec2i prop_cell = ff->world_to_cell(proposed);
        if (!ff->is_cell_navigable(prop_cell))
            proposed = project_to_navigable(ff, a.position, proposed);

        a.position = proposed;
        soft_wall_correction(a, ff, delta);
        grid->update(a.id, old_pos, a.position);
    }
}
