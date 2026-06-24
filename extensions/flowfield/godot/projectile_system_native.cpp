#include "projectile_system_native.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>
#include <godot_cpp/classes/tile_set.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
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
    ClassDB::bind_method(D_METHOD("get_impacts"), &ProjectileSystemNative::get_impacts);
    ClassDB::bind_method(D_METHOD("set_paused", "paused"), &ProjectileSystemNative::set_paused);
    ClassDB::bind_method(D_METHOD("set_wall_layer", "wall_layer", "bounds_layer"), &ProjectileSystemNative::set_wall_layer);
    ClassDB::bind_method(D_METHOD("clear_walls"), &ProjectileSystemNative::clear_walls);
    ClassDB::bind_method(D_METHOD("set_static_collision_layers", "configs", "bounds_layer"), &ProjectileSystemNative::set_static_collision_layers);
    ClassDB::bind_method(D_METHOD("set_static_collision_cells", "cells", "channels", "tile_size"), &ProjectileSystemNative::set_static_collision_cells);
    ClassDB::bind_method(D_METHOD("clear_static_collisions"), &ProjectileSystemNative::clear_static_collisions);
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
    {
        // No update => no new impacts; drop any stale ones so GDScript doesn't
        // re-render the same ring every paused frame.
        system.clear_impacts();
        return;
    }
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
    if (cfg.has("damage")) c.damage = int(cfg["damage"]);
    if (cfg.has("static_collision_mask"))
        c.static_collision_mask = static_cast<std::uint32_t>(int64_t(cfg["static_collision_mask"]));
    else if (cfg.has("stopped_by_walls"))
        c.static_collision_mask = bool(cfg["stopped_by_walls"]) ? 1u : 0u;
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

Array ProjectileSystemNative::get_impacts() const
{
    Array out;
    const auto &events = system.impacts();
    for (const auto &e : events)
    {
        Dictionary d;
        d["pos"] = Vector2(e.pos.x, e.pos.y);
        d["dir"] = Vector2(e.dir.x, e.dir.y);
        d["radius"] = e.radius;
        d["type_id"] = e.type_id;
        d["kind"] = e.kind;
        d["collider_mask"] = static_cast<int64_t>(e.collider_mask);
        d["collider_cell"] = Vector2i(e.collider_cell.x, e.collider_cell.y);
        out.push_back(d);
    }
    return out;
}

void ProjectileSystemNative::set_wall_layer(Object *wall_layer_obj, Object *bounds_layer_obj)
{
    auto *wall_layer = Object::cast_to<TileMapLayer>(wall_layer_obj);
    if (!wall_layer)
    {
        system.clear_static_collision_grid();
        return;
    }

    Dictionary config;
    config["layer"] = wall_layer;
    config["channel"] = 1;
    Array configs;
    configs.push_back(config);
    set_static_collision_layers(configs, bounds_layer_obj);
}

