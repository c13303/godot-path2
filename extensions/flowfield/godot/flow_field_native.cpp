#include "../core/types.h"
#include "flow_field_native.h"
#include "../steering/steering_system.h"
#include "../agent_manager/agent_manager.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>
#include <godot_cpp/classes/tile_set.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include "../core/nav_services.h"
#include <queue>
#include <limits>
#include <cmath>
#include <cstdlib>
#include <chrono>
#include <algorithm>
#include "../core/global_config.h"

using namespace godot;

namespace
{
    constexpr double FLOWFIELD_TARGET_RADIUS_PI = 3.14159265358979323846;
}

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

static double tile_size_from_layer(TileMapLayer *layer)
{
    if (!layer)
        return ffcore::globalconfig().tile_size;

    Ref<TileSet> tile_set = layer->get_tile_set();
    if (tile_set.is_null())
        return ffcore::globalconfig().tile_size;

    Vector2i size = tile_set->get_tile_size();
    return std::max(1.0, static_cast<double>(size.x));
}

static void sync_global_tile_size(double tile_size)
{
    ffcore::GlobalConfig &cfg = ffcore::globalconfig();
    if (std::abs(cfg.tile_size - tile_size) <= 1e-6)
        return;

    cfg.tile_size = tile_size;
    cfg.recompute_from_tile();
}

void FlowFieldNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("rebuild_async", "goal"), &FlowFieldNative::rebuild_async);
    ClassDB::bind_method(D_METHOD("assign_flow_to_group", "group_id", "goal"), &FlowFieldNative::assign_flow_to_group);
    ClassDB::bind_method(D_METHOD("set_debug_draw", "enabled"), &FlowFieldNative::set_debug_draw);
    ClassDB::bind_method(D_METHOD("get_debug_draw"), &FlowFieldNative::get_debug_draw);
    ClassDB::bind_method(D_METHOD("set_floor_layer", "node"), &FlowFieldNative::set_floor_layer);
    ClassDB::bind_method(D_METHOD("set_wall_layer", "node"), &FlowFieldNative::set_wall_layer);
    ClassDB::bind_method(D_METHOD("get_floor_layer"), &FlowFieldNative::get_floor_layer);
    ClassDB::bind_method(D_METHOD("get_wall_layer"), &FlowFieldNative::get_wall_layer);
    ClassDB::bind_method(D_METHOD("compute_distance_field_global"), &FlowFieldNative::compute_distance_field_global);
    ClassDB::bind_method(D_METHOD("compute_flow_dir", "world_pos"), &FlowFieldNative::compute_flow_dir);

    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw"), "set_debug_draw", "get_debug_draw");
}

void FlowFieldNative::set_floor_layer(Object *node) { floor_layer = Object::cast_to<TileMapLayer>(node); }
void FlowFieldNative::set_wall_layer(Object *node) { wall_layer = Object::cast_to<TileMapLayer>(node); }
Object *FlowFieldNative::get_floor_layer() const { return floor_layer; }
Object *FlowFieldNative::get_wall_layer() const { return wall_layer; }

void FlowFieldNative::set_debug_draw(bool enabled)
{
    debug_draw = enabled;
    queue_redraw();
}

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

    double tile_size = tile_size_from_layer(floor_layer);
    sync_global_tile_size(tile_size);

    field.resize(used.size.x, used.size.y);
    field.set_tile_size(tile_size);
    field.set_cell_origin(ffcore::Vec2i(used.position.x, used.position.y));
    field.first_is_arrived = false;
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
            const Vector2i d = dirs8[i];
            Vector2i nb = cur.cell + d;
            if (!walkable_set.count(nb))
                continue;

            // Prevent diagonal corner-cutting through obstacles.
            if ((std::abs(d.x) + std::abs(d.y)) == 2)
            {
                if (!walkable_set.count(cur.cell + Vector2i(d.x, 0)) ||
                    !walkable_set.count(cur.cell + Vector2i(0, d.y)))
                    continue;
            }

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

    double tile_size = tile_size_from_layer(floor_layer);
    sync_global_tile_size(tile_size);

    field.resize(used.size.x, used.size.y);
    field.set_tile_size(tile_size);
    field.set_cell_origin(ffcore::Vec2i(used.position.x, used.position.y));

    std::unordered_set<Vector2i, Vector2iHash> wall_set;
    std::unordered_set<Vector2i, Vector2iHash> walkable_set;

    build_sets(wall_set, walkable_set);

    compute_distance_field(used, wall_set);
    std::unordered_map<Vector2i, double, Vector2iHash> costs;
    compute_bottlenecks(used, walkable_set, costs);
}

