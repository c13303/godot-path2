#include "../core/types.h"
#include "../core/nav_config.h"
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
#include <thread>

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

static double layer_double_property(Object *object, const char *name, double fallback)
{
    if (!object)
        return fallback;
    Variant value = object->get(StringName(name));
    if (value.get_type() == Variant::NIL)
        return fallback;
    return static_cast<double>(value);
}

static double navigation_blocking_coverage_threshold(Object *object)
{
    double threshold = layer_double_property(object, "navigation_blocking_coverage_threshold", -1.0);
    double drowning_threshold = layer_double_property(object, "drowning_coverage_threshold", 0.0);
    if (threshold < 0.0)
        threshold = drowning_threshold;
    return clamp01(std::max(threshold, drowning_threshold));
}

void FlowFieldNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("rebuild_async", "goal"), &FlowFieldNative::rebuild_async);
    ClassDB::bind_method(D_METHOD("mark_group_flow_queued", "group_id"), &FlowFieldNative::mark_group_flow_queued);
    ClassDB::bind_method(D_METHOD("request_flow_to_group", "group_id", "goal", "block_fences"), &FlowFieldNative::request_flow_to_group, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("are_async_flows_idle"), &FlowFieldNative::are_async_flows_idle);
    ClassDB::bind_method(D_METHOD("is_group_flow_request_ready", "group_id"), &FlowFieldNative::is_group_flow_request_ready);
    ClassDB::bind_method(D_METHOD("assign_flow_to_group", "group_id", "goal", "block_fences"), &FlowFieldNative::assign_flow_to_group, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("group_route_cost_at_world", "group_id", "world_pos"), &FlowFieldNative::group_route_cost_at_world);
    ClassDB::bind_method(D_METHOD("set_debug_draw", "enabled"), &FlowFieldNative::set_debug_draw);
    ClassDB::bind_method(D_METHOD("get_debug_draw"), &FlowFieldNative::get_debug_draw);
    ClassDB::bind_method(D_METHOD("set_debug_draw_group", "group_id"), &FlowFieldNative::set_debug_draw_group);
    ClassDB::bind_method(D_METHOD("set_floor_layer", "node"), &FlowFieldNative::set_floor_layer);
    ClassDB::bind_method(D_METHOD("set_wall_layer", "node"), &FlowFieldNative::set_wall_layer);
    ClassDB::bind_method(D_METHOD("set_navigation_blocking_layer", "node"), &FlowFieldNative::set_navigation_blocking_layer);
    ClassDB::bind_method(D_METHOD("set_water_layer", "node"), &FlowFieldNative::set_water_layer);
    ClassDB::bind_method(D_METHOD("set_blocking_layer", "node"), &FlowFieldNative::set_blocking_layer);
    ClassDB::bind_method(D_METHOD("set_extra_blocking_cells", "cells"), &FlowFieldNative::set_extra_blocking_cells);
    ClassDB::bind_method(D_METHOD("clear_extra_blocking_cells"), &FlowFieldNative::clear_extra_blocking_cells);
    ClassDB::bind_method(D_METHOD("set_fence_blocking_cells", "cells"), &FlowFieldNative::set_fence_blocking_cells);
    ClassDB::bind_method(D_METHOD("clear_fence_blocking_cells"), &FlowFieldNative::clear_fence_blocking_cells);
    ClassDB::bind_method(D_METHOD("set_cell_speed_multiplier", "map_cell", "multiplier"), &FlowFieldNative::set_cell_speed_multiplier);
    ClassDB::bind_method(D_METHOD("clear_cell_speed_multipliers"), &FlowFieldNative::clear_cell_speed_multipliers);
    ClassDB::bind_method(D_METHOD("get_floor_layer"), &FlowFieldNative::get_floor_layer);
    ClassDB::bind_method(D_METHOD("get_wall_layer"), &FlowFieldNative::get_wall_layer);
    ClassDB::bind_method(D_METHOD("get_navigation_blocking_layer"), &FlowFieldNative::get_navigation_blocking_layer);
    ClassDB::bind_method(D_METHOD("get_water_layer"), &FlowFieldNative::get_water_layer);
    ClassDB::bind_method(D_METHOD("get_blocking_layer"), &FlowFieldNative::get_blocking_layer);
    ClassDB::bind_method(D_METHOD("compute_distance_field_global"), &FlowFieldNative::compute_distance_field_global);
    ClassDB::bind_method(D_METHOD("set_cell_blocked", "map_cell", "blocked"), &FlowFieldNative::set_cell_blocked);
    ClassDB::bind_method(D_METHOD("compute_flow_dir", "world_pos"), &FlowFieldNative::compute_flow_dir);

}

