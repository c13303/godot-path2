#include "steering_system.h"
#include <algorithm>
#include <cstdio>
#include <cmath>
#include <unordered_map>

using namespace ffcore;

static inline double clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }

static inline Vec2 safe_normalize(const Vec2 &v)
{
    double l = v.length();
    if (l < 1e-6)
        return Vec2(0, 0);
    return v * (1.0 / l);
}

static inline double safe_len(const Vec2 &v)
{
    double l = v.length();
    return (l < 1e-6) ? 0.0 : l;
}

static inline Vec2 hashed_unit_dir(int id)
{
    unsigned h = (unsigned)id * 1664525u + 1013904223u;
    double a = (h & 0xFFFFu) / 65535.0 * 6.28318530718;
    return Vec2(std::cos(a), std::sin(a));
}

static std::unordered_map<int, double> g_goal_cooldown;

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
    g_goal_cooldown[a.id] = 0.0;
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
    g_goal_cooldown.erase(id);
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

static Vec2 project_to_navigable(FlowField *ff, const Vec2 &from, const Vec2 &to)
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

void SteeringSystem::soft_wall_correction(AgentData &a, FlowField *ff, double delta)
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
    const double SEPARATION_RADIUS = 24.0;
    const double SEPARATION_STRENGTH = 2.0;
    const int MAX_NEIGHBORS = 8;
}

Vec2 SteeringSystem::compute_separation_force(const AgentData &agent, double, bool)
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

