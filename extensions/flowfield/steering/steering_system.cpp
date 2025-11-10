#include "steering_system.h"
#include <algorithm>
#include <cstdio>
#include <cmath>

using namespace ffcore;

SteeringSystem::SteeringSystem() {}

int SteeringSystem::register_agent(const Vec2 &pos, double max_speed, FlowField *flow)
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
    return a.id;
}

void SteeringSystem::unregister_agent(int id)
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
}

void SteeringSystem::set_default_flowfield(FlowField *f) { default_flow = f; }
void SteeringSystem::set_grid(SpatialGrid *g) { grid = g; }

const AgentData *SteeringSystem::get_agent(int id) const
{
    auto it = id_to_index.find(id);
    if (it == id_to_index.end())
        return nullptr;
    return &agents[it->second];
}

void SteeringSystem::soft_wall_correction(AgentData &a, FlowField *ff, double delta)
{
    Vec2i cell = ff->world_to_cell(a.position);
    if (ff->is_cell_navigable(cell))
        return;

    Vec2i best_cell = cell;
    double best_dist = 1e9;

    for (int dx = -1; dx <= 1; ++dx)
    {
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
    }

    if (best_cell == cell)
        return;

    Vec2 wall_center = ff->cell_to_world(cell);
    Vec2 free_center = ff->cell_to_world(best_cell);
    Vec2 dir = (free_center - wall_center).normalized();

    Vec2 target_pos = free_center - dir * (ff->tile_size() * 0.5 - 0.05);
    double blend = std::clamp(delta * 10.0, 0.0, 1.0);
    a.position = a.position.lerp(target_pos, blend);

    double toward_wall = a.velocity.dot(dir);
    if (toward_wall > 0.0)
        a.velocity -= dir * toward_wall;
}

