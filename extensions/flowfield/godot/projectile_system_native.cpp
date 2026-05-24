#include "projectile_system_native.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "steering_system_native.h"
#include "spatial_grid_native.h"

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
