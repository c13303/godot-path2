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
#include <utility>
#include <chrono> // Phase-1 diagnostic: time update_all() to catch silent per-frame spikes

using namespace ffcore; // Utilisation de l’espace de noms du moteur

static constexpr double DROWNING_VELOCITY_DAMPING_PER_SEC = 35.0;
static constexpr double DROWNING_STOP_SPEED = 8.0;
// Contact right-of-way only treats normalized manual input inside this deadzone as idle.
static constexpr double CONTACT_MANUAL_IDLE_INPUT_MAX_LENGTH_SQ = 1e-4;
// Autonomous steering must have real intent and point substantially into the contact.
static constexpr double CONTACT_AUTONOMOUS_INTENT_MIN_LENGTH_SQ = 1e-4;
static constexpr double CONTACT_AUTONOMOUS_FORWARD_MIN_DOT = 0.35;

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

static inline double terrain_speed_multiplier_for_agent(const AgentData &a, FlowField *nav)
{
    if (!nav)
        return 1.0;
    SteeringSystem *sys = g_steering;
    if (!sys)
        return 1.0;
    // Read the shared per-cell modifier by ABSOLUTE tilemap cell (field-relative cell plus
    // the field's origin). This is the single source of truth, so a live speed edit reaches
    // agents regardless of which (active/queued/newly-built) Flow Field they steer on, and
    // stale multipliers baked into an in-flight field are never observed.
    Vec2i rel = nav->world_to_cell(agent_foot_point(a));
    const Vec2i &origin = nav->get_cell_origin();
    return sys->terrain_speed_multiplier_at(Vec2i(rel.x + origin.x, rel.y + origin.y), a.profile.terrain_speed_channel);
}

static inline Vec2 terrain_scaled_step(const AgentData &a, FlowField *nav, const Vec2 &velocity, double delta)
{
    Vec2 movement_velocity = velocity;
    if (a.phase != AgentPhase::Drowning)
    {
        const Vec2 external_velocity = a.external_velocity.current_velocity();
        movement_velocity = movement_velocity + external_velocity;

        // Environmental motion may accelerate ordinary travel, but bounded normal
        // movement prevents stacked sources from producing runaway speed. Smash
        // velocity remains uncapped here so wind never weakens an existing knockback.
        if (!a.is_propelled && !external_velocity.is_zero())
        {
            const double max_environmental_speed = a.max_speed * 1.5;
            const double movement_speed = safe_len(movement_velocity);
            if (max_environmental_speed > 0.0 && movement_speed > max_environmental_speed)
                movement_velocity = movement_velocity * (max_environmental_speed / movement_speed);
        }
    }
    return movement_velocity * delta * terrain_speed_multiplier_for_agent(a, nav);
}

static inline Vec2 propelled_move_velocity(const AgentData &a, const Vec2 &target_velocity, double control_factor)
{
    if (!a.is_propelled)
        return a.velocity;

    Vec2 controlled = a.velocity + target_velocity * control_factor;
    double controlled_len = safe_len(controlled);
    if (controlled_len <= 0.000001)
        return controlled;

    double cap = std::max(safe_len(a.velocity), safe_len(target_velocity) * std::clamp(control_factor, 0.0, 1.0));
    if (cap <= 0.000001 || controlled_len <= cap)
        return controlled;

    return controlled * (cap / controlled_len);
}

static inline double agent_fight_query_padding(const AgentData &a)
{
    return std::abs(a.profile.foot_offset_y - a.profile.fight_offset_y) + std::sqrt(a.profile.fight_half_w * a.profile.fight_half_w + a.profile.fight_half_h * a.profile.fight_half_h);
}

static inline Vec2 agent_fight_center(const AgentData &a)
{
    return a.position + Vec2(0, a.profile.fight_offset_y);
}

static inline bool is_drowning_agent(const AgentData &a)
{
    return a.phase == AgentPhase::Drowning;
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
    sanitized.contact_push_power = std::isfinite(sanitized.contact_push_power) ? std::max(0.0, sanitized.contact_push_power) : 0.0;
    sanitized.contact_push_resist = std::isfinite(sanitized.contact_push_resist) ? std::max(0.001, sanitized.contact_push_resist) : 1.0;
    sanitized.contact_push_cooldown = std::isfinite(sanitized.contact_push_cooldown) ? std::max(0.0, sanitized.contact_push_cooldown) : 0.20;
    sanitized.contact_push_friction_loss = std::isfinite(sanitized.contact_push_friction_loss) ? std::clamp(sanitized.contact_push_friction_loss, 0.0, 1.0) : 0.65;
    sanitized.contact_control_suppression_seconds = std::isfinite(sanitized.contact_control_suppression_seconds) ? std::max(0.0, sanitized.contact_control_suppression_seconds) : 0.20;
    sanitized.smash_resist = (std::isfinite(sanitized.smash_resist) && sanitized.smash_resist > 0.0) ? sanitized.smash_resist : 1.0;
    sanitized.world_radius = std::isfinite(sanitized.world_radius) && sanitized.world_radius > 0.0 ? sanitized.world_radius : cfg.tile_size * cfg.agent_world_diameter_ratio * 0.5;
    sanitized.foot_offset_y = std::isfinite(sanitized.foot_offset_y) ? sanitized.foot_offset_y : cfg.agent_offset_y;
    if (!std::isfinite(sanitized.foot_offset_y))
        sanitized.foot_offset_y = 0.0;
    sanitized.fight_offset_y = std::isfinite(sanitized.fight_offset_y) ? sanitized.fight_offset_y : 0.0;
    sanitized.fight_half_w = std::isfinite(sanitized.fight_half_w) ? std::max(0.0, sanitized.fight_half_w) : 0.0;
    sanitized.fight_half_h = std::isfinite(sanitized.fight_half_h) ? std::max(0.0, sanitized.fight_half_h) : 0.0;
    if (sanitized.smash_class < 0)
        sanitized.smash_class = 0;
    if (sanitized.terrain_speed_channel < DEFAULT_TERRAIN_SPEED_CHANNEL)
        sanitized.terrain_speed_channel = DEFAULT_TERRAIN_SPEED_CHANNEL;

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
    contact_push_cooldowns.erase(id);
    traffic_right_of_way_resolver.remove_agent(id);
    for (auto &entry : contact_push_cooldowns)
        entry.second.erase(id);
    recompute_hitbox_query_extents();
}

void SteeringSystem::debug_collect_agent_ids(std::vector<int> &out) const
{
    out.clear();
    out.reserve(id_to_index.size());
    for (const auto &entry : id_to_index)
        out.push_back(entry.first);
    std::sort(out.begin(), out.end());
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

void SteeringSystem::set_terrain_speed_cell(const Vec2i &abs_cell, double multiplier, int channel)
{
    terrain_speed_grid.set_cell(abs_cell, multiplier, channel);
}

void SteeringSystem::set_terrain_speed_cells(const std::vector<Vec2i> &cells, const std::vector<double> &multipliers, int channel)
{
    terrain_speed_grid.set_cells(cells, multipliers, channel);
}

void SteeringSystem::clear_terrain_speed_cell(const Vec2i &abs_cell, int channel)
{
    terrain_speed_grid.clear_cell(abs_cell, channel);
}

void SteeringSystem::clear_terrain_speed_cells(const std::vector<Vec2i> &cells, int channel)
{
    terrain_speed_grid.clear_cells(cells, channel);
}

void SteeringSystem::replace_terrain_speed_channel(const std::vector<Vec2i> &cells, const std::vector<double> &multipliers, int channel)
{
    terrain_speed_grid.replace_channel(cells, multipliers, channel);
}

void SteeringSystem::clear_terrain_speed_channel(int channel)
{
    terrain_speed_grid.clear_channel(channel);
}

double SteeringSystem::terrain_speed_multiplier_at(const Vec2i &abs_cell, int channel) const
{
    return terrain_speed_grid.multiplier_at(abs_cell, channel);
}

void SteeringSystem::set_agent_group(int id, GroupID group)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    agents[it->second].group = group;
    // Being assigned to a real routing group ends any spawn-time flow wait.
    if (group != INVALID_GROUP)
        agents[it->second].waiting_flow_group = INVALID_GROUP;
}

void SteeringSystem::set_agent_waiting_flow_group(int id, GroupID group)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    agents[it->second].waiting_flow_group = group;
}

