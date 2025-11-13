#include "flow_field_native.h"
#include "../steering/steering_system.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include "../core/nav_services.h"
#include <queue>
#include <limits>
#include <cmath>

using namespace godot;

struct DijkstraNode
{
    double cost;
    Vector2i cell;
    bool operator>(const DijkstraNode &other) const { return cost > other.cost; }
};
static inline double clamp01(double v)
{
    return (v < 0.0) ? 0.0 : (v > 1.0 ? 1.0 : v);
}

void FlowFieldNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_floor_layer", "node"), &FlowFieldNative::set_floor_layer);
    ClassDB::bind_method(D_METHOD("get_floor_layer"), &FlowFieldNative::get_floor_layer);
    ClassDB::bind_method(D_METHOD("set_wall_layer", "node"), &FlowFieldNative::set_wall_layer);
    ClassDB::bind_method(D_METHOD("get_wall_layer"), &FlowFieldNative::get_wall_layer);
    ClassDB::bind_method(D_METHOD("rebuild_async", "goal"), &FlowFieldNative::rebuild_async);
    ClassDB::bind_method(D_METHOD("compute_flow_dir", "world_pos"), &FlowFieldNative::compute_flow_dir);
    ClassDB::bind_method(D_METHOD("get_goal_world"), &FlowFieldNative::get_goal_world);
    ClassDB::bind_method(D_METHOD("compute_distance_field_global"), &FlowFieldNative::compute_distance_field_global);
    ClassDB::bind_method(D_METHOD("get_flow_id"), &FlowFieldNative::get_flow_id);
}

void FlowFieldNative::set_floor_layer(Object *node) { floor_layer = Object::cast_to<TileMapLayer>(node); }
void FlowFieldNative::set_wall_layer(Object *node) { wall_layer = Object::cast_to<TileMapLayer>(node); }
Object *FlowFieldNative::get_floor_layer() const { return floor_layer; }
Object *FlowFieldNative::get_wall_layer() const { return wall_layer; }

bool FlowFieldNative::prepare_layers(Vector2 goal, Rect2i &used, Vector2i &goal_cell)
{
    if (!floor_layer || !wall_layer)
        return false;

    if (ffcore::SteeringSystem *sys = ffcore::get_global_steering_system())
        sys->reactivate_agents_for_field(&field);

    goal_world = goal;
    used = floor_layer->get_used_rect();
    if (used.size.x <= 0 || used.size.y <= 0)
        return false;

    field.resize(used.size.x, used.size.y);
    field.set_tile_size(floor_layer->get_tile_set()->get_tile_size().x);
    field.set_cell_origin(ffcore::Vec2i(used.position.x, used.position.y));
    field.target_triggered = false;
    field.arrived_count = 0;

    Vector2 goal_local = floor_layer->to_local(goal_world);
    goal_cell = floor_layer->local_to_map(goal_local);
    Vector2 goal_center_world = floor_layer->to_global(floor_layer->map_to_local(goal_cell));
    goal_world = goal_center_world;

    return true;
}

void FlowFieldNative::build_sets(std::unordered_set<Vector2i, Vector2iHash> &wall_set,
                                 std::unordered_set<Vector2i, Vector2iHash> &walkable_set)
{
    wall_set.clear();
    walkable_set.clear();

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
}

void FlowFieldNative::compute_costs(const std::unordered_set<Vector2i, Vector2iHash> &walkable_set,
                                    const Vector2i &goal_cell,
                                    std::unordered_map<Vector2i, double, Vector2iHash> &costs)
{
    costs.clear();
    for (const Vector2i &c : walkable_set)
        costs[c] = std::numeric_limits<double>::infinity();

    if (!walkable_set.count(goal_cell))
        return;

    const Vector2i dirs8[8] = {
        {1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

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

            double step = (i < 4) ? 1.0 : 1.41421356237;
            double new_cost = cur.cost + step;
            if (new_cost < costs[nb])
            {
                costs[nb] = new_cost;
                pq.push({new_cost, nb});
            }
        }
    }
}

/// DISTANCE FIELD = la distance de chaque case de chaque mur. On trouve avec ça la case la plus "centrale" d'un couloir pour trouver son centre. = Très utile pour une foule.
void FlowFieldNative::compute_distance_field_global()
{
    if (!floor_layer || !wall_layer)
        return;

    Rect2i used = floor_layer->get_used_rect();
    if (used.size.x <= 0 || used.size.y <= 0)
        return;

    field.resize(used.size.x, used.size.y);
    field.set_tile_size(floor_layer->get_tile_set()->get_tile_size().x);
    field.set_cell_origin(ffcore::Vec2i(used.position.x, used.position.y));

    std::unordered_set<Vector2i, Vector2iHash> wall_set;
    std::unordered_set<Vector2i, Vector2iHash> walkable_set;

    build_sets(wall_set, walkable_set);

    compute_distance_field(used, wall_set);
}

