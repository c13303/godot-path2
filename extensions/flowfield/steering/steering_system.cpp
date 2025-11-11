#include "steering_system.h" // Inclusion du header de la classe SteeringSystem
#include <algorithm>         // Pour std::sort et std::min
#include <cstdio>            // Pour les fonctions de debug (printf, etc.)
#include <cmath>             // Pour les fonctions trigonométriques
#include <unordered_map>     // Pour le stockage rapide des cooldowns par id

using namespace ffcore; // Utilisation de l’espace de noms du moteur

static inline double clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); } // Limite v entre 0 et 1

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

SteeringSystem::SteeringSystem() {} // Constructeur vide

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

namespace
{
    const double SEPARATION_RADIUS = 24.0;  // Rayon d’évitement
    const double SEPARATION_STRENGTH = 2.0; // Intensité de répulsion
    const int MAX_NEIGHBORS = 8;            // Nombre max de voisins pris en compte
}

Vec2 SteeringSystem::compute_separation_force(const AgentData &agent, double, bool) // Force de séparation entre agents
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
        if (!neighbor.active)
            continue;

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
        double falloff = 1.0 - std::min(dist / SEPARATION_RADIUS, 1.0);
        separation_force = separation_force + (diff * (1.0 / dist)) * falloff;
        count++;
    }

    if (count > 0)
        separation_force = separation_force * (1.0 / (double)count);

    if (!separation_force.is_zero())
        separation_force = safe_normalize(separation_force) * SEPARATION_STRENGTH;

    return separation_force;
}

void SteeringSystem::smooth_stop(int id, double rate)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    AgentData &a = agents[it->second];
    a.velocity = a.velocity.lerp(Vec2(0, 0), rate);
    if (safe_len(a.velocity) < 0.01)
    {
        a.velocity = Vec2(0, 0);
        a.active = false;
    }
}