int SteeringSystem::count_agents_waiting_flow_group(GroupID group) const
{
    if (group == INVALID_GROUP)
        return 0;

    int count = 0;
    for (const AgentData &agent : agents)
    {
        if (agent.waiting_flow_group == group)
            ++count;
    }
    return count;
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
    if (!ff->is_cell_physics_passable(ff->world_to_cell(a)))
        a = ff->cell_to_world(ff->world_to_cell(a));
    if (ff->is_cell_physics_passable(ff->world_to_cell(b)))
        return b;

    Vec2 lo = a, hi = b;
    for (int i = 0; i < 10; ++i)
    {
        Vec2 mid = lo + (hi - lo) * 0.5;
        if (ff->is_cell_physics_passable(ff->world_to_cell(mid)))
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
        return ff->is_cell_physics_passable(center_cell);

    const double tile = ff->tile_size();
    const double half_tile = tile * 0.5;
    const double epsilon = 1e-6;
    const int scan_radius = std::max(1, static_cast<int>(std::ceil((radius + half_tile) / tile)));

    for (int dy = -scan_radius; dy <= scan_radius; ++dy)
    {
        for (int dx = -scan_radius; dx <= scan_radius; ++dx)
        {
            Vec2i cell(center_cell.x + dx, center_cell.y + dy);
            if (ff->is_cell_physics_passable(cell))
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
            if (ff->is_cell_physics_passable(cell))
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

    Vec2i safe = ff->find_nearest_physics_passable(check);
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
            if (!ff->is_cell_physics_passable(n))
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

double SteeringSystem::movement_priority(const AgentData &agent) const
{
    Vec2 intent = safe_normalize(agent.debug_desired_dir);
    if (intent.is_zero())
        intent = safe_normalize(agent.debug_nav_dir);
    if (intent.is_zero())
        intent = safe_normalize(agent.velocity);
    Vec2 velocity_dir = safe_normalize(agent.velocity);
    if (intent.is_zero() || velocity_dir.is_zero())
        return 0.0;
    return std::clamp(velocity_dir.dot(intent), 0.0, 1.0);
}

void SteeringSystem::update_contact_push_cooldowns(double delta)
{
    if (contact_push_cooldowns.empty())
        return;

    for (auto outer = contact_push_cooldowns.begin(); outer != contact_push_cooldowns.end();)
    {
        auto &inner_map = outer->second;
        for (auto inner = inner_map.begin(); inner != inner_map.end();)
        {
            inner->second -= delta;
            if (inner->second <= 0.0)
                inner = inner_map.erase(inner);
            else
                ++inner;
        }

        if (inner_map.empty())
            outer = contact_push_cooldowns.erase(outer);
        else
            ++outer;
    }
}

bool SteeringSystem::autonomous_can_shove_idle_manual(
    const AgentData &agent,
    const AgentData &neighbor,
    const Vec2 &agent_to_neighbor) const
{
    const AgentData *idle_manual_agent = nullptr;
    const AgentData *autonomous_agent = nullptr;
    if (agent.control_mode == AgentControlMode::Manual
        && neighbor.control_mode == AgentControlMode::FlowField)
    {
        idle_manual_agent = &agent;
        autonomous_agent = &neighbor;
    }
    else if (neighbor.control_mode == AgentControlMode::Manual
        && agent.control_mode == AgentControlMode::FlowField)
    {
        idle_manual_agent = &neighbor;
        autonomous_agent = &agent;
    }
    else
    {
        return false;
    }

    if (!idle_manual_agent->active
        || idle_manual_agent->paused
        || idle_manual_agent->manual_input_dir.length_squared() > CONTACT_MANUAL_IDLE_INPUT_MAX_LENGTH_SQ
        || (idle_manual_agent->is_propelled && !idle_manual_agent->smash_stops_on_control_restore)
        || !autonomous_agent->active
        || autonomous_agent->paused
        || autonomous_agent->is_propelled
        || autonomous_agent->smash_pending
        || (!autonomous_agent->path_active && autonomous_agent->flow == nullptr)
        || is_agent_waiting_for_flow(*autonomous_agent))
    {
        return false;
    }

    // Route intent comes first so local contact avoidance cannot hide that the
    // agent's actual path continues through the manual agent.
    Vec2 autonomous_intent = autonomous_agent->debug_nav_dir;
    if (autonomous_intent.length_squared() <= CONTACT_AUTONOMOUS_INTENT_MIN_LENGTH_SQ)
        autonomous_intent = autonomous_agent->debug_desired_dir;

    double intent_length_sq = autonomous_intent.length_squared();
    if (intent_length_sq <= CONTACT_AUTONOMOUS_INTENT_MIN_LENGTH_SQ)
        return false;

    Vec2 toward_manual = autonomous_agent == &agent ? agent_to_neighbor : agent_to_neighbor * -1.0;
    double forward_dot = autonomous_intent.dot(toward_manual);
    return forward_dot > 0.0
        && forward_dot * forward_dot >= CONTACT_AUTONOMOUS_FORWARD_MIN_DOT
            * CONTACT_AUTONOMOUS_FORWARD_MIN_DOT * intent_length_sq;
}

void SteeringSystem::apply_contact_pushes(double delta)
{
    (void)delta;
    if (!grid)
        return;

    for (const AgentData &agent : agents)
    {
        if (is_drowning_agent(agent))
            continue;
        if (agent.profile.contact_push_power <= 0.0)
            continue;

        Vec2 agent_foot = agent_foot_point(agent);
        std::vector<int> neighbor_ids = grid->query_neighbors(agent_foot, agent.profile.world_radius + max_world_radius);
        for (int nid : neighbor_ids)
        {
            if (nid == agent.id)
                continue;

            auto it = id_to_index.find(nid);
            if (it == id_to_index.end())
                continue;

            const AgentData &neighbor = agents[it->second];
            if (is_drowning_agent(neighbor))
                continue;
            auto cooldowns_it = contact_push_cooldowns.find(agent.id);
            if (cooldowns_it != contact_push_cooldowns.end() && cooldowns_it->second.find(neighbor.id) != cooldowns_it->second.end())
                continue;

            double sum_radius = agent.profile.world_radius + neighbor.profile.world_radius;
            if (sum_radius <= 0.0)
                continue;

            Vec2 neighbor_foot = agent_foot_point(neighbor);
            Vec2 delta_pos = neighbor_foot - agent_foot;
            double dist_sq = delta_pos.length_squared();
            if (dist_sq > sum_radius * sum_radius)
                continue;

            Vec2 dir = safe_normalize(delta_pos);
            if (dir.is_zero())
                dir = hashed_unit_dir(agent.id);

            // Profile pressure remains the default winner. The sole exception is an
            // autonomous mover heading into an idle manual agent: in that case the
            // manual agent yields, using the same pair pressure and impulse pipeline.
            bool autonomous_shoves_idle_manual = autonomous_can_shove_idle_manual(agent, neighbor, dir);

            double agent_pressure = agent.profile.contact_push_power / std::max(0.001, neighbor.profile.contact_push_resist);
            double neighbor_pressure = neighbor.profile.contact_push_power / std::max(0.001, agent.profile.contact_push_resist);
            double net_pressure = agent_pressure - neighbor_pressure;
            if (std::abs(net_pressure) < 1e-3)
                continue;

            bool push_neighbor = autonomous_shoves_idle_manual
                ? neighbor.control_mode == AgentControlMode::Manual
                : net_pressure > 0.0;
            int target_id = push_neighbor ? neighbor.id : agent.id;
            Vec2 impulse_dir = push_neighbor ? dir : dir * -1.0;
            double force = std::abs(net_pressure);
            double cooldown = std::max(agent.profile.contact_push_cooldown, neighbor.profile.contact_push_cooldown);
            const AgentData &target = push_neighbor ? neighbor : agent;
            const AgentData &source = push_neighbor ? agent : neighbor;

            queue_smash_impulse(
                target_id,
                impulse_dir,
                force,
                target.profile.contact_push_friction_loss,
                0.0,
                false,
                1.0,
                target.profile.contact_control_suppression_seconds,
                false,
                static_cast<int>(ImpulseQueuePriority::Contact),
                false,
                source.profile.contact_push_shows_control_impaired_feedback);
            contact_push_cooldowns[agent.id][neighbor.id] = cooldown;
            contact_push_cooldowns[neighbor.id][agent.id] = cooldown;
        }
    }
}

bool SteeringSystem::is_agent_waiting_for_flow(const AgentData &agent) const
{
    GroupID wait_group = (agent.waiting_flow_group != INVALID_GROUP) ? agent.waiting_flow_group : agent.group;
    bool flow_driven = (agent.waiting_flow_group != INVALID_GROUP)
        || (!agent.path_active && (agent.phase == AgentPhase::FlowIn || agent.phase == AgentPhase::FlowOut));
    AgentManager *wait_mgr = agent_manager ? agent_manager : ffcore::get_global_agent_manager();
    return flow_driven
        && wait_group != INVALID_GROUP
        && wait_mgr
        && wait_mgr->get_group_flow_wait(wait_group) != GROUP_FLOW_WAIT_NONE;
}

void SteeringSystem::apply_traffic_right_of_way(double delta)
{
    (void)delta;
    const auto &cfg = globalconfig();
    if (!cfg.traffic_right_of_way_enabled || cfg.traffic_push_force <= 0.0 || !grid)
        return;

    flow_waiting_by_agent_index_scratch.resize(agents.size());
    for (int i = 0; i < static_cast<int>(agents.size()); ++i)
        flow_waiting_by_agent_index_scratch[i] = is_agent_waiting_for_flow(agents[i]) ? 1 : 0;

    traffic_right_of_way_resolver.collect_push_requests(
        agents,
        id_to_index,
        grid,
        flow_waiting_by_agent_index_scratch,
        max_world_radius,
        cfg.traffic_push_force,
        traffic_push_requests_scratch);

    for (const TrafficPushRequest &request : traffic_push_requests_scratch)
    {
        queue_smash_impulse(
            request.target_agent_id,
            request.direction,
            request.force,
            0.65,
            0.0,
            false,
            1.0,
            cfg.traffic_control_lock_seconds,
            false,
            static_cast<int>(ImpulseQueuePriority::Traffic));
        traffic_right_of_way_resolver.mark_target_pushed(
            request.target_agent_id,
            cfg.traffic_push_cooldown);
    }
}

Vec2 SteeringSystem::force_voisine(const AgentData &agent)
{
    const auto &cfg = globalconfig();
    if (!grid)
        return Vec2(0, 0);

    Vec2 agent_foot = agent_foot_point(agent);
    std::vector<int> neighbor_ids = grid->query_neighbors(agent_foot, agent.profile.world_radius + max_world_radius);

    // Phase-1 diagnostic: remember the biggest neighbor list handed back this frame.
    if (cfg.debug_nav_frame_lag_ms > 0.0 && neighbor_ids.size() > debug_max_neighbor_query_size)
        debug_max_neighbor_query_size = neighbor_ids.size();

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
    double self_priority = movement_priority(agent);
    double priority_bias = std::clamp(cfg.priority_separation_bias, 0.0, 1.0);
    double priority_scale_sum = 0.0;

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

        double neighbor_priority = movement_priority(n);
        double priority_delta = self_priority - neighbor_priority;
        double yield_multiplier = std::clamp(1.0 - priority_delta * priority_bias, 0.65, 1.35);
        weight *= yield_multiplier;

        separation_force = separation_force + (diff * (1.0 / dist)) * falloff * weight;
        priority_scale_sum += yield_multiplier;
        count++;
    }

    if (count > 0)
        separation_force = separation_force * (1.0 / (double)count);

    if (!separation_force.is_zero())
    {
        double priority_scale = count > 0 ? std::clamp(priority_scale_sum / (double)count, 0.65, 1.35) : 1.0;
        separation_force = safe_normalize(separation_force) * cfg.separation_strength * priority_scale;
    }

    return separation_force;
}

void SteeringSystem::register_static_obstacle(int id, const Vec2 &position, double radius, double push_strength)
{
    if (id < 0)
        return;
    if (!std::isfinite(position.x) || !std::isfinite(position.y))
    {
        godot::UtilityFunctions::printerr(
            "register_static_obstacle: non-finite position id=", id,
            " pos=(", position.x, ",", position.y, ")");
        return;
    }
    if (!std::isfinite(radius) || radius <= 0.0)
        radius = 1e-3; // clamp to a safe positive minimum rather than rejecting

    // Replace/update: drop any existing grid entry first so we never duplicate ids.
    auto existing = static_obstacles.find(id);
    if (existing != static_obstacles.end())
        static_obstacle_grid.remove(id);

    StaticObstacle obs;
    obs.id = id;
    obs.position = position;
    obs.radius = radius;
    obs.push_strength = (std::isfinite(push_strength) && push_strength >= 0.0) ? push_strength : 1.0;

    static_obstacles[id] = obs;
    static_obstacle_grid.insert(id, position);
    max_static_obstacle_radius = std::max(max_static_obstacle_radius, radius);
}

void SteeringSystem::unregister_static_obstacle(int id)
{
    auto it = static_obstacles.find(id);
    if (it == static_obstacles.end())
        return;
    static_obstacles.erase(it);
    static_obstacle_grid.remove(id);

    // Recompute the cached max radius from whatever remains.
    max_static_obstacle_radius = 0.0;
    for (const auto &entry : static_obstacles)
        max_static_obstacle_radius = std::max(max_static_obstacle_radius, entry.second.radius);
}

void SteeringSystem::clear_static_obstacles()
{
    static_obstacles.clear();
    static_obstacle_grid.clear();
    max_static_obstacle_radius = 0.0;
}

bool SteeringSystem::has_static_obstacle(int id) const
{
    return static_obstacles.find(id) != static_obstacles.end();
}

Vec2 SteeringSystem::static_obstacle_repulsion_force(const AgentData &agent)
{
    if (static_obstacles.empty())
        return Vec2(0, 0);

    const auto &cfg = globalconfig();
    Vec2 agent_foot = agent_foot_point(agent);
    double query_radius = agent.profile.world_radius + max_static_obstacle_radius + std::max(0.0, cfg.static_obstacle_query_padding);

    static std::vector<int> nearby; // reused scratch buffer; query() clears it
    static_obstacle_grid.query(agent_foot, query_radius, nearby);
    if (nearby.empty())
        return Vec2(0, 0);

    Vec2 force(0, 0);
    double resist = std::max(0.001, agent.profile.crowd_resist_strength);
    int contact_count = 0;
    int first_contact_id = -1;
    double first_contact_dist = 0.0;
    double first_contact_sum_radius = 0.0;

    for (int oid : nearby)
    {
        auto it = static_obstacles.find(oid);
        if (it == static_obstacles.end())
            continue;
        const StaticObstacle &obs = it->second;

        double sum_radius = agent.profile.world_radius + obs.radius;
        if (sum_radius <= 0.0)
            continue;

        Vec2 diff = agent_foot - obs.position;
        double dist = diff.length();
        Vec2 dir;
        if (dist < 0.001)
        {
            dir = hashed_unit_dir(agent.id);
            dist = 0.001;
        }
        else
        {
            dir = diff * (1.0 / dist);
        }

        if (dist >= sum_radius)
            continue;

        double penetration_ratio = std::clamp(1.0 - dist / sum_radius, 0.0, 1.0);
        double falloff = penetration_ratio * penetration_ratio;
        double weight = std::max(0.0, obs.push_strength) / resist;
        force = force + dir * falloff * weight;

        if (contact_count == 0)
        {
            first_contact_id = obs.id;
            first_contact_dist = dist;
            first_contact_sum_radius = sum_radius;
        }
        contact_count++;
    }

    Vec2 result = force.is_zero() ? Vec2(0, 0) : safe_normalize(force) * cfg.static_obstacle_repulsion_strength;

    // Throttled debug: only when the flag is on, only on actual contact, and at most
    // once every couple seconds per agent. Never spams per tick.
    if (cfg.debug_static_obstacles && contact_count > 0)
    {
        static std::unordered_map<int, double> last_log_time;
        static double log_clock = 0.0;
        log_clock += 1.0; // coarse frame counter; gate on a frame interval
        double &last = last_log_time[agent.id];
        if (log_clock - last >= 120.0) // ~2s at 60fps
        {
            last = log_clock;
            godot::UtilityFunctions::print(
                "[static_obstacle] agent=", agent.id,
                " radius=", agent.profile.world_radius,
                " queried=", (int)nearby.size(),
                " contacts=", contact_count,
                " first_obs=", first_contact_id,
                " dist=", first_contact_dist,
                " sum_radius=", first_contact_sum_radius,
                " force_len=", safe_len(result));
        }
    }

    return result;
}

void SteeringSystem::resolve_static_obstacle_overlap(AgentData &agent)
{
    if (static_obstacles.empty())
        return;

    Vec2 agent_foot = agent_foot_point(agent);
    const auto &cfg = globalconfig();
    double query_radius = agent.profile.world_radius + max_static_obstacle_radius + std::max(0.0, cfg.static_obstacle_query_padding);

    static std::vector<int> nearby; // reused scratch buffer; query() clears it
    static_obstacle_grid.query(agent_foot, query_radius, nearby);
    if (nearby.empty())
        return;

    // Push the foot point out of every overlapping static circle. A couple of relaxation
    // passes resolve the (rare) case of overlapping multiple obstacles at once. This is a
    // hard positional guarantee — the agent cannot end the frame inside an obstacle — and
    // is what makes flow-driven agents (monsters) blocked, not just softly nudged.
    const int relaxation_passes = 2;
    for (int pass = 0; pass < relaxation_passes; ++pass)
    {
        bool moved = false;
        for (int oid : nearby)
        {
            auto it = static_obstacles.find(oid);
            if (it == static_obstacles.end())
                continue;
            const StaticObstacle &obs = it->second;

            double sum_radius = agent.profile.world_radius + obs.radius;
            if (sum_radius <= 0.0)
                continue;

            Vec2 diff = agent_foot - obs.position;
            double dist = diff.length();
            if (dist >= sum_radius)
                continue;

            Vec2 dir = (dist < 0.001) ? hashed_unit_dir(agent.id) : diff * (1.0 / dist);
            double push = sum_radius - dist; // depth to clear
            agent_foot = agent_foot + dir * push;
            moved = true;
        }
        if (!moved)
            break;
    }

    // Convert the corrected foot point back into the agent body position (foot offset).
    agent.position = agent_foot - Vec2(0, agent.profile.foot_offset_y);
    // Kill inward velocity component so the agent doesn't keep ramming the obstacle next
    // frame; sliding velocity (tangential) is preserved by the soft steering force.
    for (int oid : nearby)
    {
        auto it = static_obstacles.find(oid);
        if (it == static_obstacles.end())
            continue;
        const StaticObstacle &obs = it->second;
        Vec2 diff = agent_foot_point(agent) - obs.position;
        double dist = diff.length();
        if (dist >= agent.profile.world_radius + obs.radius || dist < 0.001)
            continue;
        Vec2 normal = diff * (1.0 / dist);
        double into = agent.velocity.dot(normal);
        if (into < 0.0)
            agent.velocity = agent.velocity - normal * into;
    }
}

void SteeringSystem::apply_bottleneck_traffic(AgentData &agent, FlowField *ff, Vec2 &target_velocity, double delta)
{
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
    int zone_index = ff->bottleneck_zone_at_cell(cell);

    // Tile-based bottleneck gating:
    // RB = bottleneck core tile, BZ = surrounding bottleneck zone.
    // Agents inside RB own the passage by position, not by a fragile reservation owner.
    // Agents that already crossed the RB ignore the rest of that BZ until they leave it.
    if (core_index >= 0)
    {
        agent.completed_bottleneck = core_index;
        agent.debug_bottleneck_wait = false;
        return;
    }

    if (agent.completed_bottleneck >= 0)
    {
        if (zone_index == agent.completed_bottleneck)
        {
            agent.debug_bottleneck_wait = false;
            return;
        }
        agent.completed_bottleneck = -1;
    }

    agent.debug_bottleneck_wait = false;
    if (zone_index < 0)
        return;

    auto field_it = bottleneck_core_occupancy.find(ff);
    if (field_it == bottleneck_core_occupancy.end())
        return;

    auto core_it = field_it->second.find(zone_index);
    if (core_it == field_it->second.end() || core_it->second <= 0)
        return;

    agent.debug_bottleneck_wait = true;
    target_velocity = target_velocity * std::clamp(cfg.bottleneck_wait_speed_ratio, 0.0, 1.0);
}

Vec2 SteeringSystem::desired_velocity_for_flow(const AgentData &agent, FlowField *ff, const Vec2 &nav_dir, const Vec2 &wall_repel, const Vec2 &agent_separation, const Vec2 &static_obstacle_repel, double target_speed) const
{
    const auto &cfg = globalconfig();
    // Local avoidance = pure crowd separation + static obstacle repulsion. Both shape
    // the desired velocity, but they are kept as distinct inputs so callers can use
    // pure agent_separation for crowd-vs-wall comparisons.
    Vec2 local_avoidance = agent_separation + static_obstacle_repel;
    Vec2 nav = safe_normalize(nav_dir);
    if (nav.is_zero())
    {
        Vec2 fallback = safe_normalize(wall_repel + local_avoidance);
        return fallback * target_speed;
    }

    Vec2 correction = wall_repel + local_avoidance;
    Vec2i cell = ff ? ff->world_to_cell(agent_foot_point(agent)) : Vec2i(-1, -1);
    bool in_bottleneck_area = !cfg.effective_debug_disable_bottlenecks() &&
                              ff && (ff->bottleneck_core_at_cell(cell) >= 0 || ff->bottleneck_zone_at_cell(cell) >= 0);

    if (in_bottleneck_area)
    {
        double forward = correction.dot(nav);
        Vec2 lateral = correction - nav * forward;

        double min_forward = -cfg.flow_weight * std::clamp(cfg.bottleneck_backward_push_ratio, 0.0, 1.0);
        if (forward < min_forward)
            forward = min_forward;

        double max_forward = cfg.flow_weight;
        double max_lateral = cfg.flow_weight * std::max(0.0, cfg.bottleneck_lateral_push_ratio);

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

void SteeringSystem::set_agent_position(int id, const Vec2 &position, bool clear_velocity)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    if (!std::isfinite(position.x) || !std::isfinite(position.y))
        return;

    AgentData &agent = agents[it->second];
    Vec2 old_foot = agent_foot_point(agent);
    agent.position = position;
    if (clear_velocity)
    {
        agent.velocity = Vec2(0, 0);
        agent.smash_force = Vec2(0, 0);
        clear_pending_smash_slot(agent);
        agent.is_propelled = false;
        agent.propelled_timer = 0.0;
    }
    agent.was_in_t2 = false;
    agent.target_radius_timer = 0.0;
    agent.lost_timer = 0.0;
    agent.active_bottleneck = -1;
    agent.completed_bottleneck = -1;
    agent.debug_in_bottleneck_state = false;
    agent.debug_bottleneck_wait = false;
    if (grid)
        grid->update(agent.id, old_foot, agent_foot_point(agent));
}

void SteeringSystem::set_agent_traffic_state(int id, std::int64_t traffic_group_id, int traffic_priority)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    AgentData &agent = agents[it->second];
    if (traffic_group_id <= 0)
    {
        agent.traffic_group_id = 0;
        agent.traffic_priority = 0;
        return;
    }

    agent.traffic_group_id = traffic_group_id;
    agent.traffic_priority = std::max(0, traffic_priority);
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
    queue_smash_impulse(id, direction, force, friction_loss, delay, detach_flow, control_suppression, control_suppression_duration, true, static_cast<int>(ImpulseQueuePriority::Gameplay));
}

void SteeringSystem::apply_navigation_preserving_impulse(int id, const Vec2 &direction, double force, double friction_loss)
{
    // Reuse the established impulse damping/collision pipeline, but keep the
    // agent's target velocity active as an independent movement contribution.
    queue_smash_impulse(id, direction, force, friction_loss, 0.0, false, 0.0, 0.0, true, static_cast<int>(ImpulseQueuePriority::Gameplay), true);
}

int SteeringSystem::create_external_velocity_source()
{
    return next_external_velocity_source_id++;
}

void SteeringSystem::set_agent_external_velocity(int id, int source_id, const Vec2 &velocity, double response_seconds, double expiry_seconds)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end() || source_id < 0)
        return;

    AgentData &agent = agents[it->second];
    if (is_drowning_agent(agent))
        return;
    agent.external_velocity.refresh_source(source_id, velocity, response_seconds, expiry_seconds);
}

void SteeringSystem::release_agent_external_velocity(int id, int source_id)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    agents[it->second].external_velocity.release_source(source_id);
}

