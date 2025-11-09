#include "steering_system.h"

using namespace ffcore;

SteeringSystem::SteeringSystem() {}

int SteeringSystem::register_agent(const Vec2 &pos, double max_speed)
{
    AgentData a;
    a.id = next_id++;
    a.position = pos;
    a.max_speed = max_speed;
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

void SteeringSystem::set_flowfield(FlowField *f) { flowfield = f; }
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
    if (!flowfield || !flowfield->is_ready() || !grid)
        return;

    const double NEIGHBOR_RADIUS = 2.0;
    const double SEPARATION_WEIGHT = 0.5;
    const double FLOW_WEIGHT = 1.0;
    const double SLOW_RADIUS = 2.5; // rayon de ralentissement (en cellules)
    const double ARRIVAL_EPS = 0.15;

    for (auto &a : agents)
    {
        if (!a.active)
            continue;

        Vec2 flow_dir = flowfield->sample_dir_world(a.position);
        if (flow_dir.is_zero())
            continue;

        // Force de séparation
        Vec2 sep(0, 0);
        auto neighbors = grid->query_neighbors(a.position, NEIGHBOR_RADIUS);
        int count = 0;
        for (int nid : neighbors)
        {
            if (nid == a.id)
                continue;
            const AgentData *other = get_agent(nid);
            if (!other)
                continue;
            Vec2 diff = a.position - other->position;
            double dist = diff.length();
            if (dist > 1e-6 && dist < NEIGHBOR_RADIUS)
            {
                double falloff = 1.0 - (dist / NEIGHBOR_RADIUS);
                sep += diff.normalized() * falloff;
                count++;
            }
        }
        if (count > 0)
            sep = sep * (1.0 / count);

        // Direction combinée
        Vec2 desired_dir = (flow_dir * FLOW_WEIGHT + sep * SEPARATION_WEIGHT).normalized();
        if (desired_dir.is_zero())
            continue;

        // Ralentissement à l'approche du but
        Vec2i goal_cell = flowfield->world_to_cell(flowfield->cell_to_world(flowfield->world_to_cell(Vec2(2, 2))));
        Vec2 goal_pos = flowfield->cell_to_world(goal_cell);
        double dist_to_goal = a.position.distance_to(goal_pos);
        double slow_factor = 1.0;

        if (dist_to_goal < SLOW_RADIUS)
        {
            slow_factor = dist_to_goal / SLOW_RADIUS;
            slow_factor = std::max(slow_factor, 0.2);
        }
        if (dist_to_goal < ARRIVAL_EPS)
            a.active = false;

        a.velocity = desired_dir * a.max_speed * slow_factor;
        Vec2 old_pos = a.position;
        a.position += a.velocity * delta;
        grid->update(a.id, old_pos, a.position);
    }
}