void FlowFieldNative::compute_distance_field(const Rect2i &used,
                                             const std::unordered_set<Vector2i, Vector2iHash> &wall_set)
{
    distance_field.clear();
    distance_field.resize(field.width() * field.height(), 0.0f);

    const int w = field.width();
    const int h = field.height();

    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
        {
            Vector2i c = used.position + Vector2i(x, y);
            distance_field[y * w + x] = wall_set.count(c) ? 0.0f : 1e9f;
        }

    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
        {
            float d = distance_field[y * w + x];
            if (d == 0.0f)
                continue;
            if (x > 0)
                d = Math::min(d, distance_field[y * w + (x - 1)] + 1.0f);
            if (y > 0)
                d = Math::min(d, distance_field[(y - 1) * w + x] + 1.0f);
            if (x > 0 && y > 0)
                d = Math::min(d, distance_field[(y - 1) * w + (x - 1)] + 1.4142f);
            distance_field[y * w + x] = d;
        }

    for (int y = h - 1; y >= 0; --y)
        for (int x = w - 1; x >= 0; --x)
        {
            float d = distance_field[y * w + x];
            if (x + 1 < w)
                d = Math::min(d, distance_field[y * w + (x + 1)] + 1.0f);
            if (y + 1 < h)
                d = Math::min(d, distance_field[(y + 1) * w + x] + 1.0f);
            if (x + 1 < w && y + 1 < h)
                d = Math::min(d, distance_field[(y + 1) * w + (x + 1)] + 1.4142f);
            distance_field[y * w + x] = d;
        }
}

void FlowFieldNative::compute_directions(const Rect2i &used,
                                         const std::unordered_set<Vector2i, Vector2iHash> &walkable_set,
                                         const std::unordered_map<Vector2i, double, Vector2iHash> &costs,
                                         const std::unordered_set<Vector2i, Vector2iHash> &wall_set)
{
    auto cost_at = [&](const Vector2i &p) -> double
    {
        auto it = costs.find(p);
        return (it == costs.end()) ? std::numeric_limits<double>::infinity() : it->second;
    };

    const Vector2i dirs8[8] = {
        {1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

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

            double gx = 0.0, gy = 0.0, weights = 0.0;

            for (const Vector2i &d : dirs8)
            {
                Vector2i n = c + d;
                double nc = cost_at(n);
                if (!std::isfinite(nc))
                    continue;

                double dx = (double)d.x;
                double dy = (double)d.y;
                double w = ((std::abs(d.x) + std::abs(d.y)) == 2) ? 0.7071 : 1.0;

                gx += (nc - cc) * dx * w;
                gy += (nc - cc) * dy * w;
                weights += w;
            }

            if (weights > 0.0)
            {
                gx /= weights;
                gy /= weights;
            }

            //// COMPUTING DU MEILLEUR PASSAGE GOULOT COULOIR GRACE A DISTANCE_FIELD
            ffcore::Vec2 dir(-gx, -gy);
            if (dir.length() <= 1e-6)
            {
                field.set_dir(x, y, {0.0, 0.0});
                continue;
            }
            dir = dir.normalized();

            float dfc = distance_field[y * field.width() + x];

            auto df_at = [&](int px, int py)
            {
                if (px < 0 || py < 0 || px >= field.width() || py >= field.height())
                    return dfc;
                return distance_field[py * field.width() + px];
            };

            float gx_df = df_at(x + 1, y) - df_at(x - 1, y);
            float gy_df = df_at(x, y + 1) - df_at(x, y - 1);

            ffcore::Vec2 grad_df(gx_df, gy_df);
            if (grad_df.length() > 1e-6)
                grad_df = grad_df.normalized();

            float k = 0.5f;

            dir = (dir + grad_df * k).normalized();
            //// END OF PASSAGE GOULOT

            // QUANTIFICATION : divider (8 = 45°, 16 = 22.5°)
            double q = 360 / 16;
            double angle = std::atan2(dir.y, dir.x);
            double step = 2.0 * 3.141592653589793 / q;
            angle = std::round(angle / step) * step;
            dir.x = std::cos(angle);
            dir.y = std::sin(angle);
            field.set_dir(x, y, dir);
        }
    }
}