void SteeringSystem::clear_pending_smash_slot(AgentData &agent)
{
    agent.pending_smash = Vec2(0, 0);
    agent.smash_pending = false;
    agent.smash_delay = 0.0;
    agent.pending_smash_friction = -1.0;
    agent.pending_smash_control_suppression = 1.0;
    agent.pending_smash_control_suppression_duration = 0.0;
    agent.pending_smash_preserves_control = false;
    agent.pending_smash_stops_on_control_restore = false;
    agent.pending_smash_shows_control_impaired_feedback = true;
    agent.pending_smash_priority = static_cast<int>(ImpulseQueuePriority::None);
}

void SteeringSystem::queue_smash_impulse(int id, const Vec2 &direction, double force, double friction_loss, double delay, bool detach_flow, double control_suppression, double control_suppression_duration, bool respect_weapon_immune, int impulse_priority, bool preserve_control, bool show_control_impaired_feedback)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    AgentData &agent = agents[it->second];
    int sanitized_priority = std::max(static_cast<int>(ImpulseQueuePriority::None), impulse_priority);
    if (agent.smash_pending && sanitized_priority < agent.pending_smash_priority)
        return;
    if (respect_weapon_immune && agent.profile.weapon_immune)
        return;
    if (is_drowning_agent(agent))
        return;
    if (!std::isfinite(direction.x) || !std::isfinite(direction.y) || !std::isfinite(force))
    {
        godot::UtilityFunctions::printerr(
            "apply_smash_impulse: invalid input agent=", id,
            " direction=(", direction.x, ",", direction.y, ") force=", force);
        return;
    }
    Vec2 dir = safe_normalize(direction.is_zero() ? hashed_unit_dir(agent.id) : direction);
    // Per-agent inertia: heavier monsters divide the incoming impulse so they are
    // launched less far (smash_resist = 2.0 => half the knockback).
    double resist = std::max(0.001, agent.profile.smash_resist);
    Vec2 smash = dir * (std::max(0.0, force) / resist);

    const auto &cfg = globalconfig();
    double len = safe_len(smash);
    if (len > cfg.smash_cap)
        smash = smash * (cfg.smash_cap / len);

    agent.smash_delay = std::max(0.0, delay);
    agent.pending_smash = smash;
    agent.pending_smash_friction = std::clamp(friction_loss, 0.0, 1.0);
    agent.pending_smash_control_suppression = std::clamp(control_suppression, 0.0, 1.0);
    agent.pending_smash_control_suppression_duration = std::max(0.0, control_suppression_duration);
    agent.pending_smash_preserves_control = preserve_control;
    agent.pending_smash_stops_on_control_restore = sanitized_priority == static_cast<int>(ImpulseQueuePriority::Contact)
        && agent.pending_smash_control_suppression_duration > 0.0;
    agent.pending_smash_shows_control_impaired_feedback = show_control_impaired_feedback;
    agent.pending_smash_priority = sanitized_priority;
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
        if (is_drowning_agent(agent))
            continue;
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
        if (is_drowning_agent(agent))
            continue;
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