void SteeringSystem::update_all(double delta)
{
    if (!grid)
        return;

    const double FLOW_WEIGHT = 1.0;
    const double SLOW_RADIUS = 2.5;
    const double CENTER_PULL = 0.25;
    const double TILE_SIZE = 16.0;
    const double WALL_AVOID_RADIUS = TILE_SIZE * 1.5;
    const double WALL_REPEL_STRENGTH = 0.7;
    const double WALL_SLIDE_BLEND = 0.7;
    const double DIRECT_STEER_RADIUS = TILE_SIZE * 2.5;
    const double MIN_SPEED_FRACTION = 0.25;

    const double GOAL_OCCUPY_RADIUS = TILE_SIZE * 0.40;
    const double GOAL_BLOCK_RADIUS = TILE_SIZE * 0.60;
    const double GOAL_COOLDOWN_SEC = 0.75;
    const double GOAL_RING_RADIUS = TILE_SIZE * 0.51;

    for (auto &a : agents)
    {
        if (!a.active)
            continue;

        auto cd_it = g_goal_cooldown.find(a.id);
        if (cd_it != g_goal_cooldown.end() && cd_it->second > 0.0)
            cd_it->second = std::max(0.0, cd_it->second - delta);

        FlowField *ff = a.flow ? a.flow : default_flow;
        if (!ff || !ff->is_ready())
            continue;

        Vec2 goal_pos = ff->has_goal() ? ff->goal_center_world() : a.position;
        double dist_to_goal = (a.position - goal_pos).length();

        Vec2i cur_cell = ff->world_to_cell(a.position);
        if (!ff->is_cell_navigable(cur_cell))
            a.position = ff->cell_to_world(cur_cell);
        cur_cell = ff->world_to_cell(a.position);
        
        Vec2 cell_center = ff->cell_to_world(cur_cell);
        Vec2i goal_cell = ff->has_goal() ? ff->get_goal_cell() : cur_cell;
        bool in_goal_tile = (cur_cell.x == goal_cell.x && cur_cell.y == goal_cell.y);
        Vec2 goal_center = ff->cell_to_world(goal_cell);

        bool goal_has_occupant = false;
        int goal_occupant_id = -1;
        {
            double query_r = GOAL_BLOCK_RADIUS;
            std::vector<int> nids = grid->query_neighbors(goal_center, query_r);
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

                double d = (other.position - goal_center).length();
                if (d <= GOAL_OCCUPY_RADIUS)
                {
                    goal_has_occupant = true;
                    goal_occupant_id = nid;
                    break;
                }
            }
        }

        Vec2 separation_force = compute_separation_force(a, dist_to_goal, in_goal_tile);
        Vec2 flow_dir = safe_normalize(ff->sample_dir_world(a.position));
        Vec2 offset_center = cell_center - a.position;
        double offset_dist = offset_center.length();
        Vec2 center_correction = safe_normalize(offset_center) *
                                 std::min(offset_dist / TILE_SIZE, 1.0) * CENTER_PULL;

        Vec2 wall_repel(0, 0);
        for (int dx = -1; dx <= 1; ++dx)
            for (int dy = -1; dy <= 1; ++dy)
            {
                if (dx == 0 && dy == 0)
                    continue;
                Vec2i neighbor = {cur_cell.x + dx, cur_cell.y + dy};
                Vec2 n_center = ff->cell_to_world(neighbor);
                Vec2 n_dir = ff->sample_dir_world(n_center);
                if (n_dir.is_zero())
                {
                    Vec2 away = (a.position - n_center);
                    double dist = away.length();
                    if (dist < WALL_AVOID_RADIUS && dist > 1e-3)
                    {
                        double force = (1.0 - (dist / WALL_AVOID_RADIUS)) * WALL_REPEL_STRENGTH;
                        wall_repel = wall_repel + away * (force / dist);
                    }
                }
            }

        double blend_to_direct = 0.0;
        if (dist_to_goal < DIRECT_STEER_RADIUS)
        {
            blend_to_direct = 1.0 - (dist_to_goal / DIRECT_STEER_RADIUS);
            blend_to_direct = std::pow(blend_to_direct, 0.5);
        }

        double force_dampening = std::min(dist_to_goal / SLOW_RADIUS, 1.0);
        center_correction = center_correction * force_dampening * (1.0 - blend_to_direct);
        wall_repel = wall_repel * force_dampening * (1.0 - blend_to_direct);

        Vec2 flowfield_dir = safe_normalize(flow_dir * FLOW_WEIGHT + center_correction + wall_repel + separation_force);

        if (dist_to_goal < TILE_SIZE * 2.0)
        {
            Vec2 to_goal_center = safe_normalize(goal_pos - a.position);
            double pull = std::pow(1.0 - (dist_to_goal / (TILE_SIZE * 2.0)), 1.25);
            flowfield_dir = safe_normalize(flowfield_dir * (1.0 - pull) + to_goal_center * pull);
        }

        Vec2 desired_dir;
        bool block_goal_now = false;
        double my_cd = g_goal_cooldown[a.id];

        if ((goal_has_occupant && goal_occupant_id != a.id) || my_cd > 0.0)
        {
            block_goal_now = true;

            Vec2 from_goal = a.position - goal_center;
            if (from_goal.is_zero())
                from_goal = hashed_unit_dir(a.id);

            Vec2 tangent(-from_goal.y, from_goal.x);
            tangent = safe_normalize(tangent);
            Vec2 keep_out = safe_normalize(from_goal) * 0.8 + tangent * 0.6 + separation_force * 0.8;
            desired_dir = safe_normalize(keep_out);
            if (desired_dir.is_zero())
                desired_dir = tangent;
        }
        else
        {
            Vec2 direct_dir = safe_normalize(goal_pos - a.position);
            desired_dir = safe_normalize(flowfield_dir * (1.0 - blend_to_direct) + direct_dir * blend_to_direct);
            if (desired_dir.is_zero())
                desired_dir = (flowfield_dir.is_zero() ? hashed_unit_dir(a.id) : flowfield_dir);
        }

        double slow_factor = 1.0;
        if (dist_to_goal < SLOW_RADIUS)
        {
            slow_factor = dist_to_goal / SLOW_RADIUS;
            slow_factor = std::pow(slow_factor, 1.2);
            slow_factor = std::max(slow_factor, MIN_SPEED_FRACTION);
        }

        Vec2 target_velocity = desired_dir * a.max_speed * slow_factor;
        a.velocity = a.velocity.lerp(target_velocity, 0.25);

        double vmax = a.max_speed;
        double vlen = safe_len(a.velocity);
        if (vlen > vmax)
            a.velocity = a.velocity * (vmax / vlen);

        Vec2 old_pos = a.position;
        Vec2 proposed = a.position + a.velocity * delta;

        if (block_goal_now)
        {
            Vec2 v = proposed - goal_center;
            double r = v.length();
            if (r < GOAL_BLOCK_RADIUS)
            {
                if (r < 1e-4)
                    v = hashed_unit_dir(a.id), r = 1.0;
                v = v * (GOAL_RING_RADIUS / r);
                proposed = goal_center + v;
                g_goal_cooldown[a.id] = std::max(g_goal_cooldown[a.id], GOAL_COOLDOWN_SEC);
            }
        }

        Vec2i prop_cell = ff->world_to_cell(proposed);
        if (!ff->is_cell_navigable(prop_cell))
            proposed = project_to_navigable(ff, a.position, proposed);

        a.position = proposed;
        soft_wall_correction(a, ff, delta);
        grid->update(a.id, old_pos, a.position);
    }
}