void SteeringSystem::update_all(double delta)
{
    if (!grid)
        return;

    const double FLOW_WEIGHT = 1.0;
    const double SLOW_RADIUS = 2.5;
    const double ARRIVAL_EPS = 0.25;
    const double CENTER_PULL = 0.25;
    const double TILE_SIZE = 16.0;
    const double WALL_AVOID_RADIUS = TILE_SIZE * 1.5;
    const double WALL_REPEL_STRENGTH = 0.9;
    const double WALL_SLIDE_BLEND = 0.7;
    const double DIRECT_STEER_RADIUS = TILE_SIZE * 2.5; // ✅ Augmenté

    for (auto &a : agents)
    {
        if (!a.active)
            continue;

        FlowField *ff = a.flow ? a.flow : default_flow;
        if (!ff || !ff->is_ready())
            continue;

        Vec2 goal_pos = ff->has_goal() ? ff->goal_center_world() : a.position;
        double dist_to_goal = (a.position - goal_pos).length();

        // ARRÊT COMPLET au goal
        if (dist_to_goal < ARRIVAL_EPS)
        {
            a.velocity = Vec2(0, 0);
            a.position = goal_pos;
            continue;
        }

        Vec2i cur_cell = ff->world_to_cell(a.position);
        Vec2 cell_center = ff->cell_to_world(cur_cell);

        // VÉRIFIER SI ON EST DANS LA TILE GOAL
        Vec2i goal_cell = ff->has_goal() ? ff->get_goal_cell() : cur_cell;
        bool in_goal_tile = (cur_cell.x == goal_cell.x && cur_cell.y == goal_cell.y);

        // Calculer flowfield
        Vec2 flow_dir = ff->sample_dir_world(a.position);

        // MODE DIRECT PUR dans goal
        if (in_goal_tile || flow_dir.is_zero())
        {
            Vec2 direct_dir = (goal_pos - a.position).normalized();
            double slow_factor = std::min(dist_to_goal / TILE_SIZE, 1.0);
            slow_factor = std::max(slow_factor, 0.4);
            a.velocity = direct_dir * a.max_speed * slow_factor;
            
            Vec2 old_pos = a.position;
            a.position = a.position + a.velocity * delta;
            grid->update(a.id, old_pos, a.position);
            continue;
        }

        // MODE FLOWFIELD NORMAL
        Vec2 offset_center = cell_center - a.position;
        double offset_dist = offset_center.length();
        Vec2 center_correction = offset_center.normalized() * 
            std::min(offset_dist / TILE_SIZE, 1.0) * CENTER_PULL;

        // WALL AVOIDANCE
        Vec2 wall_repel(0, 0);
        for (int dx = -1; dx <= 1; ++dx)
        {
            for (int dy = -1; dy <= 1; ++dy)
            {
                if (dx == 0 && dy == 0)
                    continue;

                Vec2i neighbor;
                neighbor.x = cur_cell.x + dx;
                neighbor.y = cur_cell.y + dy;

                Vec2 n_center = ff->cell_to_world(neighbor);
                Vec2 n_dir = ff->sample_dir_world(n_center);

                if (n_dir.is_zero())
                {
                    Vec2 away = (a.position - n_center);
                    double dist = away.length();
                    if (dist < WALL_AVOID_RADIUS && dist > 1e-3)
                    {
                        double force = (1.0 - (dist / WALL_AVOID_RADIUS)) * WALL_REPEL_STRENGTH;
                        wall_repel = wall_repel + away.normalized() * force;
                    }
                }
            }
        }

        // ✅ Blend progressif PLUS AGRESSIF
        double blend_to_direct = 0.0;
        if (dist_to_goal < DIRECT_STEER_RADIUS)
        {
            blend_to_direct = 1.0 - (dist_to_goal / DIRECT_STEER_RADIUS);
            blend_to_direct = std::pow(blend_to_direct, 0.5); // ✅ Plus fort qu'avant (0.7)
        }

        // Réduire forces parasites
        double force_dampening = std::min(dist_to_goal / SLOW_RADIUS, 1.0);
        center_correction = center_correction * force_dampening * (1.0 - blend_to_direct);
        wall_repel = wall_repel * force_dampening * (1.0 - blend_to_direct);

        Vec2 flowfield_dir = (flow_dir * FLOW_WEIGHT + center_correction + wall_repel).normalized();

        // ✅ CORRECTION du flowfield près du goal
        if (dist_to_goal < TILE_SIZE * 2.0)
        {
            Vec2 to_goal_center = (goal_pos - a.position).normalized();
            double pull_strength = 1.0 - (dist_to_goal / (TILE_SIZE * 2.0));
            pull_strength = std::pow(pull_strength, 1.5);
            flowfield_dir = (flowfield_dir * (1.0 - pull_strength) + 
                            to_goal_center * pull_strength).normalized();
        }

        Vec2 direct_dir = (goal_pos - a.position).normalized();

        // Wall sliding
        if (!wall_repel.is_zero() && blend_to_direct < 0.5)
        {
            Vec2 tangent1(-wall_repel.y, wall_repel.x);
            Vec2 tangent2(wall_repel.y, -wall_repel.x);

            double dot1 = tangent1.dot(flow_dir);
            double dot2 = tangent2.dot(flow_dir);
            Vec2 tangent = (dot1 > dot2) ? tangent1 : tangent2;

            flowfield_dir = (flowfield_dir * (1.0 - WALL_SLIDE_BLEND) + 
                            tangent.normalized() * WALL_SLIDE_BLEND).normalized();
        }

        // Blend final
        Vec2 desired_dir = (flowfield_dir * (1.0 - blend_to_direct) + 
                           direct_dir * blend_to_direct).normalized();

        // Ralentissement
        double slow_factor = 1.0;
        if (dist_to_goal < SLOW_RADIUS)
        {
            slow_factor = dist_to_goal / SLOW_RADIUS;
            slow_factor = std::pow(slow_factor, 1.2);
            slow_factor = std::max(slow_factor, 0.3);
        }

        // Velocity smoothing
        Vec2 target_velocity = desired_dir * a.max_speed * slow_factor;
        double smoothing = std::clamp(delta * 10.0, 0.0, 1.0);
        a.velocity = a.velocity.lerp(target_velocity, smoothing);

        Vec2 old_pos = a.position;
        a.position = a.position + a.velocity * delta;

        if (dist_to_goal > ARRIVAL_EPS * 2.0)
        {
            soft_wall_correction(a, ff, delta);
        }

        grid->update(a.id, old_pos, a.position);
    }
}


