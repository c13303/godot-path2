#include "flow_field_native.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <queue>
#include <vector>
#include <unordered_set>
#include <unordered_map>
#include <limits>
#include <cmath>
#include <algorithm>

using namespace godot;

struct Vector2iHash
{
    size_t operator()(const godot::Vector2i &v) const noexcept
    {
        return (static_cast<size_t>(v.x) * 73856093u) ^ (static_cast<size_t>(v.y) * 19349663u);
    }
};

struct DijkstraNode
{
    double cost;
    Vector2i cell;
    bool operator>(const DijkstraNode &other) const { return cost > other.cost; }
};

void FlowFieldNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_floor_layer", "node"), &FlowFieldNative::set_floor_layer);
    ClassDB::bind_method(D_METHOD("get_floor_layer"), &FlowFieldNative::get_floor_layer);
    ClassDB::bind_method(D_METHOD("set_wall_layer", "node"), &FlowFieldNative::set_wall_layer);
    ClassDB::bind_method(D_METHOD("get_wall_layer"), &FlowFieldNative::get_wall_layer);
    ClassDB::bind_method(D_METHOD("rebuild_async", "goal"), &FlowFieldNative::rebuild_async);
    ClassDB::bind_method(D_METHOD("sample_dir_world", "world_pos"), &FlowFieldNative::sample_dir_world);
}

void FlowFieldNative::set_floor_layer(Object *node)
{
    floor_layer = Object::cast_to<TileMapLayer>(node);
}

void FlowFieldNative::set_wall_layer(Object *node)
{
    wall_layer = Object::cast_to<TileMapLayer>(node);
}

Object *FlowFieldNative::get_floor_layer() const { return floor_layer; }
Object *FlowFieldNative::get_wall_layer() const { return wall_layer; }