void FlowFieldNative::set_floor_layer(Object *node) { floor_layer = Object::cast_to<TileMapLayer>(node); }
void FlowFieldNative::set_wall_layer(Object *node) { wall_layer = Object::cast_to<TileMapLayer>(node); }
void FlowFieldNative::set_navigation_blocking_layer(Object *node) { navigation_blocking_layer = Object::cast_to<TileMapLayer>(node); }
void FlowFieldNative::set_water_layer(Object *node) { set_navigation_blocking_layer(node); }
void FlowFieldNative::set_blocking_layer(Object *node) { blocking_layer = Object::cast_to<TileMapLayer>(node); }
void FlowFieldNative::set_extra_blocking_cells(const PackedVector2Array &cells)
{
    extra_blocking_cells.clear();
    extra_blocking_cells.reserve(cells.size());
    for (int i = 0; i < cells.size(); i++)
    {
        Vector2 cell = cells[i];
        extra_blocking_cells.insert(Vector2i((int)cell.x, (int)cell.y));
    }
}
void FlowFieldNative::clear_extra_blocking_cells() { extra_blocking_cells.clear(); }
void FlowFieldNative::set_fence_blocking_cells(const PackedVector2Array &cells)
{
    fence_blocking_cells.clear();
    fence_blocking_cells.reserve(cells.size());
    for (int i = 0; i < cells.size(); i++)
    {
        Vector2 cell = cells[i];
        fence_blocking_cells.insert(Vector2i((int)cell.x, (int)cell.y));
    }
}
void FlowFieldNative::clear_fence_blocking_cells() { fence_blocking_cells.clear(); }
void FlowFieldNative::set_cell_speed_multiplier(Vector2i map_cell, double multiplier)
{
    if (!std::isfinite(multiplier) || multiplier >= 0.999)
        cell_speed_multipliers.erase(map_cell);
    else
        cell_speed_multipliers[map_cell] = std::clamp(multiplier, 0.01, 1.0);

    // Authoritative live speed: the shared steering map (keyed by absolute cell) is what
    // every agent reads, so this edit is felt immediately on all active group flow fields
    // and cannot be overwritten by a stale in-flight async field. The per-field bake below
    // is kept only for legacy field-local queries; steering no longer reads it.
    if (ffcore::SteeringSystem *sys = ffcore::get_global_steering_system())
        sys->set_terrain_speed_multiplier(ffcore::Vec2i(map_cell.x, map_cell.y), multiplier);

    ffcore::Vec2i rel(map_cell.x - field.get_cell_origin().x, map_cell.y - field.get_cell_origin().y);
    if (field.width() > 0 && field.height() > 0)
        field.set_cell_speed_multiplier(rel, multiplier);
}
void FlowFieldNative::clear_cell_speed_multipliers()
{
    cell_speed_multipliers.clear();
    if (ffcore::SteeringSystem *sys = ffcore::get_global_steering_system())
        sys->clear_terrain_speed_multipliers();
    if (field.width() <= 0 || field.height() <= 0)
        return;
    for (int y = 0; y < field.height(); ++y)
        for (int x = 0; x < field.width(); ++x)
            field.set_cell_speed_multiplier(ffcore::Vec2i(x, y), 1.0);
}
Object *FlowFieldNative::get_floor_layer() const { return floor_layer; }
Object *FlowFieldNative::get_wall_layer() const { return wall_layer; }
Object *FlowFieldNative::get_navigation_blocking_layer() const { return navigation_blocking_layer; }
Object *FlowFieldNative::get_water_layer() const { return navigation_blocking_layer; }
Object *FlowFieldNative::get_blocking_layer() const { return blocking_layer; }

FlowFieldNative::~FlowFieldNative()
{
    stop_worker();
}

void FlowFieldNative::set_debug_draw(bool enabled)
{
    debug_draw = enabled;
    queue_redraw();
}

void FlowFieldNative::set_debug_draw_group(int group_id)
{
    if (group_id < 0)
        group_id = 0;
    debug_draw_group = (ffcore::GroupID)group_id;
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
    apply_cell_speed_multipliers(field, used);
    seed_terrain_speed_to_steering();

    Vector2 goal_local = floor_layer->to_local(goal_world);
    goal_cell = floor_layer->local_to_map(goal_local);
    Vector2 goal_center_world = floor_layer->to_global(floor_layer->map_to_local(goal_cell));
    goal_world = goal_center_world;

    return true;
}

void FlowFieldNative::apply_cell_speed_multipliers(ffcore::FlowField &target_field, const Rect2i &used) const
{
    for (const auto &entry : cell_speed_multipliers)
    {
        const Vector2i &cell = entry.first;
        ffcore::Vec2i rel(cell.x - used.position.x, cell.y - used.position.y);
        target_field.set_cell_speed_multiplier(rel, entry.second);
    }
}

void FlowFieldNative::seed_terrain_speed_to_steering() const
{
    ffcore::SteeringSystem *sys = ffcore::get_global_steering_system();
    if (!sys)
        return;
    // Rebuild the shared map from this node's absolute-cell record. Covers the case where
    // the initial bulk speed sync ran before the steering system existed; live edits keep
    // both in sync afterwards. Main-thread only, so no agent reads mid-reconcile.
    sys->clear_terrain_speed_multipliers();
    for (const auto &entry : cell_speed_multipliers)
        sys->set_terrain_speed_multiplier(ffcore::Vec2i(entry.first.x, entry.first.y), entry.second);
}

void FlowFieldNative::apply_cell_speed_modifiers(ffcore::FlowField &target_field,
                                                 const Rect2i &used,
                                                 const std::vector<CellSpeedModifier> &modifiers) const
{
    for (const CellSpeedModifier &modifier : modifiers)
    {
        ffcore::Vec2i rel(modifier.cell.x - used.position.x, modifier.cell.y - used.position.y);
        target_field.set_cell_speed_multiplier(rel, modifier.multiplier);
    }
}

void FlowFieldNative::build_sets(std::unordered_set<Vector2i, Vector2iHash> &physical_wall_set,
                                 std::unordered_set<Vector2i, Vector2iHash> &walkable_set)
{
    physical_wall_set.clear();
    walkable_set.clear();
    std::unordered_set<Vector2i, Vector2iHash> navigation_blocked_set;
    Array floors = floor_layer->get_used_cells();

    Array walls = wall_layer->get_used_cells();
    for (int i = 0; i < walls.size(); i++)
    {
        Vector2i cell = (Vector2i)walls[i];
        physical_wall_set.insert(cell);
        navigation_blocked_set.insert(cell);
    }

    if (blocking_layer)
    {
        Array blockers = blocking_layer->get_used_cells();
        for (int i = 0; i < blockers.size(); i++)
        {
            Vector2i cell = (Vector2i)blockers[i];
            physical_wall_set.insert(cell);
            navigation_blocked_set.insert(cell);
        }
    }

    for (const Vector2i &cell : extra_blocking_cells)
    {
        physical_wall_set.insert(cell);
        navigation_blocked_set.insert(cell);
    }

    add_navigation_coverage_blockers(floors, navigation_blocked_set);

    for (int i = 0; i < floors.size(); i++)
    {
        Vector2i c = floors[i];
        if (!navigation_blocked_set.count(c))
            walkable_set.insert(c);
    }
}

