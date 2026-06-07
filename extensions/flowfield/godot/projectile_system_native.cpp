#include "projectile_system_native.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>
#include <godot_cpp/classes/tile_set.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "steering_system_native.h"
#include "spatial_grid_native.h"
#include "../core/global_config.h"

using namespace godot;

void ProjectileSystemNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_steering", "steering"), &ProjectileSystemNative::set_steering);
    ClassDB::bind_method(D_METHOD("set_grid", "grid"), &ProjectileSystemNative::set_grid);
    ClassDB::bind_method(D_METHOD("register_type", "config"), &ProjectileSystemNative::register_type);
    ClassDB::bind_method(D_METHOD("fire", "type_id", "pos", "dir", "owner_agent_id", "affected_smash_classes"), &ProjectileSystemNative::fire);
    ClassDB::bind_method(D_METHOD("get_active_positions", "type_id"), &ProjectileSystemNative::get_active_positions);
    ClassDB::bind_method(D_METHOD("get_active_count", "type_id"), &ProjectileSystemNative::get_active_count);
    ClassDB::bind_method(D_METHOD("get_type_count"), &ProjectileSystemNative::get_type_count);
    ClassDB::bind_method(D_METHOD("set_paused", "paused"), &ProjectileSystemNative::set_paused);
    ClassDB::bind_method(D_METHOD("set_wall_layer", "wall_layer", "bounds_layer"), &ProjectileSystemNative::set_wall_layer);
    ClassDB::bind_method(D_METHOD("clear_walls"), &ProjectileSystemNative::clear_walls);
}

ProjectileSystemNative::ProjectileSystemNative() {}
ProjectileSystemNative::~ProjectileSystemNative() {}

void ProjectileSystemNative::_ready()
{
    if (Engine::get_singleton()->is_editor_hint())
        return;

    Node *parent = get_parent();
    if (!parent)
        return;

    steering_node = Object::cast_to<Node2D>(parent->get_node_or_null("SteeringSystemNative"));
    grid_node = Object::cast_to<Node2D>(parent->get_node_or_null("SpatialGridNative"));

    auto *steering_native = Object::cast_to<SteeringSystemNative>(steering_node);
    auto *grid_native = Object::cast_to<SpatialGridNative>(grid_node);

    if (steering_native)
        system.set_steering(steering_native->get_system());

    if (grid_native)
        system.set_grid(grid_native->get_grid());
}

void ProjectileSystemNative::_process(double delta)
{
    if (paused)
        return;
    system.update(delta);
}

void ProjectileSystemNative::set_steering(Object *obj)
{
    steering_node = Object::cast_to<Node2D>(obj);
    auto *steering_native = Object::cast_to<SteeringSystemNative>(steering_node);
    if (steering_native)
        system.set_steering(steering_native->get_system());
}

void ProjectileSystemNative::set_grid(Object *obj)
{
    grid_node = Object::cast_to<Node2D>(obj);
    auto *grid_native = Object::cast_to<SpatialGridNative>(grid_node);
    if (grid_native)
        system.set_grid(grid_native->get_grid());
}

int ProjectileSystemNative::register_type(const Dictionary &cfg)
{
    ffcore::ProjectileTypeConfig c;
    if (cfg.has("speed")) c.speed = double(cfg["speed"]);
    if (cfg.has("lifetime")) c.lifetime = double(cfg["lifetime"]);
    if (cfg.has("radius")) c.radius = double(cfg["radius"]);
    if (cfg.has("aoe_radius")) c.aoe_radius = double(cfg["aoe_radius"]);
    if (cfg.has("smash_force")) c.smash_force = double(cfg["smash_force"]);
    if (cfg.has("smash_friction_loss")) c.smash_friction_loss = double(cfg["smash_friction_loss"]);
    if (cfg.has("smash_falloff")) c.smash_falloff = double(cfg["smash_falloff"]);
    if (cfg.has("smash_detach_flow")) c.smash_detach_flow = bool(cfg["smash_detach_flow"]);
    if (cfg.has("smash_control_suppression")) c.smash_control_suppression = double(cfg["smash_control_suppression"]);
    if (cfg.has("smash_control_suppression_duration")) c.smash_control_suppression_duration = double(cfg["smash_control_suppression_duration"]);
    if (cfg.has("stopped_by_walls")) c.stopped_by_walls = bool(cfg["stopped_by_walls"]);
    if (cfg.has("end_of_life_aoe_enabled")) c.end_of_life_aoe_enabled = bool(cfg["end_of_life_aoe_enabled"]);
    if (cfg.has("end_aoe_radius")) c.end_aoe_radius = double(cfg["end_aoe_radius"]);
    if (cfg.has("end_aoe_force")) c.end_aoe_force = double(cfg["end_aoe_force"]);
    if (cfg.has("end_aoe_friction_loss")) c.end_aoe_friction_loss = double(cfg["end_aoe_friction_loss"]);
    if (cfg.has("end_aoe_falloff")) c.end_aoe_falloff = double(cfg["end_aoe_falloff"]);
    if (cfg.has("end_aoe_detach_flow")) c.end_aoe_detach_flow = bool(cfg["end_aoe_detach_flow"]);
    if (cfg.has("end_aoe_control_suppression")) c.end_aoe_control_suppression = double(cfg["end_aoe_control_suppression"]);
    if (cfg.has("end_aoe_control_suppression_duration")) c.end_aoe_control_suppression_duration = double(cfg["end_aoe_control_suppression_duration"]);
    if (cfg.has("pool_size")) c.pool_size = int(cfg["pool_size"]);
    return system.register_type(c);
}