void FlowFieldNative::adjust_wall_tangents(const Rect2i &used,
                                           const std::unordered_set<Vector2i, Vector2iHash> &wall_set,
                                           int radius)
{
    const Vector2i dirs8[8] = {
        {1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

    for (int y = 0; y < field.height(); ++y)
    {
        for (int x = 0; x < field.width(); ++x)
        {
            Vector2i c = used.position + Vector2i(x, y);

            double min_dist2 = 1e9;
            Vector2 wall_normal(0, 0);

            // Cherche le mur le plus proche
            for (int dy = -radius; dy <= radius; ++dy)
                for (int dx = -radius; dx <= radius; ++dx)
                {
                    Vector2i n = c + Vector2i(dx, dy);
                    if (wall_set.count(n))
                    {
                        double d2 = double(dx * dx + dy * dy);
                        if (d2 < min_dist2)
                        {
                            min_dist2 = d2;
                            wall_normal = Vector2(-dx, -dy);
                        }
                    }
                }

            if (wall_normal.length_squared() < 1e-6)
                continue;

            wall_normal = wall_normal.normalized();

            ffcore::Vec2 dir = field.dir(x, y);
            if (dir.x == 0.0 && dir.y == 0.0)
                continue;

            Vector2 d2(dir.x, dir.y);
            if (d2.dot(wall_normal) < 0.0)
            {
                // Projette tangentiellement dans le bon sens
                Vector2 tangent(-wall_normal.y, wall_normal.x);
                if (tangent.dot(d2) < 0.0)
                    tangent = -tangent;

                dir = ffcore::Vec2(tangent.x, tangent.y);
                field.set_dir(x, y, dir);
            }
        }
    }
}

void FlowFieldNative::finalize_field(const Rect2i &used, const Vector2i &goal_cell)
{
    ffcore::Vec2i rel_goal(goal_cell.x - used.position.x, goal_cell.y - used.position.y);
    if (rel_goal.x >= 0 && rel_goal.y >= 0 &&
        rel_goal.x < field.width() && rel_goal.y < field.height())
        field.set_dir(rel_goal.x, rel_goal.y, ffcore::Vec2(0.0, 0.0));

    field.set_goal_cell(rel_goal);
    queue_redraw();
}

void FlowFieldNative::rebuild_async(Vector2 goal)
{
    Rect2i used;
    Vector2i goal_cell;

    if (!prepare_layers(goal, used, goal_cell))
        return;

    std::unordered_set<Vector2i, Vector2iHash> wall_set;
    std::unordered_set<Vector2i, Vector2iHash> walkable_set;
    build_sets(wall_set, walkable_set);

    if (!walkable_set.count(goal_cell))
        return;

    std::unordered_map<Vector2i, double, Vector2iHash> costs;
    compute_costs(walkable_set, goal_cell, costs);
    compute_directions(used, walkable_set, costs, wall_set);
    adjust_wall_tangents(used, wall_set, 2);
    finalize_field(used, goal_cell);
    flow_id = ffcore::flowfields()->register_existing(&field);
}

Vector2 FlowFieldNative::compute_flow_dir(Vector2 world_pos) const
{
    if (!floor_layer || field.width() == 0 || field.height() == 0)
        return Vector2(0, 0);

    Vector2 cell_size = floor_layer->get_tile_set()->get_tile_size();
    double tile_size = cell_size.x;

    Vector2 local = floor_layer->to_local(world_pos);
    Vector2i base = floor_layer->local_to_map(local);
    Vector2 frac = Vector2(fmod(local.x, tile_size) / tile_size,
                           fmod(local.y, tile_size) / tile_size);

    Rect2i used = floor_layer->get_used_rect();

    auto dir_cell = [&](int cx, int cy)
    {
        Vector2i rel(cx - used.position.x, cy - used.position.y);
        if (rel.x < 0 || rel.y < 0 || rel.x >= field.width() || rel.y >= field.height())
            return Vector2(0, 0);
        ffcore::Vec2 d = field.dir(rel.x, rel.y);
        return Vector2(d.x, d.y);
    };

    Vector2 d00 = dir_cell(base.x, base.y);
    Vector2 d10 = dir_cell(base.x + 1, base.y);
    Vector2 d01 = dir_cell(base.x, base.y + 1);
    Vector2 d11 = dir_cell(base.x + 1, base.y + 1);

    Vector2 a = d00.lerp(d10, frac.x);
    Vector2 b = d01.lerp(d11, frac.x);
    Vector2 result = a.lerp(b, frac.y);

    float len2 = result.x * result.x + result.y * result.y;
    return (len2 > 1e-6f) ? (result / Math::sqrt(len2)) : Vector2(0, 0);
}

void FlowFieldNative::_draw()
{
    if (!debug_draw || !floor_layer)
        return;

    set_z_index(999);
    Vector2 cell_size = floor_layer->get_tile_set()->get_tile_size();
    Rect2i used = floor_layer->get_used_rect();
    int skip = Math::max(1, debug_stride);

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
            draw_line(draw_center, draw_center + dir * len, debug_color_dir, 1.0);
        }
    }

    if (field.has_goal())
    {
        ffcore::Vec2i goal = field.get_goal_cell();
        Vector2 goal_center = to_local(
            floor_layer->to_global(
                floor_layer->map_to_local(Vector2i(goal.x, goal.y))));

        const int segments = 128;
        const float thickness = 1.0f;

        draw_arc(goal_center, ffcore::TARGET_SLOW_RADIUS, 0, Math_TAU, segments, Color(0, 1, 0, 0.9), thickness);
        draw_arc(goal_center, ffcore::TARGET_APPROACH_RADIUS, 0, Math_TAU, segments, Color(1, 0.5, 0, 0.9), thickness);
        draw_arc(goal_center, ffcore::TARGET_OCCUPY_RADIUS, 0, Math_TAU, segments, Color(1, 0, 0, 0.9), thickness);
    }
}