void FlowFieldNative::compute_bottlenecks(const Rect2i &used,
                                          const std::unordered_set<Vector2i, Vector2iHash> &walkable_set,
                                          const std::unordered_map<Vector2i, double, Vector2iHash> &costs)
{
    field.clear_bottlenecks();
    if (costs.empty())
        return;

    const int zone_radius = std::clamp(ffcore::globalconfig().bottleneck_zone_radius_tiles, 0, 2);
    const Vector2i east(1, 0);
    const Vector2i west(-1, 0);
    const Vector2i south(0, 1);
    const Vector2i north(0, -1);

    auto is_walkable = [&](const Vector2i &cell) -> bool
    {
        return walkable_set.count(cell) > 0;
    };

    auto cost_at = [&](const Vector2i &cell) -> double
    {
        auto it = costs.find(cell);
        return it == costs.end() ? std::numeric_limits<double>::infinity() : it->second;
    };

    auto is_narrow = [&](const Vector2i &cell, int *out_axis = nullptr) -> bool
    {
        const bool e = is_walkable(cell + east);
        const bool w = is_walkable(cell + west);
        const bool s = is_walkable(cell + south);
        const bool n = is_walkable(cell + north);
        const int neighbor_count = int(e) + int(w) + int(s) + int(n);
        int axis = 0;
        if (neighbor_count == 2 && e && w)
            axis = 1;
        else if (neighbor_count == 2 && n && s)
            axis = 2;

        if (out_axis)
            *out_axis = axis;
        return axis != 0;
    };

    std::unordered_set<Vector2i, Vector2iHash> added_doors;
    const Vector2i cardinal_dirs[4] = {east, west, south, north};

    for (const Vector2i &cell : walkable_set)
    {
        int axis = 0;
        if (!is_narrow(cell, &axis))
            continue;

        const double cell_cost = cost_at(cell);
        if (!std::isfinite(cell_cost))
            continue;

        bool is_route_entry = false;
        for (const Vector2i &d : cardinal_dirs)
        {
            Vector2i neighbor = cell + d;
            if (!is_walkable(neighbor) || is_narrow(neighbor))
                continue;

            double neighbor_cost = cost_at(neighbor);
            if (std::isfinite(neighbor_cost) && neighbor_cost > cell_cost)
            {
                is_route_entry = true;
                break;
            }
        }

        if (!is_route_entry || added_doors.count(cell) != 0)
            continue;
        added_doors.insert(cell);

        Vector2i rel(cell.x - used.position.x, cell.y - used.position.y);
        int bottleneck_index = field.add_bottleneck(ffcore::Vec2i(rel.x, rel.y), axis, cell_cost);
        if (bottleneck_index < 0)
            continue;

        for (int dy = -zone_radius; dy <= zone_radius; ++dy)
        {
            for (int dx = -zone_radius; dx <= zone_radius; ++dx)
            {
                if (std::abs(dx) + std::abs(dy) > zone_radius)
                    continue;

                Vector2i zone_cell = cell + Vector2i(dx, dy);
                if (!is_walkable(zone_cell))
                    continue;

                Vector2i zone_rel(zone_cell.x - used.position.x, zone_cell.y - used.position.y);
                field.add_bottleneck_zone_cell(bottleneck_index, ffcore::Vec2i(zone_rel.x, zone_rel.y));
            }
        }
    }
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

    field.set_distance_field(distance_field);
}