bool ProjectileSystemNative::fire(int type_id, const Vector2 &pos, const Vector2 &dir, int owner_agent_id, int affected_smash_classes)
{
    return system.fire(type_id,
                       ffcore::Vec2(pos.x, pos.y),
                       ffcore::Vec2(dir.x, dir.y),
                       owner_agent_id,
                       affected_smash_classes);
}

PackedVector2Array ProjectileSystemNative::get_active_positions(int type_id) const
{
    PackedVector2Array out;
    if (type_id < 0 || type_id >= static_cast<int>(system.type_count()))
        return out;
    const auto &pool = system.pool_for(type_id);
    out.resize(static_cast<int>(system.active_count(type_id)));
    int j = 0;
    for (const auto &p : pool)
    {
        if (!p.active)
            continue;
        out.set(j++, Vector2(p.pos.x, p.pos.y));
    }
    return out;
}

int ProjectileSystemNative::get_active_count(int type_id) const
{
    return static_cast<int>(system.active_count(type_id));
}

int ProjectileSystemNative::get_type_count() const
{
    return static_cast<int>(system.type_count());
}

void ProjectileSystemNative::set_wall_layer(Object *wall_layer_obj, Object *bounds_layer_obj)
{
    auto *wall_layer = Object::cast_to<TileMapLayer>(wall_layer_obj);
    if (!wall_layer)
    {
        system.clear_wall_grid();
        return;
    }
    auto *bounds_layer = Object::cast_to<TileMapLayer>(bounds_layer_obj);
    if (!bounds_layer)
        bounds_layer = wall_layer;

    // Tile size from the layer's TileSet (square tiles assumed, like FlowField).
    double tile_size = ffcore::globalconfig().tile_size;
    Ref<TileSet> ts = wall_layer->get_tile_set();
    if (ts.is_valid())
        tile_size = std::max(1.0, static_cast<double>(ts->get_tile_size().x));
    if (tile_size <= 0.0)
        tile_size = 1.0;

    // Mark wall cells into a grid indexed in the SAME world->cell space the
    // simulation uses: cell = floor(world_center / tile_size). Converting each
    // wall cell to its world center via the layer transform keeps the mask
    // aligned even if the tilemap is offset (no rotation/scale expected).
    Array walls = wall_layer->get_used_cells();
    const int n = static_cast<int>(walls.size());
    if (n == 0)
    {
        system.clear_wall_grid();
        return;
    }

    std::vector<int> cx(n);
    std::vector<int> cy(n);
    int min_x = INT32_MAX, min_y = INT32_MAX, max_x = INT32_MIN, max_y = INT32_MIN;
    for (int i = 0; i < n; ++i)
    {
        Vector2i cell = walls[i];
        Vector2 world_center = wall_layer->to_global(wall_layer->map_to_local(cell));
        int gx = static_cast<int>(std::floor(world_center.x / tile_size));
        int gy = static_cast<int>(std::floor(world_center.y / tile_size));
        cx[i] = gx;
        cy[i] = gy;
        min_x = std::min(min_x, gx);
        min_y = std::min(min_y, gy);
        max_x = std::max(max_x, gx);
        max_y = std::max(max_y, gy);
    }
    (void)bounds_layer; // origin derived from wall extents below

    const int width = max_x - min_x + 1;
    const int height = max_y - min_y + 1;
    std::vector<std::uint8_t> mask(static_cast<std::size_t>(width) * height, 0);
    for (int i = 0; i < n; ++i)
    {
        int lx = cx[i] - min_x;
        int ly = cy[i] - min_y;
        mask[static_cast<std::size_t>(ly) * width + lx] = 1;
    }

    system.set_wall_grid(min_x, min_y, width, height, tile_size, mask);
}

void ProjectileSystemNative::clear_walls()
{
    system.clear_wall_grid();
}