void SteeringSystem::spawn_aoe_zone(const Vec2 &pos, const Vec2 &direction, double radius, double angle_degrees, double duration, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes, const Vec2 &follow_offset, int damage)
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
    zone.damage = std::max(0, damage);
    zone.time_left = duration;

    active_aoes.push_back(std::move(zone));
}

int SteeringSystem::start_continuous_aoe(const Vec2 &pos, const Vec2 &direction, double radius, double angle_degrees, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes, const Vec2 &follow_offset, int damage, double damage_frequency, double repulse_frequency)
{
    if (!std::isfinite(pos.x) || !std::isfinite(pos.y) || !std::isfinite(direction.x) || !std::isfinite(direction.y) || !std::isfinite(radius) || !std::isfinite(force) || !std::isfinite(follow_offset.x) || !std::isfinite(follow_offset.y) || !std::isfinite(damage_frequency) || !std::isfinite(repulse_frequency))
        return -1;
    if (radius <= 0.0 || damage_frequency <= 0.0 || repulse_frequency <= 0.0)
        return -1;

    Vec2 facing = safe_normalize(direction);
    double clamped_angle = std::clamp(angle_degrees, 0.0, 360.0);
    if (clamped_angle < 360.0 && facing.is_zero())
        return -1;

    ActiveAoE zone;
    zone.pos = pos;
    zone.follow_offset = follow_offset;
    zone.direction = clamped_angle < 360.0 ? facing : Vec2(0, 0);
    zone.radius = radius;
    zone.angle_degrees = clamped_angle;
    zone.force = force;
    zone.friction_loss = friction_loss;
    zone.falloff = std::max(0.0, falloff);
    zone.detach_flow = detach_flow;
    zone.control_suppression = control_suppression;
    zone.control_suppression_duration = control_suppression_duration;
    zone.ignored_agent_id = ignored_agent_id;
    zone.owner_id = ignored_agent_id;
    zone.affected_smash_classes = affected_smash_classes;
    zone.damage = std::max(0, damage);
    zone.time_left = 1.0;
    zone.continuous_id = next_continuous_aoe_id++;
    zone.damage_frequency = damage_frequency;
    zone.repulse_frequency = repulse_frequency;
    active_aoes.push_back(std::move(zone));
    return active_aoes.back().continuous_id;
}