void SteeringSystem::update_all(double delta) // Met à jour tous les agents
{
    if (!grid)
        return;

    for (auto &a : agents)
    {
        if (!a.active)
            continue;

        // Met à jour le cooldown local lié au fait de devoir contourner un target occupé
        if (auto it = g_goal_cooldown.find(a.id); it != g_goal_cooldown.end() && it->second > 0.0)
            it->second = std::max(0.0, it->second - delta);

        // Sélection du flowfield
        FlowField *ff = a.flow ? a.flow : default_flow;
        if (!ff || !ff->is_ready())
            continue;

        // Calcul des grandeurs liées au target final
        const Vec2 goal_pos = ff->has_goal() ? ff->goal_center_world() : a.position;
        const double dist_to_target = (a.position - goal_pos).length();

        // Projection dans une cellule navigable si nécessaire
        Vec2i cur_cell = ff->world_to_cell(a.position);
        if (!ff->is_cell_navigable(cur_cell))
            a.position = ff->cell_to_world(cur_cell);
        cur_cell = ff->world_to_cell(a.position);

        // Références centrées cellule courante / cellule du target
        const Vec2 cell_center = ff->cell_to_world(cur_cell);
        const Vec2i goal_cell = ff->has_goal() ? ff->get_goal_cell() : cur_cell;
        const bool in_goal_tile = (cur_cell.x == goal_cell.x && cur_cell.y == goal_cell.y);
        const Vec2 goal_center = ff->cell_to_world(goal_cell);

        // Détection d’un occupant dans la zone d’occupation finale
        bool goal_has_occupant = false;
        int goal_occupant_id = -1;
        {
            // Recherche limitée à la zone d’approche (utile pour l’évitement local final)
            std::vector<int> nids = grid->query_neighbors(goal_center, TARGET_APPROACH_RADIUS);
            for (int nid : nids)
            {
                if (nid == a.id)
                    continue;
                auto itn = id_to_index.find(nid);
                if (itn == id_to_index.end())
                    continue;
                const AgentData &other = agents[itn->second];
                if (!other.active)
                    continue;

                const double d = (other.position - goal_center).length();
                if (d <= TARGET_OCCUPY_RADIUS)
                {
                    goal_has_occupant = true;
                    goal_occupant_id = nid;
                    break;
                }
            }
        }

        // Forces locales: séparation, recentrage dans la cellule, répulsion murs
        const Vec2 separation_force = compute_separation_force(a, dist_to_target, in_goal_tile);

        const Vec2 flow_dir = safe_normalize(ff->sample_dir_world(a.position)); // direction du flowfield (CELLGOAL)
        const Vec2 offset_center = cell_center - a.position;
        const double offset_dist = offset_center.length();
        Vec2 center_correction = safe_normalize(offset_center) * std::min(offset_dist / TILE_SIZE, 1.0) * CENTER_PULL;

        Vec2 wall_repel(0, 0);
        for (int dx = -1; dx <= 1; ++dx)
            for (int dy = -1; dy <= 1; ++dy)
            {
                if (dx == 0 && dy == 0)
                    continue;
                const Vec2i ncell{cur_cell.x + dx, cur_cell.y + dy};
                const Vec2 n_center = ff->cell_to_world(ncell);
                const Vec2 n_dir = ff->sample_dir_world(n_center);
                if (n_dir.is_zero()) // cellule non navigable aux alentours => repousser
                {
                    Vec2 away = a.position - n_center;
                    const double d = away.length();
                    if (d < WALL_AVOID_RADIUS && d > 1e-3)
                    {
                        const double k = (1.0 - (d / WALL_AVOID_RADIUS)) * WALL_REPEL_STRENGTH;
                        wall_repel = wall_repel + away * (k / d);
                    }
                }
            }

        // Mélange direction directe vers target quand on est proche (adoucit la fin de trajectoire)
        double blend_to_direct = 0.0;
        if (dist_to_target < DIRECT_STEER_RADIUS)  /// Le STEERING prend le controle !
        {
            blend_to_direct = 1.0 - (dist_to_target / DIRECT_STEER_RADIUS);
            blend_to_direct = std::pow(blend_to_direct, 0.5);
        }

        // Atténue certaines forces quand on est proche du target (évite sur-corrections)
        const double force_dampening = std::min(dist_to_target / TARGET_SLOW_RADIUS, 1.0);
        center_correction = center_correction * force_dampening * (1.0 - blend_to_direct);
        wall_repel = wall_repel * force_dampening * (1.0 - blend_to_direct);

        // Direction consolidée issue du champ + corrections locales
        const Vec2 flowfield_dir = safe_normalize(flow_dir * FLOW_WEIGHT + center_correction + wall_repel + separation_force);

        // Stratégie d’approche : contournement si la zone d’occupation est prise, sinon suivi normal
        Vec2 desired_dir;
        bool keep_out_now = false;
        const double my_cd = g_goal_cooldown[a.id];

        if ((goal_has_occupant && goal_occupant_id != a.id) || my_cd > 0.0)
        {
            // Évitement/tangentiel autour d’un target occupé
            keep_out_now = true;
            Vec2 from_goal = a.position - goal_center;
            if (from_goal.is_zero())
                from_goal = hashed_unit_dir(a.id);
            Vec2 tangent(-from_goal.y, from_goal.x);
            tangent = safe_normalize(tangent);

            // Combinaison: s’éloigner un peu du centre + glisser tangentiel + tenir compte de la séparation
            const Vec2 keep_out = safe_normalize(from_goal) * 0.8 + tangent * 0.6 + separation_force * 0.8;
            desired_dir = safe_normalize(keep_out);
            if (desired_dir.is_zero())
                desired_dir = tangent;
        }
        else
        {
            // Mix direction flowfield (CELLGOAL) et direction directe vers TARGET
            const Vec2 direct_dir = safe_normalize(goal_pos - a.position);
            desired_dir = safe_normalize(flowfield_dir * (1.0 - blend_to_direct) + direct_dir * blend_to_direct);
            if (desired_dir.is_zero())
                desired_dir = (flowfield_dir.is_zero() ? hashed_unit_dir(a.id) : flowfield_dir);
        }

        // Dans la zone d’approche, évite d’orienter vers l’intérieur du centre (comportement tangentiel)
        if (ff->has_goal() && dist_to_target < TARGET_APPROACH_RADIUS)
        {
            const Vec2 n = safe_normalize(goal_center - a.position);
            const double inward = desired_dir.dot(n);
            if (inward > 0.0)
            {
                desired_dir = safe_normalize(desired_dir - n * inward);
                if (desired_dir.is_zero())
                    desired_dir = Vec2(-n.y, n.x);
            }
        }

        // Profil de décélération en deux temps: ralentissement général puis freinage terminal
        double slow_factor = 1.0;

        // 1) Ralentissement progressif à moyenne distance
        if (dist_to_target < TARGET_SLOW_RADIUS)
        {
            printf("[Agent %d] entre dans TARGET_SLOW_RADIUS (%.2f < %.2f)\n", a.id, dist_to_target, TARGET_SLOW_RADIUS);

            slow_factor = dist_to_target / TARGET_SLOW_RADIUS;
            slow_factor = std::pow(slow_factor, 1.2);
            slow_factor = std::max(slow_factor, MIN_SPEED_FRACTION);
        }

        // 2) Freinage terminal entre APPROACH et OCCUPY (tombe vers 0 au centre) /// changement de force
        if (dist_to_target < TARGET_APPROACH_RADIUS)
        {
            printf("[Agent %d] entre dans TARGET_APPROACH_RADIUS (%.2f < %.2f)\n", a.id, dist_to_target, TARGET_APPROACH_RADIUS);

            const double t = (dist_to_target - TARGET_OCCUPY_RADIUS) / (TARGET_APPROACH_RADIUS - TARGET_OCCUPY_RADIUS);
            slow_factor *= std::max(t, 0.0);
        }

        // Vélocité désirée
        Vec2 target_velocity = desired_dir * a.max_speed * slow_factor;

        // Arrivée: validation et arrêt
        if (dist_to_target <= TARGET_OCCUPY_RADIUS)
        {
            printf("[Agent %d] entre dans TARGET_OCCUPY_RADIUS (%.2f < %.2f)\n", a.id, dist_to_target, TARGET_OCCUPY_RADIUS);

            if (!a.has_arrived)
            {

                a.has_arrived = true;
                ff->arrived_count++;
                std::printf("[Agent %d] arrived, [FlowField %p] arrived_count = %d\n", a.id, (void *)ff, ff->arrived_count);
                smooth_stop(a.id);
            }
            target_velocity = Vec2(0, 0);
        }

        // Interpolation de vitesse (amortissement)
        a.velocity = a.velocity.lerp(target_velocity, 0.25);

        // Clamp vitesse max
        const double vmax = a.max_speed;
        const double vlen = safe_len(a.velocity);
        if (vlen > vmax)
            a.velocity = a.velocity * (vmax / vlen);

        // Intégration candidate
        const Vec2 old_pos = a.position;
        Vec2 proposed = a.position + a.velocity * delta;

        // Garde-fou dans la zone d’approche quand quelqu’un occupe le centre:
        // on interdit de pénétrer à l’intérieur du rayon d’approche si ce n’est pas l’occupant.
        if (keep_out_now)
        {
            Vec2 v = proposed - goal_center;
            double r = v.length();
            if (r < TARGET_APPROACH_RADIUS)
            {
                if (r < 1e-4)
                {
                    v = hashed_unit_dir(a.id);
                    r = 1.0;
                }
                proposed = goal_center + v * (TARGET_APPROACH_RADIUS / r);
                g_goal_cooldown[a.id] = std::max(g_goal_cooldown[a.id], CELLGOAL_COOLDOWN_SEC);
            }
        }

        // Collision simple contre cellules non navigables
        Vec2i prop_cell = ff->world_to_cell(proposed);
        if (!ff->is_cell_navigable(prop_cell))
            proposed = project_to_navigable(ff, a.position, proposed);

        // Application et post-correction douce en cas de mur
        a.position = proposed;
        soft_wall_correction(a, ff, delta);

        // Mise à jour spatiale
        grid->update(a.id, old_pos, a.position);
    }
}



