void ProjectileSystemNative::set_static_collision_layers(const Array &configs, Object *bounds_layer_obj)
{
    auto *bounds_layer = Object::cast_to<TileMapLayer>(bounds_layer_obj);
    TileMapLayer *tile_size_layer = bounds_layer;
    if (!tile_size_layer)
    {
        for (int i = 0; i < configs.size(); ++i)
        {
            Dictionary config = configs[i];
            Object *layer_obj = config.get("layer", Variant());
            tile_size_layer = Object::cast_to<TileMapLayer>(layer_obj);
            if (tile_size_layer)
                break;
        }
    }

    // Tile size from the bounds/first layer (square tiles assumed, like FlowField).
    double tile_size = ffcore::globalconfig().tile_size;
    if (tile_size_layer)
    {
        Ref<TileSet> ts = tile_size_layer->get_tile_set();
        if (ts.is_valid())
            tile_size = std::max(1.0, static_cast<double>(ts->get_tile_size().x));
    }
    if (tile_size <= 0.0)
        tile_size = 1.0;

    struct UploadedCell
    {
        int x;
        int y;
        std::uint32_t channel;
    };
    std::vector<UploadedCell> uploaded_cells;
    int min_x = INT32_MAX, min_y = INT32_MAX, max_x = INT32_MIN, max_y = INT32_MIN;

    // Mark collider cells into the SAME world->cell space the
    // simulation uses: cell = floor(world_center / tile_size). Converting each
    // layer cell to its world center via the layer transform keeps the mask
    // aligned even if the tilemap is offset (no rotation/scale expected).
    for (int config_index = 0; config_index < configs.size(); ++config_index)
    {
        Dictionary config = configs[config_index];
        Object *layer_obj = config.get("layer", Variant());
        auto *layer = Object::cast_to<TileMapLayer>(layer_obj);
        const int64_t channel_value = int64_t(config.get("channel", 0));
        if (!layer || channel_value <= 0 ||
            channel_value > static_cast<int64_t>(std::numeric_limits<std::uint32_t>::max()))
            continue;
        const std::uint32_t channel = static_cast<std::uint32_t>(channel_value);

        Array atlas_filter = config.get("atlas_coords", Array());
        Array cells = layer->get_used_cells();
        for (int cell_index = 0; cell_index < cells.size(); ++cell_index)
        {
            Vector2i cell = cells[cell_index];
            if (!atlas_filter.is_empty())
            {
                const Vector2i atlas = layer->get_cell_atlas_coords(cell);
                bool accepted = false;
                for (int atlas_index = 0; atlas_index < atlas_filter.size(); ++atlas_index)
                {
                    const Vector2i allowed_atlas = atlas_filter[atlas_index];
                    if (atlas == allowed_atlas)
                    {
                        accepted = true;
                        break;
                    }
                }
                if (!accepted)
                    continue;
            }

            Vector2 world_center = layer->to_global(layer->map_to_local(cell));
            int gx = static_cast<int>(std::floor(world_center.x / tile_size));
            int gy = static_cast<int>(std::floor(world_center.y / tile_size));
            uploaded_cells.push_back(UploadedCell{gx, gy, channel});
            min_x = std::min(min_x, gx);
            min_y = std::min(min_y, gy);
            max_x = std::max(max_x, gx);
            max_y = std::max(max_y, gy);
        }
    }

    if (uploaded_cells.empty())
    {
        system.clear_static_collision_grid();
        return;
    }

    const int width = max_x - min_x + 1;
    const int height = max_y - min_y + 1;
    std::vector<std::uint32_t> mask(static_cast<std::size_t>(width) * height, 0);
    for (const UploadedCell &cell : uploaded_cells)
    {
        int lx = cell.x - min_x;
        int ly = cell.y - min_y;
        mask[static_cast<std::size_t>(ly) * width + lx] |= cell.channel;
    }

    system.set_static_collision_grid(min_x, min_y, width, height, tile_size, mask);
}

void ProjectileSystemNative::set_static_collision_cells(const PackedVector2Array &cells,
                                                        const PackedInt32Array &channels,
                                                        double tile_size)
{
    const int count = std::min(cells.size(), channels.size());
    if (count <= 0)
    {
        system.clear_static_collision_grid();
        return;
    }

    int min_x = INT32_MAX, min_y = INT32_MAX, max_x = INT32_MIN, max_y = INT32_MIN;
    for (int i = 0; i < count; ++i)
    {
        const Vector2 cell = cells[i];
        const int x = static_cast<int>(cell.x);
        const int y = static_cast<int>(cell.y);
        min_x = std::min(min_x, x);
        min_y = std::min(min_y, y);
        max_x = std::max(max_x, x);
        max_y = std::max(max_y, y);
    }

    const int width = max_x - min_x + 1;
    const int height = max_y - min_y + 1;
    std::vector<std::uint32_t> mask(static_cast<std::size_t>(width) * height, 0);
    for (int i = 0; i < count; ++i)
    {
        const Vector2 cell = cells[i];
        const int x = static_cast<int>(cell.x) - min_x;
        const int y = static_cast<int>(cell.y) - min_y;
        mask[static_cast<std::size_t>(y) * width + x] |= static_cast<std::uint32_t>(channels[i]);
    }
    system.set_static_collision_grid(min_x, min_y, width, height, std::max(1.0, tile_size), mask);
}

void ProjectileSystemNative::clear_walls()
{
    system.clear_static_collision_grid();
}

void ProjectileSystemNative::clear_static_collisions()
{
    system.clear_static_collision_grid();
}