void FlowFieldNative::add_navigation_coverage_blockers(const Array &floor_cells,
                                                       std::unordered_set<Vector2i, Vector2iHash> &navigation_blocked_set) const
{
    if (!navigation_blocking_layer)
        return;

    const double threshold = navigation_blocking_coverage_threshold(navigation_blocking_layer);
    if (threshold <= 0.0)
    {
        Array blockers = navigation_blocking_layer->get_used_cells();
        for (int i = 0; i < blockers.size(); i++)
        {
            Vector2i cell = (Vector2i)blockers[i];
            navigation_blocked_set.insert(cell);
        }
        return;
    }

    const double radius = std::max(1.0, ffcore::globalconfig().tile_size * ffcore::globalconfig().agent_world_diameter_ratio * 0.5);
    for (int i = 0; i < floor_cells.size(); i++)
    {
        Vector2i cell = (Vector2i)floor_cells[i];
        if (!cell_reaches_navigation_blocking_coverage(cell, radius, threshold))
            continue;
        navigation_blocked_set.insert(cell);
    }
}

bool FlowFieldNative::cell_reaches_navigation_blocking_coverage(const Vector2i &cell,
                                                                double radius,
                                                                double threshold) const
{
    if (!floor_layer || !navigation_blocking_layer || radius <= 0.0)
        return false;

    const Vector2 world_center = floor_layer->to_global(floor_layer->map_to_local(cell));
    const Rect2 world_rect(world_center - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0));
    const Vector2 p0 = navigation_blocking_layer->to_local(world_rect.position);
    const Vector2 p1 = navigation_blocking_layer->to_local(world_rect.position + Vector2(world_rect.size.x, 0.0));
    const Vector2 p2 = navigation_blocking_layer->to_local(world_rect.position + Vector2(0.0, world_rect.size.y));
    const Vector2 p3 = navigation_blocking_layer->to_local(world_rect.position + world_rect.size);

    const double min_x = std::min({(double)p0.x, (double)p1.x, (double)p2.x, (double)p3.x});
    const double min_y = std::min({(double)p0.y, (double)p1.y, (double)p2.y, (double)p3.y});
    const double max_x = std::max({(double)p0.x, (double)p1.x, (double)p2.x, (double)p3.x});
    const double max_y = std::max({(double)p0.y, (double)p1.y, (double)p2.y, (double)p3.y});
    const Rect2 local_rect(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y));
    const double footprint_area = (double)local_rect.size.x * (double)local_rect.size.y;
    if (footprint_area <= 0.0)
        return false;

    const double tile_size = tile_size_from_layer(navigation_blocking_layer);
    const Vector2i first_cell = navigation_blocking_layer->local_to_map(local_rect.position);
    const Vector2i last_cell = navigation_blocking_layer->local_to_map(local_rect.position + local_rect.size);
    const int min_cell_x = std::min(first_cell.x, last_cell.x) - 1;
    const int max_cell_x = std::max(first_cell.x, last_cell.x) + 1;
    const int min_cell_y = std::min(first_cell.y, last_cell.y) - 1;
    const int max_cell_y = std::max(first_cell.y, last_cell.y) + 1;
    double covered_area = 0.0;

    for (int y = min_cell_y; y <= max_cell_y; ++y)
    {
        for (int x = min_cell_x; x <= max_cell_x; ++x)
        {
            const Vector2i blocker_cell(x, y);
            if (navigation_blocking_layer->get_cell_source_id(blocker_cell) == -1)
                continue;

            const Vector2 blocker_center = navigation_blocking_layer->map_to_local(blocker_cell);
            const Rect2 blocker_rect(blocker_center - Vector2(tile_size * 0.5, tile_size * 0.5), Vector2(tile_size, tile_size));
            const Rect2 overlap = local_rect.intersection(blocker_rect);
            const double overlap_area = (double)overlap.size.x * (double)overlap.size.y;
            if (overlap_area <= 0.0)
                continue;

            covered_area += overlap_area;
            if (covered_area / footprint_area >= threshold)
                return true;
        }
    }

    return false;
}

bool FlowFieldNative::snapshot_cell_is_coverage_blocked(const AsyncFlowSnapshot &snapshot,
                                                        const std::unordered_set<Vector2i, Vector2iHash> &nav_cells,
                                                        const Vector2i &cell)
{
    // Worker-thread replica of cell_reaches_navigation_blocking_coverage. TileMapLayer
    // must not be touched off the main thread, so map_to_local/local_to_map are inlined
    // with their square-tile formulas (this project only uses square atlases) and the
    // layer transforms come from the snapshot copies.
    const double radius = snapshot.coverage_radius;
    const double threshold = snapshot.coverage_threshold;
    if (radius <= 0.0 || threshold <= 0.0 || nav_cells.empty())
        return false;

    const double floor_tile = snapshot.tile_size;
    const double nav_tile = snapshot.nav_tile_size;

    const Vector2 local_center(((double)cell.x + 0.5) * floor_tile, ((double)cell.y + 0.5) * floor_tile);
    const Vector2 world_center = snapshot.floor_to_world.xform(local_center);
    const Rect2 world_rect(world_center - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0));
    const Vector2 p0 = snapshot.world_to_nav.xform(world_rect.position);
    const Vector2 p1 = snapshot.world_to_nav.xform(world_rect.position + Vector2(world_rect.size.x, 0.0));
    const Vector2 p2 = snapshot.world_to_nav.xform(world_rect.position + Vector2(0.0, world_rect.size.y));
    const Vector2 p3 = snapshot.world_to_nav.xform(world_rect.position + world_rect.size);

    const double min_x = std::min({(double)p0.x, (double)p1.x, (double)p2.x, (double)p3.x});
    const double min_y = std::min({(double)p0.y, (double)p1.y, (double)p2.y, (double)p3.y});
    const double max_x = std::max({(double)p0.x, (double)p1.x, (double)p2.x, (double)p3.x});
    const double max_y = std::max({(double)p0.y, (double)p1.y, (double)p2.y, (double)p3.y});
    const Rect2 local_rect(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y));
    const double footprint_area = (double)local_rect.size.x * (double)local_rect.size.y;
    if (footprint_area <= 0.0)
        return false;

    auto local_to_map = [nav_tile](const Vector2 &p) -> Vector2i
    {
        return Vector2i((int)std::floor((double)p.x / nav_tile), (int)std::floor((double)p.y / nav_tile));
    };
    const Vector2i first_cell = local_to_map(local_rect.position);
    const Vector2i last_cell = local_to_map(local_rect.position + local_rect.size);
    const int min_cell_x = std::min(first_cell.x, last_cell.x) - 1;
    const int max_cell_x = std::max(first_cell.x, last_cell.x) + 1;
    const int min_cell_y = std::min(first_cell.y, last_cell.y) - 1;
    const int max_cell_y = std::max(first_cell.y, last_cell.y) + 1;
    double covered_area = 0.0;

    for (int y = min_cell_y; y <= max_cell_y; ++y)
    {
        for (int x = min_cell_x; x <= max_cell_x; ++x)
        {
            if (!nav_cells.count(Vector2i(x, y)))
                continue;

            const Vector2 blocker_center(((double)x + 0.5) * nav_tile, ((double)y + 0.5) * nav_tile);
            const Rect2 blocker_rect(blocker_center - Vector2(nav_tile * 0.5, nav_tile * 0.5), Vector2(nav_tile, nav_tile));
            const Rect2 overlap = local_rect.intersection(blocker_rect);
            const double overlap_area = (double)overlap.size.x * (double)overlap.size.y;
            if (overlap_area <= 0.0)
                continue;

            covered_area += overlap_area;
            if (covered_area / footprint_area >= threshold)
                return true;
        }
    }

    return false;
}