void FlowFieldNative::_ready()
{
    set_z_index(1);
}

int FlowFieldNative::group_size_for_draw() const
{
    auto *mgr = ffcore::get_global_agent_manager();
    if (!mgr || current_group_id == ffcore::INVALID_GROUP)
        return 1;
    int count = mgr->count_group_members(current_group_id);
    return std::max(1, count);
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

    auto is_walkable = [&](const Vector2i &p) -> bool
    { return walkable_set.count(p) != 0; };

    auto diagonal_ok = [&](const Vector2i &c, const Vector2i &d) -> bool
    {
        if ((std::abs(d.x) + std::abs(d.y)) != 2)
            return true;
        // Disallow diagonals that would "cut" between two blocked cells.
        return is_walkable(c + Vector2i(d.x, 0)) && is_walkable(c + Vector2i(0, d.y));
    };

    const Vector2i dirs8[8] = {
        {1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

    for (int y = 0; y < field.height(); ++y)
    {
        for (int x = 0; x < field.width(); ++x)
        {
            Vector2i c = used.position + Vector2i(x, y);
            double cc = cost_at(c);
            if (!is_walkable(c) || !std::isfinite(cc))
            {
                field.set_dir(x, y, {0.0, 0.0});
                continue;
            }

            // Base direction: steepest-descent to the best neighboring cell.
            Vector2i best_step(0, 0);
            double best_cost = cc;
            for (const Vector2i &d : dirs8)
            {
                if (!diagonal_ok(c, d))
                    continue;
                Vector2i n = c + d;
                if (!is_walkable(n))
                    continue;
                double nc = cost_at(n);
                if (!std::isfinite(nc))
                    continue;

                if (nc < best_cost)
                {
                    best_cost = nc;
                    best_step = d;
                }
            }

            if (best_step == Vector2i(0, 0))
            {
                field.set_dir(x, y, {0.0, 0.0});
                continue;
            }

            //// COMPUTING DU MEILLEUR PASSAGE GOULOT COULOIR GRACE A DISTANCE_FIELD
            ffcore::Vec2 dir((double)best_step.x, (double)best_step.y);
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

            const double k = ffcore::globalconfig().flow_field_wall_clearance;

            dir = (dir + grad_df * k).normalized();
            //// END OF PASSAGE GOULOT

            // QUANTIFICATION : divider (8 = 45°, 16 = 22.5°)
            const double q = 16.0;
            double angle = std::atan2(dir.y, dir.x);
            double step = 2.0 * 3.141592653589793 / q;
            angle = std::round(angle / step) * step;
            dir.x = std::cos(angle);
            dir.y = std::sin(angle);

            // Ensure the final direction still picks the best downhill neighbor.
            // Clearance smoothing can only break cost ties, not override path cost.
            Vector2i final_step(0, 0);
            double final_cost = std::numeric_limits<double>::infinity();
            double best_score = -1.0;
            const double cost_eps = 1e-9;
            for (const Vector2i &d : dirs8)
            {
                if (!diagonal_ok(c, d))
                    continue;
                Vector2i n = c + d;
                if (!is_walkable(n))
                    continue;
                double nc = cost_at(n);
                if (!std::isfinite(nc) || nc > cc)
                    continue;

                const double inv_len = ((std::abs(d.x) + std::abs(d.y)) == 2) ? 0.70710678118 : 1.0;
                const double score = (dir.x * (double)d.x + dir.y * (double)d.y) * inv_len;
                if (nc + cost_eps < final_cost)
                {
                    final_cost = nc;
                    best_score = score;
                    final_step = d;
                }
                else if (std::abs(nc - final_cost) <= cost_eps && score > best_score)
                {
                    best_score = score;
                    final_step = d;
                }
            }

            if (final_step == Vector2i(0, 0))
                final_step = best_step;

            ffcore::Vec2 final_dir((double)final_step.x, (double)final_step.y);
            field.set_dir(x, y, final_dir.normalized());
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

bool FlowFieldNative::rebuild_async(Vector2 goal)
{
    Rect2i used;
    Vector2i goal_cell;

    if (!prepare_layers(goal, used, goal_cell))
    {
        field.resize(0, 0);
        return false;
    }

    distance_field.clear();
    distance_field.resize(field.width() * field.height(), 0.0f);

    std::unordered_set<Vector2i, Vector2iHash> wall_set;
    std::unordered_set<Vector2i, Vector2iHash> walkable_set;
    build_sets(wall_set, walkable_set);

    if (!walkable_set.count(goal_cell))
    {
        field.resize(0, 0);
        return false;
    }

    // Precompute clearance to walls so flow directions can blend in distance gradients.
    compute_distance_field(used, wall_set);

    std::unordered_map<Vector2i, double, Vector2iHash> costs;
    compute_costs(walkable_set, goal_cell, costs);
    std::vector<double> route_costs(field.width() * field.height(), std::numeric_limits<double>::infinity());
    for (int y = 0; y < field.height(); ++y)
    {
        for (int x = 0; x < field.width(); ++x)
        {
            Vector2i cell = used.position + Vector2i(x, y);
            auto it = costs.find(cell);
            if (it != costs.end())
                route_costs[y * field.width() + x] = it->second;
        }
    }
    field.set_route_cost_field(route_costs);

    compute_bottlenecks(used, walkable_set, costs);
    compute_directions(used, walkable_set, costs, wall_set);
    finalize_field(used, goal_cell);
    ffcore::FormationFootprint fp;
    if (auto *mgr = ffcore::get_global_agent_manager())
        fp = mgr->compute_group_footprint(current_group_id);

    /* retrait de flow_id : plus d'enregistrement dans FlowFieldManager */
    return true;
}

Vector2 FlowFieldNative::compute_flow_dir(Vector2 world_pos) const
{
    if (!floor_layer || field.width() == 0 || field.height() == 0)
        return Vector2(0, 0);

    Vector2 cell_size = floor_layer->get_tile_set()->get_tile_size();
    double tile_size = cell_size.x;

    Vector2 local = floor_layer->to_local(world_pos);
    Vector2i base = floor_layer->local_to_map(local);
    // Fraction within the cell, robust for negative coordinates.
    Vector2 base_center = floor_layer->map_to_local(base);
    Vector2 delta = local - base_center;
    Vector2 frac = Vector2((float)clamp01(delta.x / tile_size + 0.5),
                           (float)clamp01(delta.y / tile_size + 0.5));

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
    if (!floor_layer)
        return;

    const auto &cfg = ffcore::globalconfig();
    const bool draw_flow = debug_draw || cfg.draw_flow_field;

    if (draw_flow)
    {
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
    }

}

void FlowFieldNative::assign_flow_to_group(int group_id, Vector2 goal)
{
    current_group_id = group_id;
    if (!rebuild_async(goal))
        return;

    ffcore::AgentManager *mgr = ffcore::get_global_agent_manager();
    if (!mgr)
        return;

    auto *fm = ffcore::flowfields();
    ffcore::FlowFieldID fid = fm->register_copy(field);
    ffcore::FlowField *new_flow = fm->get(fid);
    int agent_count = mgr->count_group_members(group_id);
    double target_radius = 0.0;
    if (agent_count > 1)
    {
        double denominator = double(std::max(0, agent_count - 1));
        target_radius = std::ceil(std::sqrt(denominator / FLOWFIELD_TARGET_RADIUS_PI));
    }
    auto goal_tile = new_flow->get_goal_cell();
    double world_radius = (target_radius + 1) * new_flow->tile_size();
  /*   godot::UtilityFunctions::print(
        "Flow target radius (tiles):", target_radius, "mapped world radius:", world_radius,
        "agents:", agent_count, "goal_tile:", goal_tile.x, goal_tile.y, "tile_size:", new_flow->tile_size()); */
    new_flow->set_ff_target_radius(world_radius);
    mgr->set_group_flow(group_id, new_flow);
}
