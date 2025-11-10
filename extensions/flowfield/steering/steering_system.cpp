#include "steering_system.h"
#include <algorithm>
#include <cstdio>

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

void SteeringSystem::update_all(double delta)
{
    if (!grid)
        return;

    const double FLOW_WEIGHT = 1.0;
    const double SLOW_RADIUS = 2.5;
    const double ARRIVAL_EPS = 0.15;
    const double DAMP_RADIUS = ARRIVAL_EPS * 2.0;

    for (auto &a : agents)
    {
        if (!a.active)
            continue;

        FlowField *ff = a.flow ? a.flow : default_flow;
        if (!ff || !ff->is_ready())
            continue;

        Vec2 flow_dir = ff->sample_dir_world(a.position);

        // Cas sans direction: on stoppe net pour éviter de "coller" au mur
        if (flow_dir.is_zero())
        {
            Vec2 old_pos = a.position;
            a.velocity = Vec2(0, 0);
            grid->update(a.id, old_pos, a.position);
            continue;
        }

        Vec2 goal_pos = ff->has_goal() ? ff->goal_center_world() : a.position;
        Vec2i cur_cell = ff->world_to_cell(a.position);
        Vec2i goal_cell = ff->has_goal() ? ff->get_goal_cell() : cur_cell;

        if (cur_cell == goal_cell)
        {
            Vec2 to_center = goal_pos - a.position;
            double d = to_center.length();

            if (d < ARRIVAL_EPS)
            {
                Vec2 old_pos = a.position;
                a.velocity = Vec2(0, 0);
                a.active = false;
                grid->update(a.id, old_pos, a.position);
                continue;
            }

            Vec2 center_dir = to_center.normalized();
            double slow_factor = std::max(d / SLOW_RADIUS, 0.2);
            if (d < DAMP_RADIUS)
                slow_factor *= (d / DAMP_RADIUS);

            a.velocity = center_dir * a.max_speed * slow_factor;
        }
        else
        {
            double dist_to_goal = (a.position - goal_pos).length();
            double slow_factor = 1.0;
            if (dist_to_goal < SLOW_RADIUS)
                slow_factor = std::max(dist_to_goal / SLOW_RADIUS, 0.2);

            Vec2 desired_dir = (flow_dir * FLOW_WEIGHT).normalized();
            if (desired_dir.is_zero())
            {
                Vec2 old_pos = a.position;
                a.velocity = Vec2(0, 0);
                grid->update(a.id, old_pos, a.position);
                continue;
            }

            a.velocity = desired_dir * a.max_speed * slow_factor;
        }

        Vec2 old_pos = a.position;
        a.position += a.velocity * delta;
        grid->update(a.id, old_pos, a.position);
    }
}