bool SteeringSystem::update_continuous_aoe(int continuous_id, const Vec2 &direction, const Vec2 &follow_offset)
{
    for (ActiveAoE &zone : active_aoes)
    {
        if (zone.continuous_id != continuous_id)
            continue;
        Vec2 facing = safe_normalize(direction);
        if (zone.angle_degrees < 360.0 && facing.is_zero())
            return false;
        if (zone.angle_degrees < 360.0)
            zone.direction = facing;
        zone.follow_offset = follow_offset;
        return true;
    }
    return false;
}

void SteeringSystem::stop_continuous_aoe(int continuous_id)
{
    active_aoes.erase(std::remove_if(active_aoes.begin(), active_aoes.end(),
                                     [continuous_id](const ActiveAoE &zone) { return zone.continuous_id == continuous_id; }),
                      active_aoes.end());
}

void SteeringSystem::apply_area_damage(const Vec2 &pos, double radius, int ignored_agent_id, int affected_smash_classes, int damage)
{
    if (!grid || radius <= 0.0 || damage <= 0)
        return;

    auto neighbors = grid->query_neighbors(pos, radius + max_fight_query_padding);
    for (int nid : neighbors)
    {
        if (nid == ignored_agent_id)
            continue;
        auto it = id_to_index.find(nid);
        if (it == id_to_index.end())
            continue;

        const AgentData &agent = agents[it->second];
        if (is_drowning_agent(agent))
            continue;
        if (agent.profile.weapon_immune)
            continue;
        if (affected_smash_classes != 0 && (agent.profile.smash_class & affected_smash_classes) == 0)
            continue;

        Vec2 fight_center = agent_fight_center(agent);
        if (point_aabb_distance(pos, fight_center, agent.profile.fight_half_w, agent.profile.fight_half_h) > radius)
            continue;
        damage_events.push_back(DamageEvent{nid, damage, fight_center});
    }
}

void SteeringSystem::apply_damage_to_agent(int id, int damage, int affected_smash_classes)
{
    if (damage <= 0)
        return;

    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;

    const AgentData &agent = agents[it->second];
    if (is_drowning_agent(agent))
        return;
    if (agent.profile.weapon_immune)
        return;
    if (affected_smash_classes != 0 && (agent.profile.smash_class & affected_smash_classes) == 0)
        return;

    damage_events.push_back(DamageEvent{id, damage, agent_fight_center(agent)});
}

std::vector<DamageEvent> SteeringSystem::take_damage_events()
{
    std::vector<DamageEvent> out;
    out.swap(damage_events);
    return out;
}

void SteeringSystem::set_agent_never_rest(int id, bool value)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    agents[it->second].never_rest = value;
}

void SteeringSystem::set_agent_paused(int id, bool value)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    AgentData &a = agents[it->second];
    a.paused = value;
    if (value)
        a.velocity = Vec2(0, 0);
}