void FlowFieldNative::apply_physics_passability(ffcore::FlowField &target_field,
                                                const Rect2i &used,
                                                const std::unordered_set<Vector2i, Vector2iHash> &physical_wall_set) const
{
    target_field.enable_explicit_physics_passability();
    for (int y = 0; y < target_field.height(); ++y)
    {
        for (int x = 0; x < target_field.width(); ++x)
        {
            Vector2i cell = used.position + Vector2i(x, y);
            target_field.set_cell_physics_passable(ffcore::Vec2i(x, y), physical_wall_set.count(cell) == 0);
        }
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
    apply_cell_speed_multipliers(field, used);
    seed_terrain_speed_to_steering();

    std::unordered_set<Vector2i, Vector2iHash> wall_set;
    std::unordered_set<Vector2i, Vector2iHash> walkable_set;

    build_sets(wall_set, walkable_set);

    // This field exists to provide wall distance/collision data before any goal
    // flow is built. Its directions are intentionally all zero, so preserve the
    // actual floor topology in an explicit mask instead of treating every cell as
    // blocked via FlowField's direction-derived fallback.
    field.enable_explicit_navigability();
    for (const Vector2i &cell : walkable_set)
    {
        const Vector2i relative = cell - used.position;
        field.set_cell_navigable(ffcore::Vec2i(relative.x, relative.y), true);
    }

    apply_physics_passability(field, used, wall_set);
    compute_distance_field(used, wall_set);
    std::unordered_map<Vector2i, double, Vector2iHash> costs;
    compute_bottlenecks(used, walkable_set, costs);
}

void FlowFieldNative::set_cell_blocked(Vector2i map_cell, bool blocked)
{
    // Single-cell, in-place passability edit for live wall/building build and removal.
    // Only the default collision field's physics mask is touched; the distance field,
    // bottlenecks, and group flow fields are deliberately left untouched (they stay
    // valid for routing and are recomputed wholesale when night begins). The mask is
    // only meaningful once compute_distance_field_global() has enabled it.
    if (!field.is_ready())
        return;
    const ffcore::Vec2i origin = field.get_cell_origin();
    const ffcore::Vec2i rel(map_cell.x - origin.x, map_cell.y - origin.y);
    field.set_cell_physics_passable(rel, !blocked);
}

void FlowFieldNative::compute_bottlenecks(const Rect2i &used,
                                          const std::unordered_set<Vector2i, Vector2iHash> &walkable_set,
                                          const std::unordered_map<Vector2i, double, Vector2iHash> &costs)
{
    field.clear_bottlenecks();
    if (ffcore::globalconfig().effective_debug_disable_bottlenecks())
        return;
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
    set_process(true);
    start_worker();
}

void FlowFieldNative::_process(double)
{
    process_async_results();
}

void FlowFieldNative::_exit_tree()
{
    stop_worker();
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

    // Precompute physical-wall clearance so flow directions can blend in distance gradients.
    // Navigation-only blockers are omitted here: they affect routes, not collision/bounce.
    apply_physics_passability(field, used, wall_set);
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

    if (!ffcore::globalconfig().effective_debug_disable_bottlenecks())
        compute_bottlenecks(used, walkable_set, costs);
    else
        field.clear_bottlenecks();
    compute_directions(used, walkable_set, costs, wall_set);
    finalize_field(used, goal_cell);
    ffcore::FormationFootprint fp;
    if (auto *mgr = ffcore::get_global_agent_manager())
        fp = mgr->compute_group_footprint(current_group_id);

    /* retrait de flow_id : plus d'enregistrement dans FlowFieldManager */
    return true;
}

bool FlowFieldNative::build_async_snapshot(Vector2 goal, AsyncFlowSnapshot &snapshot, bool block_fences)
{
    snapshot.block_fences = block_fences;
    if (!floor_layer || !wall_layer)
        return false;

    Rect2i used = floor_layer->get_used_rect();
    if (used.size.x <= 0 || used.size.y <= 0)
        return false;

    double tile_size = tile_size_from_layer(floor_layer);
    sync_global_tile_size(tile_size);

    Vector2 goal_local = floor_layer->to_local(goal);
    Vector2i goal_cell = floor_layer->local_to_map(goal_local);

    std::unordered_set<Vector2i, Vector2iHash> wall_set;
    std::unordered_set<Vector2i, Vector2iHash> navigation_blocked_set;
    Array walls = wall_layer->get_used_cells();
    Array blockers;
    if (blocking_layer)
        blockers = blocking_layer->get_used_cells();
    Array floors = floor_layer->get_used_cells();
    snapshot.walls.reserve(walls.size() + blockers.size() + extra_blocking_cells.size() +
                           (block_fences ? fence_blocking_cells.size() : 0));
    snapshot.speed_modifiers.reserve(cell_speed_multipliers.size());
    for (int i = 0; i < walls.size(); i++)
    {
        Vector2i cell = walls[i];
        wall_set.insert(cell);
        navigation_blocked_set.insert(cell);
        snapshot.walls.push_back(cell);
    }
    for (int i = 0; i < blockers.size(); i++)
    {
        Vector2i cell = blockers[i];
        navigation_blocked_set.insert(cell);
        if (wall_set.insert(cell).second)
            snapshot.walls.push_back(cell);
    }
    for (const Vector2i &cell : extra_blocking_cells)
    {
        navigation_blocked_set.insert(cell);
        if (wall_set.insert(cell).second)
            snapshot.walls.push_back(cell);
    }
    // Fences block only client/merchant flows (block_fences). Monster flows omit them so
    // monsters route straight through, merely slowed by the fence cells' speed multiplier.
    if (block_fences)
    {
        for (const Vector2i &cell : fence_blocking_cells)
        {
            navigation_blocked_set.insert(cell);
            if (wall_set.insert(cell).second)
                snapshot.walls.push_back(cell);
        }
    }
    // The navigation-coverage scan (per floor cell, with tilemap queries) is far too
    // heavy for the main thread and caused visible hitches on lazy flow rebuilds.
    // Only its raw inputs are captured here; the worker filters the walkables itself
    // in snapshot_cell_is_coverage_blocked. When the threshold is zero the blockers
    // are plain used cells, which stays a cheap main-thread merge.
    if (navigation_blocking_layer)
    {
        const double threshold = navigation_blocking_coverage_threshold(navigation_blocking_layer);
        Array nav_cells = navigation_blocking_layer->get_used_cells();
        if (threshold <= 0.0)
        {
            for (int i = 0; i < nav_cells.size(); i++)
                navigation_blocked_set.insert((Vector2i)nav_cells[i]);
        }
        else
        {
            const auto &nav_cfg = ffcore::globalconfig();
            snapshot.coverage_threshold = threshold;
            snapshot.coverage_radius = std::max(1.0, nav_cfg.tile_size * nav_cfg.agent_world_diameter_ratio * 0.5);
            snapshot.nav_tile_size = tile_size_from_layer(navigation_blocking_layer);
            snapshot.floor_to_world = floor_layer->get_global_transform();
            snapshot.world_to_nav = navigation_blocking_layer->get_global_transform().affine_inverse();
            snapshot.nav_coverage_cells.reserve(nav_cells.size());
            for (int i = 0; i < nav_cells.size(); i++)
                snapshot.nav_coverage_cells.push_back((Vector2i)nav_cells[i]);
        }
    }

    snapshot.walkables.reserve(floors.size());
    bool goal_is_walkable = false;
    for (int i = 0; i < floors.size(); i++)
    {
        Vector2i cell = floors[i];
        if (navigation_blocked_set.count(cell))
            continue;
        snapshot.walkables.push_back(cell);
        if (cell == goal_cell)
            goal_is_walkable = true;
    }

    if (!goal_is_walkable)
        return false;

    const auto &cfg = ffcore::globalconfig();
    for (const auto &entry : cell_speed_multipliers)
        snapshot.speed_modifiers.push_back({entry.first, entry.second});
    snapshot.used = used;
    snapshot.goal_cell = goal_cell;
    snapshot.tile_size = tile_size;
    snapshot.debug_disable_bottlenecks = cfg.effective_debug_disable_bottlenecks();
    snapshot.bottleneck_zone_radius_tiles = cfg.bottleneck_zone_radius_tiles;
    snapshot.flow_field_wall_clearance = cfg.flow_field_wall_clearance;
    return true;
}

void FlowFieldNative::start_worker()
{
    std::lock_guard<std::mutex> lock(async_mutex);
    if (worker_thread.joinable())
        return;
    worker_stop = false;
    worker_thread = std::thread(&FlowFieldNative::worker_loop, this);
}

void FlowFieldNative::stop_worker()
{
    {
        std::lock_guard<std::mutex> lock(async_mutex);
        worker_stop = true;
        pending_requests.clear();
    }
    async_cv.notify_all();
    if (worker_thread.joinable())
        worker_thread.join();
}

void FlowFieldNative::worker_loop()
{
    while (true)
    {
        AsyncFlowRequest request;
        {
            std::unique_lock<std::mutex> lock(async_mutex);
            async_cv.wait(lock, [&]()
                          { return worker_stop || !pending_requests.empty(); });
            if (worker_stop)
                return;
            request = pending_requests.front();
            pending_requests.pop_front();
            ++active_worker_requests;
        }

        AsyncFlowResult result = compute_async_request(request);

        {
            std::lock_guard<std::mutex> lock(async_mutex);
            completed_results.push_back(result);
            --active_worker_requests;
        }
    }
}

FlowFieldNative::AsyncFlowResult FlowFieldNative::compute_async_request(const AsyncFlowRequest &request) const
{
    AsyncFlowResult result;
    result.group_id = request.group_id;
    result.serial = request.serial;

    const AsyncFlowSnapshot &snapshot = request.snapshot;
    const Rect2i &used = snapshot.used;
    const int width = used.size.x;
    const int height = used.size.y;
    if (width <= 0 || height <= 0)
        return result;

    ffcore::FlowField computed;
    computed.resize(width, height);
    computed.set_tile_size(snapshot.tile_size);
    computed.set_cell_origin(ffcore::Vec2i(used.position.x, used.position.y));
    computed.first_is_arrived = false;
    computed.arrived_count = 0;
    apply_cell_speed_modifiers(computed, used, snapshot.speed_modifiers);

    std::unordered_set<Vector2i, Vector2iHash> wall_set;
    wall_set.reserve(snapshot.walls.size());
    for (const Vector2i &cell : snapshot.walls)
        wall_set.insert(cell);

    apply_physics_passability(computed, used, wall_set);

    // snapshot.walkables are pre-coverage candidates; the navigation-coverage filter
    // runs here on the worker thread (see build_async_snapshot for why).
    std::unordered_set<Vector2i, Vector2iHash> walkable_set;
    walkable_set.reserve(snapshot.walkables.size());
    if (snapshot.coverage_threshold > 0.0 && !snapshot.nav_coverage_cells.empty())
    {
        std::unordered_set<Vector2i, Vector2iHash> nav_cells;
        nav_cells.reserve(snapshot.nav_coverage_cells.size());
        for (const Vector2i &cell : snapshot.nav_coverage_cells)
            nav_cells.insert(cell);
        for (const Vector2i &cell : snapshot.walkables)
        {
            if (!snapshot_cell_is_coverage_blocked(snapshot, nav_cells, cell))
                walkable_set.insert(cell);
        }
    }
    else
    {
        for (const Vector2i &cell : snapshot.walkables)
            walkable_set.insert(cell);
    }

    if (!walkable_set.count(snapshot.goal_cell))
        return result;

    std::vector<float> local_distance_field(width * height, 0.0f);
    for (int y = 0; y < height; ++y)
    {
        for (int x = 0; x < width; ++x)
        {
            Vector2i cell = used.position + Vector2i(x, y);
            local_distance_field[y * width + x] = wall_set.count(cell) ? 0.0f : 1e9f;
        }
    }

    for (int y = 0; y < height; ++y)
    {
        for (int x = 0; x < width; ++x)
        {
            float d = local_distance_field[y * width + x];
            if (d == 0.0f)
                continue;
            if (x > 0)
                d = std::min(d, local_distance_field[y * width + (x - 1)] + 1.0f);
            if (y > 0)
                d = std::min(d, local_distance_field[(y - 1) * width + x] + 1.0f);
            if (x > 0 && y > 0)
                d = std::min(d, local_distance_field[(y - 1) * width + (x - 1)] + 1.4142f);
            local_distance_field[y * width + x] = d;
        }
    }

    for (int y = height - 1; y >= 0; --y)
    {
        for (int x = width - 1; x >= 0; --x)
        {
            float d = local_distance_field[y * width + x];
            if (x + 1 < width)
                d = std::min(d, local_distance_field[y * width + (x + 1)] + 1.0f);
            if (y + 1 < height)
                d = std::min(d, local_distance_field[(y + 1) * width + x] + 1.0f);
            if (x + 1 < width && y + 1 < height)
                d = std::min(d, local_distance_field[(y + 1) * width + (x + 1)] + 1.4142f);
            local_distance_field[y * width + x] = d;
        }
    }
    computed.set_distance_field(local_distance_field);

    std::unordered_map<Vector2i, double, Vector2iHash> costs;
    costs.reserve(walkable_set.size());
    for (const Vector2i &cell : walkable_set)
        costs[cell] = std::numeric_limits<double>::infinity();

    const Vector2i dirs8[8] = {
        {1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

    std::priority_queue<DijkstraNode, std::vector<DijkstraNode>, std::greater<DijkstraNode>> pq;
    costs[snapshot.goal_cell] = 0.0;
    pq.push({0.0, snapshot.goal_cell});

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

    std::vector<double> route_costs(width * height, std::numeric_limits<double>::infinity());
    for (int y = 0; y < height; ++y)
    {
        for (int x = 0; x < width; ++x)
        {
            Vector2i cell = used.position + Vector2i(x, y);
            auto it = costs.find(cell);
            if (it != costs.end())
                route_costs[y * width + x] = it->second;
        }
    }
    computed.set_route_cost_field(route_costs);

    if (!snapshot.debug_disable_bottlenecks && !costs.empty())
    {
        const int zone_radius = std::clamp(snapshot.bottleneck_zone_radius_tiles, 0, 2);
        const Vector2i east(1, 0);
        const Vector2i west(-1, 0);
        const Vector2i south(0, 1);
        const Vector2i north(0, -1);
        const Vector2i cardinal_dirs[4] = {east, west, south, north};
        std::unordered_set<Vector2i, Vector2iHash> added_doors;

        auto is_walkable = [&](const Vector2i &cell) -> bool
        { return walkable_set.count(cell) > 0; };

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
            int bottleneck_index = computed.add_bottleneck(ffcore::Vec2i(rel.x, rel.y), axis, cell_cost);
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
                    computed.add_bottleneck_zone_cell(bottleneck_index, ffcore::Vec2i(zone_rel.x, zone_rel.y));
                }
            }
        }
    }
    else
    {
        computed.clear_bottlenecks();
    }

    auto cost_at = [&](const Vector2i &cell) -> double
    {
        auto it = costs.find(cell);
        return it == costs.end() ? std::numeric_limits<double>::infinity() : it->second;
    };

    auto is_walkable = [&](const Vector2i &cell) -> bool
    { return walkable_set.count(cell) != 0; };

    auto diagonal_ok = [&](const Vector2i &cell, const Vector2i &d) -> bool
    {
        if ((std::abs(d.x) + std::abs(d.y)) != 2)
            return true;
        return is_walkable(cell + Vector2i(d.x, 0)) && is_walkable(cell + Vector2i(0, d.y));
    };

    for (int y = 0; y < height; ++y)
    {
        for (int x = 0; x < width; ++x)
        {
            Vector2i cell = used.position + Vector2i(x, y);
            double cc = cost_at(cell);
            if (!is_walkable(cell) || !std::isfinite(cc))
            {
                computed.set_dir(x, y, {0.0, 0.0});
                continue;
            }

            Vector2i best_step(0, 0);
            double best_cost = cc;
            for (const Vector2i &d : dirs8)
            {
                if (!diagonal_ok(cell, d))
                    continue;
                Vector2i n = cell + d;
                if (!is_walkable(n))
                    continue;
                double nc = cost_at(n);
                if (std::isfinite(nc) && nc < best_cost)
                {
                    best_cost = nc;
                    best_step = d;
                }
            }

            if (best_step == Vector2i(0, 0))
            {
                computed.set_dir(x, y, {0.0, 0.0});
                continue;
            }

            ffcore::Vec2 dir((double)best_step.x, (double)best_step.y);
            dir = dir.normalized();

            float dfc = local_distance_field[y * width + x];
            auto df_at = [&](int px, int py)
            {
                if (px < 0 || py < 0 || px >= width || py >= height)
                    return dfc;
                return local_distance_field[py * width + px];
            };

            float gx_df = df_at(x + 1, y) - df_at(x - 1, y);
            float gy_df = df_at(x, y + 1) - df_at(x, y - 1);
            ffcore::Vec2 grad_df(gx_df, gy_df);
            if (grad_df.length() > 1e-6)
                grad_df = grad_df.normalized();

            dir = (dir + grad_df * snapshot.flow_field_wall_clearance).normalized();

            const double q = 16.0;
            double angle = std::atan2(dir.y, dir.x);
            double step = 2.0 * 3.141592653589793 / q;
            angle = std::round(angle / step) * step;
            dir.x = std::cos(angle);
            dir.y = std::sin(angle);

            Vector2i final_step(0, 0);
            double final_cost = std::numeric_limits<double>::infinity();
            double best_score = -1.0;
            const double cost_eps = 1e-9;
            for (const Vector2i &d : dirs8)
            {
                if (!diagonal_ok(cell, d))
                    continue;
                Vector2i n = cell + d;
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
            computed.set_dir(x, y, final_dir.normalized());
        }
    }

    ffcore::Vec2i rel_goal(snapshot.goal_cell.x - used.position.x, snapshot.goal_cell.y - used.position.y);
    if (rel_goal.x >= 0 && rel_goal.y >= 0 && rel_goal.x < width && rel_goal.y < height)
        computed.set_dir(rel_goal.x, rel_goal.y, ffcore::Vec2(0.0, 0.0));
    computed.set_goal_cell(rel_goal);

    result.field.copy_from(computed);
    result.ok = true;
    return result;
}

void FlowFieldNative::mark_group_flow_queued(int group_id)
{
    if (group_id == ffcore::INVALID_GROUP || group_id >= ffcore::MAX_GROUPS)
        return;
    if (auto *mgr = ffcore::get_global_agent_manager())
        mgr->set_group_flow_wait(group_id, ffcore::GROUP_FLOW_WAIT_QUEUED);
}

void FlowFieldNative::request_flow_to_group(int group_id, Vector2 goal, bool block_fences)
{
    if (group_id == ffcore::INVALID_GROUP || group_id >= ffcore::MAX_GROUPS)
    {
        UtilityFunctions::printerr("FlowFieldNative.request_flow_to_group: invalid group_id ", group_id);
        return;
    }

    AsyncFlowRequest request;
    request.group_id = group_id;

    {
        std::lock_guard<std::mutex> lock(async_mutex);
        request.serial = next_request_serial++;
        latest_request_serial_by_group[group_id] = request.serial;
    }

    // Stamp the request before snapshot construction. If the snapshot is invalid,
    // readiness remains false instead of accidentally accepting an older field.
    if (!build_async_snapshot(goal, request.snapshot, block_fences))
    {
        // Snapshot failed: the field will never build, so don't leave agents frozen.
        if (auto *mgr = ffcore::get_global_agent_manager())
            mgr->set_group_flow_wait(group_id, ffcore::GROUP_FLOW_WAIT_NONE);
        return;
    }

    // The request is now handed to the async worker: agents show "ff being computed".
    if (auto *mgr = ffcore::get_global_agent_manager())
        mgr->set_group_flow_wait(group_id, ffcore::GROUP_FLOW_WAIT_COMPUTING);

    {
        std::lock_guard<std::mutex> lock(async_mutex);
        for (auto it = pending_requests.begin(); it != pending_requests.end();)
        {
            if (it->group_id == group_id)
                it = pending_requests.erase(it);
            else
                ++it;
        }

        pending_requests.push_back(request);
    }
    async_cv.notify_one();
}

bool FlowFieldNative::are_async_flows_idle() const
{
    std::lock_guard<std::mutex> lock(async_mutex);
    return pending_requests.empty() && completed_results.empty() && active_worker_requests == 0;
}

bool FlowFieldNative::is_group_flow_request_ready(int group_id) const
{
    std::lock_guard<std::mutex> lock(async_mutex);
    const auto requested = latest_request_serial_by_group.find(group_id);
    const auto applied = latest_applied_serial_by_group.find(group_id);
    return requested != latest_request_serial_by_group.end() &&
           applied != latest_applied_serial_by_group.end() &&
           requested->second == applied->second;
}

void FlowFieldNative::process_async_results()
{
    std::deque<AsyncFlowResult> results;
    {
        std::lock_guard<std::mutex> lock(async_mutex);
        results.swap(completed_results);
    }

    for (const AsyncFlowResult &result : results)
        apply_async_result(result);
}

void FlowFieldNative::apply_async_result(const AsyncFlowResult &result)
{
    {
        std::lock_guard<std::mutex> lock(async_mutex);
        auto it = latest_request_serial_by_group.find(result.group_id);
        if (it == latest_request_serial_by_group.end() || it->second != result.serial)
            return;
    }

    if (!result.ok)
    {
        // The worker rejected the request (e.g. the goal cell turned out to be
        // coverage-blocked). The field will never build, so don't leave the group's
        // agents frozen in "ff being computed"; mirrors the snapshot-failure path.
        if (auto *mgr = ffcore::get_global_agent_manager())
            mgr->set_group_flow_wait(result.group_id, ffcore::GROUP_FLOW_WAIT_NONE);
        return;
    }

    ffcore::AgentManager *mgr = ffcore::get_global_agent_manager();
    if (!mgr)
        return;
    if (!mgr->get_groups()[result.group_id].active)
        return;

    auto *fm = ffcore::flowfields();
    ffcore::FlowFieldID fid = fm->register_copy(result.field);
    ffcore::FlowField *new_flow = fm->get(fid);
    if (fid == ffcore::INVALID_FLOWFIELD || !new_flow)
    {
        UtilityFunctions::printerr("FlowFieldNative.apply_async_result: flowfield pool exhausted for group ", result.group_id);
        return;
    }

    int agent_count = mgr->count_group_members(result.group_id);
    double target_radius = 0.0;
    if (agent_count > 1)
    {
        double denominator = double(std::max(0, agent_count - 1));
        target_radius = std::ceil(std::sqrt(denominator / FLOWFIELD_TARGET_RADIUS_PI));
    }
    double world_radius = (target_radius + 1) * new_flow->tile_size();
    new_flow->set_ff_target_radius(world_radius);
    mgr->set_group_flow(result.group_id, new_flow);
    // This is the latest requested field for the group (older serials were rejected
    // above), so the group is current again: agents unfreeze and resume flow in/out.
    mgr->set_group_flow_wait(result.group_id, ffcore::GROUP_FLOW_WAIT_NONE);

    {
        std::lock_guard<std::mutex> lock(async_mutex);
        latest_applied_serial_by_group[result.group_id] = result.serial;
    }

    field.copy_from(result.field);
    current_group_id = result.group_id;
    queue_redraw();
}

Vector2 FlowFieldNative::compute_flow_dir(Vector2 world_pos) const
{
    if (!std::isfinite(world_pos.x) || !std::isfinite(world_pos.y))
    {
        UtilityFunctions::printerr(
            "FlowFieldNative.compute_flow_dir: non-finite world_pos (", world_pos.x, ",", world_pos.y, ")");
        return Vector2(0, 0);
    }

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
    const bool draw_flow = !cfg.debug_disable_all_debug && (debug_draw || cfg.effective_draw_flow_field());

    // Per-agent draw: only draw the clicked agent's group field. Nothing is drawn until a
    // group is selected (set_debug_draw_group) by clicking an agent.
    const ffcore::FlowField *draw_field = nullptr;
    if (draw_flow && debug_draw_group != ffcore::INVALID_GROUP)
    {
        if (auto *mgr = ffcore::get_global_agent_manager())
            draw_field = mgr->get_group_flow(debug_draw_group);
    }

    if (draw_flow && draw_field)
    {
        Vector2 cell_size = floor_layer->get_tile_set()->get_tile_size();
        Rect2i used = floor_layer->get_used_rect();
        int skip = Math::max(1, debug_stride);

        for (int y = 0; y < draw_field->height(); y += skip)
        {
            for (int x = 0; x < draw_field->width(); x += skip)
            {
                ffcore::Vec2 dir_v = draw_field->dir(x, y);
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

void FlowFieldNative::assign_flow_to_group(int group_id, Vector2 goal, bool block_fences)
{
    if (group_id == ffcore::INVALID_GROUP || group_id >= ffcore::MAX_GROUPS)
    {
        UtilityFunctions::printerr("FlowFieldNative.assign_flow_to_group: invalid group_id ", group_id);
        return;
    }

    uint64_t serial = 0;
    {
        std::lock_guard<std::mutex> lock(async_mutex);
        serial = next_request_serial++;
        latest_request_serial_by_group[group_id] = serial;
    }

    // Synchronous path (legacy DLLs without an async worker). Compute + apply happen in
    // this one call, so agents only ever observe "queued" (set by mark_group_flow_queued)
    // for the frames before the drain reaches them; here we just make sure the group ends
    // at "none" on success and is never left stuck-frozen on a failure.
    ffcore::FlowField computed_field;
    if (block_fences)
    {
        AsyncFlowRequest request;
        request.group_id = group_id;
        request.serial = serial;
        if (!build_async_snapshot(goal, request.snapshot, true))
        {
            if (auto *m = ffcore::get_global_agent_manager())
                m->set_group_flow_wait(group_id, ffcore::GROUP_FLOW_WAIT_NONE);
            return;
        }
        AsyncFlowResult result = compute_async_request(request);
        if (!result.ok)
        {
            if (auto *m = ffcore::get_global_agent_manager())
                m->set_group_flow_wait(group_id, ffcore::GROUP_FLOW_WAIT_NONE);
            return;
        }
        computed_field.copy_from(result.field);
    }
    else
    {
        if (!rebuild_async(goal))
        {
            if (auto *m = ffcore::get_global_agent_manager())
                m->set_group_flow_wait(group_id, ffcore::GROUP_FLOW_WAIT_NONE);
            return;
        }
        computed_field.copy_from(field);
    }

    ffcore::AgentManager *mgr = ffcore::get_global_agent_manager();
    if (!mgr)
        return;

    auto *fm = ffcore::flowfields();
    ffcore::FlowFieldID fid = fm->register_copy(computed_field);
    ffcore::FlowField *new_flow = fm->get(fid);
    if (fid == ffcore::INVALID_FLOWFIELD || !new_flow)
    {
        UtilityFunctions::printerr("FlowFieldNative.assign_flow_to_group: flowfield pool exhausted for group ", group_id);
        mgr->set_group_flow_wait(group_id, ffcore::GROUP_FLOW_WAIT_NONE);
        return;
    }
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
    mgr->set_group_flow_wait(group_id, ffcore::GROUP_FLOW_WAIT_NONE);

    {
        std::lock_guard<std::mutex> lock(async_mutex);
        latest_applied_serial_by_group[group_id] = serial;
    }

    field.copy_from(computed_field);
    current_group_id = group_id;
    queue_redraw();
}

double FlowFieldNative::group_route_cost_at_world(int group_id, Vector2 world_pos) const
{
    if (group_id == ffcore::INVALID_GROUP || group_id >= ffcore::MAX_GROUPS)
        return std::numeric_limits<double>::infinity();
    ffcore::AgentManager *mgr = ffcore::get_global_agent_manager();
    if (!mgr)
        return std::numeric_limits<double>::infinity();
    const ffcore::FlowField *ff = mgr->get_group_flow(group_id);
    if (!ff || !ff->is_ready())
        return std::numeric_limits<double>::infinity();
    // The group's field stores its own cell_origin/tile, so convert against it.
    ffcore::Vec2i cell = ff->world_to_cell(ffcore::Vec2(world_pos.x, world_pos.y));
    return ff->route_cost_at_cell(cell);
}