void FlowFieldNative::rebuild_async(Vector2 goal)
{
    if (!floor_layer || !wall_layer)
        return;

    goal_world = goal;
    Rect2i used = floor_layer->get_used_rect();
    if (used.size.x <= 0 || used.size.y <= 0)
        return;

    field.resize(used.size.x, used.size.y);
    field.set_tile_size(floor_layer->get_tile_set()->get_tile_size().x);
    field.set_cell_origin(ffcore::Vec2i(used.position.x, used.position.y));

    std::unordered_set<Vector2i, Vector2iHash> wall_set;
    std::unordered_set<Vector2i, Vector2iHash> walkable_set;

    Array walls = wall_layer->get_used_cells();
    for (int i = 0; i < walls.size(); i++)
        wall_set.insert((Vector2i)walls[i]);

    Array floors = floor_layer->get_used_cells();
    for (int i = 0; i < floors.size(); i++)
    {
        Vector2i c = floors[i];
        if (!wall_set.count(c))
            walkable_set.insert(c);
    }

    Vector2 goal_local = floor_layer->to_local(goal_world);
    Vector2i goal_cell = floor_layer->local_to_map(goal_local);
    if (!walkable_set.count(goal_cell))
        return;

    const Vector2i dirs8[8] = {
        {1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

    std::unordered_map<Vector2i, int, Vector2iHash> cheb_dist;
    const int INF_INT = 1e9;
    for (const Vector2i &c : walkable_set)
        cheb_dist[c] = INF_INT;

    std::queue<Vector2i> q;
    for (const Vector2i &w : wall_set)
    {
        for (int i = 0; i < 8; i++)
        {
            Vector2i n = w + dirs8[i];
            auto it = cheb_dist.find(n);
            if (it != cheb_dist.end() && it->second > 1)
            {
                it->second = 1;
                q.push(n);
            }
        }
    }

    while (!q.empty())
    {
        Vector2i cur = q.front();
        q.pop();
        int cd = cheb_dist[cur];
        for (int i = 0; i < 8; i++)
        {
            Vector2i n = cur + dirs8[i];
            auto it = cheb_dist.find(n);
            if (it == cheb_dist.end())
                continue;
            int nd = cd + 1;
            if (nd < it->second)
            {
                it->second = nd;
                q.push(n);
            }
        }
    }

    auto penalty = [&](int d) -> double
    {
        if (d <= 0)
            return std::numeric_limits<double>::infinity();
        double k = 2.5;
        double p = k / (double(d) + 0.5);
        return std::max(p, 0.2);
    };

    std::unordered_map<Vector2i, double, Vector2iHash> costs;
    std::priority_queue<DijkstraNode, std::vector<DijkstraNode>, std::greater<DijkstraNode>> pq;

    for (const Vector2i &c : walkable_set)
        costs[c] = std::numeric_limits<double>::infinity();

    costs[goal_cell] = 0.0;
    pq.push({0.0, goal_cell});

    while (!pq.empty())
    {
        DijkstraNode cur = pq.top();
        pq.pop();
        if (cur.cost > costs[cur.cell])
            continue;

        for (int i = 0; i < 8; i++)
        {
            Vector2i nb = cur.cell + dirs8[i];
            if (!walkable_set.count(nb))
                continue;

            if (i >= 4)
            {
                Vector2i ax(dirs8[i].x, 0), ay(0, dirs8[i].y);
                if (!walkable_set.count(cur.cell + ax) || !walkable_set.count(cur.cell + ay))
                    continue;
            }

            int d_nb = INF_INT;
            auto itd = cheb_dist.find(nb);
            if (itd != cheb_dist.end())
                d_nb = itd->second;

            double pen = penalty(d_nb);
            if (!std::isfinite(pen))
                continue;

            double new_cost = cur.cost + move_cost_for_dir(i) + pen;
            if (new_cost < costs[nb])
            {
                costs[nb] = new_cost;
                pq.push({new_cost, nb});
            }
        }
    }

    auto cost_at = [&](const Vector2i &p) -> double
    {
        auto it = costs.find(p);
        return (it == costs.end()) ? std::numeric_limits<double>::infinity() : it->second;
    };

    for (int y = 0; y < field.height(); ++y)
    {
        for (int x = 0; x < field.width(); ++x)
        {
            Vector2i c = used.position + Vector2i(x, y);
            double cc = cost_at(c);
            if (!walkable_set.count(c) || !std::isfinite(cc))
            {
                field.set_dir(x, y, {0.0f, 0.0f});
                continue;
            }

            double gx = 0.0, gy = 0.0;
            int valid = 0;

            auto add = [&](const Vector2i &off, double wx, double wy)
            {
                double cv = cost_at(c + off);
                if (!std::isfinite(cv))
                    return;
                gx += (cv - cc) * wx;
                gy += (cv - cc) * wy;
                valid++;
            };

            add(Vector2i(1, 0), 1.0, 0.0);
            add(Vector2i(-1, 0), -1.0, 0.0);
            add(Vector2i(0, 1), 0.0, 1.0);
            add(Vector2i(0, -1), 0.0, -1.0);

            if (valid > 0)
            {
                Vector2 g(-static_cast<float>(gx), -static_cast<float>(gy));
                if (g.length() > 1e-6f)
                    g = g.normalized();
                field.set_dir(x, y, {g.x, g.y});
            }
            else
            {
                field.set_dir(x, y, {0.0f, 0.0f});
            }
        }
    }

    queue_redraw();
}

double FlowFieldNative::move_cost_for_dir(int dir_index)
{
    return (dir_index < 4) ? 1.0 : 1.4142135623730951;
}

godot::Vector2 FlowFieldNative::sample_dir_world(Vector2 world_pos) const
{
    if (!floor_layer || field.width() == 0 || field.height() == 0)
        return Vector2(0, 0);

    Vector2 local = floor_layer->to_local(world_pos);
    Vector2i cell = floor_layer->local_to_map(local);
    Rect2i used = floor_layer->get_used_rect();
    Vector2i rel = cell - used.position;

    if (rel.x < 0 || rel.y < 0 || rel.x >= field.width() || rel.y >= field.height())
        return Vector2(0, 0);

    ffcore::Vec2 d = field.dir(rel.x, rel.y);
    return Vector2(d.x, d.y);
}

void FlowFieldNative::_draw()
{
    if (!debug_draw || !floor_layer)
        return;

    set_z_index(999);

    Vector2 cell_size = floor_layer->get_tile_set()->get_tile_size();
    int skip = Math::max(1, debug_stride);
    int count = 0;

    Rect2i used = floor_layer->get_used_rect();

    for (int y = 0; y < field.height(); y += skip)
    {
        for (int x = 0; x < field.width(); x += skip)
        {
            ffcore::Vec2 dir_v = field.dir(x, y);
            if (dir_v.x == 0.0f && dir_v.y == 0.0f)
                continue;

            Vector2i cell = used.position + Vector2i(x, y);

            // position du centre exact de la cellule
            Vector2 local_center = floor_layer->map_to_local(cell);
            Vector2 world_center = floor_layer->to_global(local_center);
            Vector2 draw_center = to_local(world_center);

            Vector2 dir(dir_v.x, dir_v.y);
            dir = dir.normalized();

            // longueur proportionnelle à la taille de cellule
            float len = cell_size.x * debug_scale * 0.5f;

            Vector2 p1 = draw_center + dir * len;

            draw_line(draw_center, p1, debug_color_dir, 1.0);
            if (debug_stride >= 4)
                draw_circle(draw_center, 1.0, debug_color_cell);

            count++;
        }
    }

    UtilityFunctions::print("FlowFieldNative: debug draw vectors =", count);
}