void SteeringSystem::set_agent_phase(int id, AgentPhase phase, float eating_seconds)
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return;
    AgentData &a = agents[it->second];
    a.phase = phase;
    a.eating_seconds = eating_seconds;
    if (phase == AgentPhase::Drowning)
    {
        a.external_velocity.clear();
        clear_pending_smash_slot(a);
        a.smash_force = Vec2(0, 0);
        a.smash_friction = -1.0;
        a.smash_control_suppression = 1.0;
        a.smash_control_suppression_timer = 0.0;
        a.smash_preserves_control = false;
        a.smash_stops_on_control_restore = false;
        a.smash_shows_control_impaired_feedback = true;
        a.smash_just_reset = false;
        a.is_propelled = false;
        a.propelled_timer = 0.0;
    }
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

    // --- Phase-1 diagnostic probe (debug-gated) --------------------------------
    // update_all() is the only per-frame hot path with no timing, so a rare, sudden,
    // silent near-freeze during day with many agents is invisible to the GDScript lag
    // warnings. Time the whole sim pass and, on a spike over the nav-frame threshold,
    // dump grid occupancy so a spatial-grid ID leak (grid_ids >> live agents) or a hot
    // cell is caught in the act. Fires on the threshold regardless of the debug-draw
    // toggle, matching the GDScript lag detectors (debug_nav_total_frame_lag et al.)
    // which are tuning thresholds applied whether or not Debug Enabled is on — so the
    // rare spike is caught even in a normal (non-debug) session. Set the threshold to 0
    // to disable.
    const bool debug_probe_enabled = cfg.debug_nav_frame_lag_ms > 0.0;
    std::chrono::steady_clock::time_point probe_start;
    if (debug_probe_enabled)
    {
        debug_max_neighbor_query_size = 0;
        probe_start = std::chrono::steady_clock::now();
    }

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
        // Authoritative per-frame cone membership for continuous weapons.
        // Cooldown entries exist only while that agent remains inside.
        std::unordered_set<int> current_inside_ids;
        if (zone.continuous_id >= 0)
        {
            for (auto &cooldown : zone.damage_cooldowns)
                cooldown.second -= delta;
            for (auto &cooldown : zone.repulse_cooldowns)
                cooldown.second -= delta;
        }
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
            if (zone.continuous_id < 0 && zone.hit_ids.count(nid) != 0)
            {
                continue;
            }

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

            if (zone.continuous_id >= 0)
            {
                current_inside_ids.insert(nid);
            }

            if (zone.continuous_id >= 0)
            {
                auto repulse_it = zone.repulse_cooldowns.find(nid);
                bool repulse_ready = repulse_it == zone.repulse_cooldowns.end() || repulse_it->second <= 0.0;
                if (repulse_ready)
                {
                    double base = std::max(0.0, 1.0 - dist / zone.radius);
                    double attenuation = std::pow(base, zone.falloff);
                    apply_smash_impulse(nid, impulse_dir, zone.force * attenuation, zone.friction_loss, 0.0, zone.detach_flow, zone.control_suppression, zone.control_suppression_duration);
                    zone.repulse_cooldowns[nid] = zone.repulse_frequency;
                }

                auto damage_it = zone.damage_cooldowns.find(nid);
                bool damage_ready = damage_it == zone.damage_cooldowns.end() || damage_it->second <= 0.0;
                if (damage_ready)
                {
                    if (zone.damage > 0 && !is_drowning_agent(agent))
                        damage_events.push_back(DamageEvent{nid, zone.damage, fight_center});
                    zone.damage_cooldowns[nid] = zone.damage_frequency;
                }
            }
            else
            {
                double base = std::max(0.0, 1.0 - dist / zone.radius);
                double attenuation = std::pow(base, zone.falloff);
                apply_smash_impulse(nid, impulse_dir, zone.force * attenuation, zone.friction_loss, 0.0, zone.detach_flow, zone.control_suppression, zone.control_suppression_duration);
                if (zone.damage > 0 && !is_drowning_agent(agent))
                    damage_events.push_back(DamageEvent{nid, zone.damage, fight_center});
                zone.hit_ids.insert(nid);
            }
        }

        if (zone.continuous_id >= 0)
        {
            // Each effect is throttled independently during one uninterrupted overlap.
            // Leaving the cone clears both, so the next entry applies both immediately.
            for (auto cooldown_it = zone.damage_cooldowns.begin(); cooldown_it != zone.damage_cooldowns.end();)
            {
                if (current_inside_ids.count(cooldown_it->first) == 0)
                    cooldown_it = zone.damage_cooldowns.erase(cooldown_it);
                else
                    ++cooldown_it;
            }
            for (auto cooldown_it = zone.repulse_cooldowns.begin(); cooldown_it != zone.repulse_cooldowns.end();)
            {
                if (current_inside_ids.count(cooldown_it->first) == 0)
                    cooldown_it = zone.repulse_cooldowns.erase(cooldown_it);
                else
                    ++cooldown_it;
            }
        }

        if (zone.continuous_id < 0)
            zone.time_left -= delta;
    }
    active_aoes.erase(std::remove_if(active_aoes.begin(), active_aoes.end(),
                                     [](const ActiveAoE &z) { return z.continuous_id < 0 && z.time_left <= 0.0; }),
                      active_aoes.end());

    update_contact_push_cooldowns(delta);
    traffic_right_of_way_resolver.update_cooldowns(delta);
    apply_contact_pushes(delta);
    apply_traffic_right_of_way(delta);

    for (auto &a : agents)
    {
        if (is_drowning_agent(a))
        {
            clear_pending_smash_slot(a);
            a.smash_force = Vec2(0, 0);
            a.smash_just_reset = false;
            a.is_propelled = false;
            a.propelled_timer = 0.0;
            a.smash_friction = -1.0;
            a.smash_control_suppression = 1.0;
            a.smash_control_suppression_timer = 0.0;
            a.smash_preserves_control = false;
            a.smash_stops_on_control_restore = false;
            a.smash_shows_control_impaired_feedback = true;
            continue;
        }
        if (a.smash_pending)
        {
            a.smash_delay -= delta;
            if (a.smash_delay <= 0.0)
            {
                a.smash_force = a.pending_smash;
                a.smash_friction = a.pending_smash_friction;
                a.smash_control_suppression = a.pending_smash_control_suppression;
                a.smash_control_suppression_timer = a.pending_smash_control_suppression_duration;
                a.smash_preserves_control = a.pending_smash_preserves_control;
                a.smash_stops_on_control_restore = a.pending_smash_stops_on_control_restore;
                a.smash_shows_control_impaired_feedback = a.pending_smash_shows_control_impaired_feedback;
                clear_pending_smash_slot(a);
                a.smash_just_reset = true;
            }
        }
    }

    for (auto &a : agents)
    {
        if (is_drowning_agent(a))
        {
            // Velocity for drowning agents is owned entirely by the drift pass
            // below (the directional-cell-field branch). Damping it here as well
            // zeroed the drift every frame before the per-frame lerp could build
            // it up — that was the "stuck on the edge tile" freeze. Only clear the
            // smash residue so the smash pipeline keeps ignoring drowning agents.
            a.smash_force = Vec2(0, 0);
            continue;
        }
        if (a.smash_control_suppression_timer > 0.0)
            a.smash_control_suppression_timer = std::max(0.0, a.smash_control_suppression_timer - delta);

        if (a.is_propelled && a.smash_stops_on_control_restore && a.smash_control_suppression_timer <= 0.0)
        {
            a.is_propelled = false;
            a.propelled_timer = 0.0;
            a.smash_force = Vec2(0, 0);
            a.smash_friction = -1.0;
            a.smash_control_suppression = 1.0;
            a.smash_preserves_control = false;
            a.smash_stops_on_control_restore = false;
            a.smash_shows_control_impaired_feedback = true;
            a.velocity = Vec2(0, 0);
        }

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
                a.smash_preserves_control = false;
                a.smash_stops_on_control_restore = false;
                a.smash_shows_control_impaired_feedback = true;
                a.velocity = Vec2(0, 0);
            }
        }
        else
        {
            a.smash_force = Vec2(0, 0);
        }
    }

    bottleneck_core_occupancy.clear();
    if (!cfg.effective_debug_disable_bottlenecks())
    {
        for (const auto &a : agents)
        {
            FlowField *ff = a.flow ? a.flow : default_flow;
            if (!ff || !ff->is_ready())
                continue;
            Vec2i cell = ff->world_to_cell(agent_foot_point(a));
            int core_index = ff->bottleneck_core_at_cell(cell);
            if (core_index >= 0)
                bottleneck_core_occupancy[ff][core_index] += 1;
        }
    }

    for (auto &a : agents)
    {
        a.external_velocity.update(delta);

        // A paused agent freezes autonomous navigation, but contact impulses are
        // still allowed to displace it so dialog villagers do not become walls.
        if (a.paused)
        {
            if (a.is_propelled)
            {
                FlowField *paused_nav = a.flow ? a.flow : default_flow;
                if (paused_nav && !paused_nav->is_ready())
                    paused_nav = nullptr;
                Vec2 offset(0, a.profile.foot_offset_y);
                Vec2 old_pos = a.position;
                Vec2 step = terrain_scaled_step(a, paused_nav, a.velocity, delta);
                a.position = apply_walk_with_walls(a, step, paused_nav);
                if (paused_nav)
                    ultimate_wall_correction(a, paused_nav, delta);
                resolve_static_obstacle_overlap(a);
                grid->update(a.id, old_pos + offset, agent_foot_point(a));
                a.update_motion_state(delta, cfg, safe_len(a.velocity) > 1.0);
                continue;
            }
            a.velocity = Vec2(0, 0);
            a.update_motion_state(delta, cfg);
            continue;
        }

        // Lazy flow-field wait: the agent's routing field is still queued or being
        // recomputed. Freeze in place (like paused) so it neither drifts nor follows a
        // stale field; the debug label reads "ff wait" / "ff being computed". Its phase
        // (flow in / flow out) is untouched, so it resumes exactly where it left off once
        // the field is applied. Only flow-driven agents freeze: spawn-waiting agents (no
        // group/flow yet, stamped via waiting_flow_group) and agents actively on a flow.
        // A*-path followers and eating agents (flow detached) are unaffected.
        {
            if (is_agent_waiting_for_flow(a))
            {
                a.velocity = Vec2(0, 0);
                a.update_motion_state(delta, cfg);
                continue;
            }
        }

        const bool is_manual = a.control_mode == AgentControlMode::Manual;
        FlowField *nav = a.flow ? a.flow : default_flow;
        if (nav && !nav->is_ready())
            nav = nullptr;

        if (is_drowning_agent(a))
        {
            Vec2 offset(0, a.profile.foot_offset_y);
            // Single owner of drowning velocity. Exponentially relax velocity toward
            // the pool-center drift target: residual impact/propel velocity bleeds off
            // fast (a smashed monster can't be flung out of the water) while the bounded
            // drift ramps up and then holds steady. This replaces the old two-pass scheme
            // where a separate damping pass zeroed the drift before it could accumulate.
            Vec2 target_velocity = directional_cell_field_velocity_for_agent(a);
            const double drift_relax = std::exp(-DROWNING_VELOCITY_DAMPING_PER_SEC * delta);
            a.velocity = target_velocity + (a.velocity - target_velocity) * drift_relax;
            // Preserve the original rest behaviour: only snap to a hard stop when there
            // is no drift pulling the agent and it has effectively stopped. With an active
            // drift (>= stop speed) the velocity is never zeroed, so it can build/hold.
            if (safe_len(target_velocity) < DROWNING_STOP_SPEED && safe_len(a.velocity) < DROWNING_STOP_SPEED)
                a.velocity = Vec2(0, 0);
            Vec2 old_pos = a.position;
            Vec2 step = terrain_scaled_step(a, nav, a.velocity, delta);
            a.position = apply_walk_with_walls(a, step, nav);
            if (nav)
                ultimate_wall_correction(a, nav, delta);
            resolve_static_obstacle_overlap(a);
            grid->update(a.id, old_pos + offset, agent_foot_point(a));
            a.debug_nav_dir = Vec2(0, 0);
            a.debug_wall_repel = Vec2(0, 0);
            a.debug_separation = Vec2(0, 0);
            a.debug_desired_dir = safe_normalize(a.velocity);
            a.debug_target_velocity = target_velocity;
            a.update_motion_state(delta, cfg, safe_len(a.velocity) > 1.0);
            continue;
        }

        bool force_motion_state = false;

        Vec2 wall_repel(0, 0);
        if (nav)
            wall_repel = wall_repulsion_force(a, nav);

        // Pure agent-agent crowd separation. Kept distinct from static obstacle repulsion
        // so downstream crowd logic (wall-stuck detector, debug_separation) stays clean.
        Vec2 agent_separation = force_voisine(a);
        // Soft static obstacle repulsion (turrets etc. register as generic obstacles).
        Vec2 static_obstacle_repel = static_obstacle_repulsion_force(a);
        // Combined soft local avoidance used by branches that just want "push me out of
        // everything local". Hard depenetration passes after integration guarantee
        // blocking even when these soft terms are damped by lerp/momentum.
        Vec2 local_avoidance = agent_separation + static_obstacle_repel;

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
                    // Arrived agents must keep yielding to neighbors / static obstacles,
                    // otherwise several monsters reaching the same final A* cell (e.g. the
                    // same plant) stack on top of each other. When there's local pressure
                    // drift softly away at min speed; only settle to a full stop once the
                    // area is clear.
                    Vec2 arrival_avoidance = agent_separation + static_obstacle_repel;
                    Vec2 target_velocity = arrival_avoidance.is_zero()
                                               ? Vec2(0, 0)
                                               : safe_normalize(arrival_avoidance) * a.max_speed * cfg.min_speed_fraction;
                    a.velocity = a.velocity.lerp(target_velocity, cfg.lerp_general);
                }
                a.debug_separation = agent_separation;
                Vec2 old_pos = a.position;
                Vec2 step = terrain_scaled_step(a, nav, a.velocity, delta);
                a.position = apply_walk_with_walls(a, step, nav);
                if (nav)
                    ultimate_wall_correction(a, nav, delta);
                resolve_static_obstacle_overlap(a);
                grid->update(a.id, old_pos + offset, agent_foot_point(a));
                a.update_motion_state(delta, cfg);
                continue;
            }

            Vec2 to_wp = a.path_waypoints[a.path_index] - foot;
            Vec2 nav_dir = safe_normalize(to_wp);

            // An explicit A* path already provides safe cell-center route intent.
            // Feeding soft wall repulsion into that direction can invert it inside a
            // one-tile corridor: the wall force may be stronger than flow_weight and
            // point the agent away from its waypoint forever. Hard footprint collision
            // and sliding below remain authoritative, so walls still cannot be crossed.
            const Vec2 no_soft_wall_repel(0, 0);
            Vec2 target_velocity = desired_velocity_for_flow(a, nav, nav_dir, no_soft_wall_repel, agent_separation, static_obstacle_repel, a.max_speed);
            Vec2 desired_dir = safe_normalize(target_velocity);
            if (desired_dir.is_zero())
                desired_dir = nav_dir;

            apply_bottleneck_traffic(a, nav, target_velocity, delta);
            desired_dir = safe_normalize(target_velocity);
            if (desired_dir.is_zero())
                desired_dir = nav_dir;

            if (a.is_propelled && !a.smash_preserves_control && active_control_suppression <= 0.0 && !target_velocity.is_zero() && a.velocity.dot(target_velocity) <= 0.0)
            {
                a.is_propelled = false;
                a.propelled_timer = 0.0;
                a.smash_force = Vec2(0, 0);
                a.smash_friction = -1.0;
                a.velocity = Vec2(0, 0);
                smash_control_factor = 1.0;
            }

            a.debug_nav_dir = nav_dir;
            a.debug_wall_repel = wall_repel;
            a.debug_separation = agent_separation;
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
            Vec2 move_velocity = propelled_move_velocity(a, target_velocity, smash_control_factor);
            Vec2 step = terrain_scaled_step(a, nav, move_velocity, delta);
            a.position = apply_walk_with_walls(a, step, nav);
            if (nav)
                ultimate_wall_correction(a, nav, delta);
            resolve_static_obstacle_overlap(a);
            grid->update(a.id, old_pos + offset, agent_foot_point(a));
            a.update_motion_state(delta, cfg);
            continue;
        }

        if (!a.active || !a.flow)
        {
            if (a.control_mode == AgentControlMode::Manual)
            {
                Vec2 manual_dir = safe_normalize(a.manual_input_dir);
                Vec2 correction = local_avoidance;
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
                Vec2 move_velocity = propelled_move_velocity(a, target_velocity, smash_control_factor);
                Vec2 step = terrain_scaled_step(a, nav, move_velocity, delta);
                Vec2 new_pos = apply_walk_with_walls(a, step, nav);
                a.position = new_pos;

                if (nav)
                    ultimate_wall_correction(a, nav, delta);

                resolve_static_obstacle_overlap(a);
                grid->update(a.id, old_pos + offset, agent_foot_point(a));
                a.update_motion_state(delta, cfg);
                continue;
            }

            if (!a.is_propelled)
            {
                Vec2 combined = wall_repel + local_avoidance;

                Vec2 local_dir = safe_normalize(combined);
                if (local_dir.is_zero() && a.external_velocity.current_velocity().is_zero())
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
            Vec2 step = terrain_scaled_step(a, nav, a.velocity, delta);
            a.position = apply_walk_with_walls(a, step, nav);

            if (nav)
                ultimate_wall_correction(a, nav, delta);

            resolve_static_obstacle_overlap(a);
            grid->update(a.id, old_pos + offset, agent_foot_point(a));
            a.update_motion_state(delta, cfg);
            continue;
        }

        if (a.control_mode == AgentControlMode::Manual)
        {
            Vec2 manual_dir = safe_normalize(a.manual_input_dir);
            Vec2 correction = local_avoidance;
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
            Vec2 move_velocity = propelled_move_velocity(a, target_velocity, smash_control_factor);
            Vec2 step = terrain_scaled_step(a, nav, move_velocity, delta);
            Vec2 new_pos = apply_walk_with_walls(a, step, nav);
            a.position = new_pos;

            if (nav)
                ultimate_wall_correction(a, nav, delta);

            resolve_static_obstacle_overlap(a);
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
            if (a.is_propelled)
            {
                a.lost_timer = 0.0;
            }
            else if (!a.external_velocity.current_velocity().is_zero())
            {
                // A missing flow direction only removes autonomous guidance. Generic
                // environmental motion (wind, currents, conveyors, etc.) still owns
                // displacement and must not be swallowed by the lost-flow brake.
                a.lost_timer = 0.0;
            }
            else
            {
                a.lost_timer = std::max(0.0, a.lost_timer - delta);
                a.velocity = a.velocity.lerp(Vec2(0, 0), cfg.lerp_general);
                a.update_motion_state(delta, cfg);
                continue;
            }
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
            if (!a.is_propelled)
            {
                const Vec2 external_velocity = a.external_velocity.current_velocity();
                if (!external_velocity.is_zero())
                {
                    // Integrate only the external source. Do not invent an autonomous
                    // direction or start the land-recovery slide while another movement
                    // owner is deliberately carrying the agent through this physically
                    // passable cell. terrain_scaled_step keeps terrain slowdown and the
                    // normal environmental-speed cap in one shared pipeline.
                    a.lost_timer = 0.0;
                    a.lost_slide_accum = 0.0;
                    a.velocity = Vec2(0, 0);
                    Vec2 old_pos = a.position;
                    Vec2 step = terrain_scaled_step(a, nav, Vec2(0, 0), delta);
                    a.position = apply_walk_with_walls(a, step, nav);
                    if (nav)
                        ultimate_wall_correction(a, nav, delta);
                    resolve_static_obstacle_overlap(a);
                    grid->update(a.id, old_pos + offset, agent_foot_point(a));
                    a.debug_nav_dir = Vec2(0, 0);
                    a.debug_wall_repel = wall_repel;
                    a.debug_separation = agent_separation;
                    a.debug_desired_dir = safe_normalize(external_velocity);
                    a.debug_target_velocity = external_velocity;
                    a.update_motion_state(delta, cfg, safe_len(external_velocity) > 1.0);
                    continue;
                }

                // The agent is on a cell with no flow arrow (non-navigable but
                // physics-passable, e.g. a water edge tile it was shoved onto).
                // It can neither be routed nor repelled off. Phase 1: freeze for one
                // lost_retry window so a mid-rebuild flow field / a crowd shove can
                // resolve it. Phase 2 (still lost after the delay): slide toward the
                // nearest navigable cell at min speed until flow is recovered. This
                // is guarded to !is_propelled (knockback keeps priority) and only
                // runs far from the goal, so arrival/wall-repel behavior is untouched.
                if (a.lost_slide_accum <= 0.0)
                {
                    a.lost_slide_accum = std::max(cfg.lost_retry_seconds, 1e-4);
                    a.lost_timer = std::max(0.0, cfg.lost_retry_seconds);
                    a.velocity = Vec2(0, 0);
                    a.update_motion_state(delta, cfg, true);
                    continue;
                }

                Vec2i target_cell = ff->find_nearest_navigable(rel_cell);
                Vec2 escape = safe_normalize(ff->cell_to_world(target_cell) - sample_pos);
                if (escape.is_zero())
                {
                    a.velocity = a.velocity.lerp(Vec2(0, 0), cfg.lerp_general);
                    a.update_motion_state(delta, cfg, true);
                    continue;
                }

                Vec2 target_velocity = escape * a.max_speed * cfg.min_speed_fraction;
                a.velocity = a.velocity.lerp(target_velocity, cfg.lerp_general);
                a.debug_nav_dir = escape;
                a.debug_wall_repel = wall_repel;
                a.debug_separation = agent_separation;
                a.debug_desired_dir = escape;
                a.debug_target_velocity = target_velocity;
                Vec2 old_pos = a.position;
                Vec2 step = terrain_scaled_step(a, nav, a.velocity, delta);
                a.position = apply_walk_with_walls(a, step, nav);
                if (nav)
                    ultimate_wall_correction(a, nav, delta);
                resolve_static_obstacle_overlap(a);
                grid->update(a.id, old_pos + offset, agent_foot_point(a));
                a.update_motion_state(delta, cfg, true);
                continue;
            }
            a.lost_timer = 0.0;
            a.lost_slide_accum = 0.0;
        }
        else
        {
            // Flow recovered (or the agent is within goal margin): end the lost episode.
            a.lost_slide_accum = 0.0;
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
            int current_core = ff->bottleneck_core_at_cell(rel_cell);
            int current_zone = ff->bottleneck_zone_at_cell(rel_cell);
            int next_bottleneck = ff->next_bottleneck_at_cell(rel_cell);
            if (current_core >= 0)
                a.completed_bottleneck = current_core;
            else if (a.completed_bottleneck >= 0 && current_zone != a.completed_bottleneck)
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
            target_velocity = desired_velocity_for_flow(a, ff, nav_dir, wall_repel, agent_separation, static_obstacle_repel, target_speed);
            desired_dir = safe_normalize(target_velocity);
            if (desired_dir.is_zero() && dist_to_target > 0.0)
                desired_dir = safe_normalize(to_goal);
        }

        a.debug_nav_dir = nav_dir;
        a.debug_wall_repel = wall_repel;
        a.debug_separation = agent_separation;
        a.debug_desired_dir = desired_dir;
        a.debug_target_velocity = target_velocity;

        // Wall-stuck detector: wants to move into geometry it can't traverse.
        // Crowd-throttled agents (separation dominates) are intentionally ignored.
        // Compares walls vs PURE crowd separation only — static obstacle repulsion must
        // not be folded in here, or a nearby turret could mask/distort the detector.
        if (!a.is_propelled && !desired_dir.is_zero() && cfg.wall_stuck_detect_seconds > 0.0)
        {
            double wall_mag = safe_len(wall_repel);
            double sep_mag = safe_len(agent_separation);
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
        desired_dir = safe_normalize(target_velocity);
        if (desired_dir.is_zero() && dist_to_target > 0.0)
            desired_dir = safe_normalize(to_goal);

        if (a.is_propelled && !a.smash_preserves_control && active_control_suppression <= 0.0 && !target_velocity.is_zero() && a.velocity.dot(target_velocity) <= 0.0)
        {
            a.is_propelled = false;
            a.propelled_timer = 0.0;
            a.smash_force = Vec2(0, 0);
            a.smash_friction = -1.0;
            a.velocity = Vec2(0, 0);
            smash_control_factor = 1.0;
        }

        a.debug_desired_dir = desired_dir;
        a.debug_target_velocity = target_velocity;

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
        Vec2 move_velocity = propelled_move_velocity(a, target_velocity, smash_control_factor);
        Vec2 step = terrain_scaled_step(a, ff, move_velocity, delta);
        a.position = apply_walk_with_walls(a, step, ff);

        ultimate_wall_correction(a, ff, delta);

        resolve_static_obstacle_overlap(a);
        grid->update(a.id, old_pos + offset, agent_foot_point(a));

        a.update_motion_state(delta, cfg, force_motion_state);

    }

    // --- Phase-1 diagnostic probe: report on a spike ---------------------------
    if (debug_probe_enabled)
    {
        const double elapsed_ms =
            std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - probe_start)
                .count();
        if (elapsed_ms > cfg.debug_nav_frame_lag_ms)
        {
            const long long grid_ids = (long long)grid->total_id_count();
            const long long live_agents = (long long)agents.size();
            // grid_leak > 0 => stale/duplicate ids in the grid (the snowball hypothesis).
            // grid_max_cell huge with a small agent count => one hot cell driving the cost.
            godot::UtilityFunctions::printerr(
                "debug_steering_update_all_lag: elapsed_ms=", elapsed_ms,
                " agents=", (int)live_agents,
                " grid_ids=", (int)grid_ids,
                " grid_leak=", (int)(grid_ids - live_agents),
                " grid_max_cell=", (int)grid->max_cell_occupancy(),
                " grid_cells=", (int)grid->cell_count(),
                " max_neighbor_query=", (int)debug_max_neighbor_query_size,
                " active_aoes=", (int)active_aoes.size());
        }
    }
}
