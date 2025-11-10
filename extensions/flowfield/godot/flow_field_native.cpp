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
    ClassDB::bind_method(D_METHOD("get_goal_world"), &FlowFieldNative::get_goal_world);
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
    Vector2 goal_center_world = floor_layer->to_global(floor_layer->map_to_local(goal_cell));
    goal_world = goal_center_world;

    UtilityFunctions::print("[GOAL TEST] click=", goal.x, ",", goal.y,
                            " | cell=", goal_cell.x, ",", goal_cell.y,
                            " | center=", goal_center_world.x, ",", goal_center_world.y);

    if (!walkable_set.count(goal_cell))
        return;

    const Vector2i dirs8[8] = {
        {1, 0}, {-1, 0}, {0, 1}, {0, -1},
        {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

    std::unordered_map<Vector2i, double, Vector2iHash> costs;
    for (const Vector2i &c : walkable_set)
        costs[c] = std::numeric_limits<double>::infinity();

    std::priority_queue<DijkstraNode, std::vector<DijkstraNode>, std::greater<DijkstraNode>> pq;
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

            double new_cost = cur.cost + move_cost_for_dir(i);
            if (new_cost < costs[nb])
            {
                costs[nb] = new_cost;
                pq.push({new_cost, nb});
            }
        }
    }

    auto cost_at = [&](const Vector2i &p) -> double {
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
                field.set_dir(x, y, {0.0, 0.0});
                continue;
            }

            double gx = cost_at(c + Vector2i(1, 0)) - cc;
            double gy = cost_at(c + Vector2i(0, 1)) - cc;
            ffcore::Vec2 dir(-gx, -gy);
            if (dir.length() > 1e-6)
                dir = dir.normalized();
            field.set_dir(x, y, dir);
        }
    }

    ffcore::Vec2i rel_goal(goal_cell.x - used.position.x, goal_cell.y - used.position.y);
    ffcore::Vec2 dir_goal = field.dir(rel_goal.x, rel_goal.y);
    UtilityFunctions::print("[DIR TEST] goal_cell=", goal_cell.x, ",", goal_cell.y,
                            " | dir=", dir_goal.x, ",", dir_goal.y);

    field.set_goal_cell(rel_goal);
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
            Vector2 local_center = floor_layer->map_to_local(cell);
            Vector2 world_center = floor_layer->to_global(local_center);
            Vector2 draw_center = to_local(world_center);

            Vector2 dir(dir_v.x, dir_v.y);
            dir = dir.normalized();

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
