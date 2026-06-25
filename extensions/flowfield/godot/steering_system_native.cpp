#include "steering_system_native.h"
#include "flow_field_native.h"
#include "spatial_grid_native.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/theme.hpp>
#include <godot_cpp/classes/theme_db.hpp>
#include "../agent_manager/agent_manager.h"
#include <godot_cpp/classes/engine.hpp>
#include "agent_manager_native.h"
#include <godot_cpp/variant/dictionary.hpp>
#include "../flow/flow_field.h"
#include "../core/global_config.h"
#include <cmath>
#include <vector>
#include <algorithm>

using namespace godot;

namespace
{
    const std::vector<Vector2> &debug_unit_circle_points()
    {
        static std::vector<Vector2> points;
        if (!points.empty())
            return points;

        constexpr int segment_count = 32;
        points.reserve(segment_count + 1);
        for (int i = 0; i <= segment_count; ++i)
        {
            double angle = (double)i / (double)segment_count * 6.28318530717958647692;
            points.emplace_back(std::cos(angle), std::sin(angle));
        }
        return points;
    }
}

void SteeringSystemNative::_bind_methods()
{

    ClassDB::bind_method(D_METHOD("set_flowfield", "flowfield"), &SteeringSystemNative::set_flowfield);
    ClassDB::bind_method(D_METHOD("set_grid", "grid"), &SteeringSystemNative::set_grid);
    ClassDB::bind_method(D_METHOD("get_agent_id", "agent"), &SteeringSystemNative::get_agent_id);
    ClassDB::bind_method(D_METHOD("register_node_mapping", "node", "agent_id"), &SteeringSystemNative::register_node_mapping);
    ClassDB::bind_method(D_METHOD("set_agent_control_mode", "agent_id", "mode"), &SteeringSystemNative::set_agent_control_mode);
    ClassDB::bind_method(D_METHOD("set_agent_input", "agent_id", "direction"), &SteeringSystemNative::set_agent_input);
    ClassDB::bind_method(D_METHOD("set_agent_manual_motion", "agent_id", "acceleration", "deceleration"), &SteeringSystemNative::set_agent_manual_motion);
    ClassDB::bind_method(D_METHOD("set_agent_profile", "agent_id", "profile"), &SteeringSystemNative::set_agent_profile);
    ClassDB::bind_method(D_METHOD("get_agent_position", "agent_id"), &SteeringSystemNative::get_agent_position);
    ClassDB::bind_method(D_METHOD("get_agent_velocity", "agent_id"), &SteeringSystemNative::get_agent_velocity);
    ClassDB::bind_method(D_METHOD("apply_smash_impulse", "agent_id", "direction", "force", "friction_loss", "delay", "detach_flow", "control_suppression", "control_suppression_duration"), &SteeringSystemNative::apply_smash_impulse);
    ClassDB::bind_method(D_METHOD("apply_area_smash", "position", "radius", "direction", "force", "friction_loss", "falloff", "detach_flow", "control_suppression", "control_suppression_duration", "ignored_agent_id", "affected_smash_classes"), &SteeringSystemNative::apply_area_smash);
    ClassDB::bind_method(D_METHOD("apply_cone_smash", "position", "radius", "direction", "angle_degrees", "force", "friction_loss", "falloff", "detach_flow", "control_suppression", "control_suppression_duration", "ignored_agent_id", "affected_smash_classes"), &SteeringSystemNative::apply_cone_smash);
    ClassDB::bind_method(D_METHOD("apply_explosion", "position", "radius", "intensity", "friction_loss"), &SteeringSystemNative::apply_explosion);
    ClassDB::bind_method(D_METHOD("apply_explosion_filtered", "position", "radius", "intensity", "friction_loss", "falloff", "ignored_agent_id", "control_suppression", "control_suppression_duration", "affected_smash_classes"), &SteeringSystemNative::apply_explosion_filtered);
    ClassDB::bind_method(D_METHOD("spawn_aoe_zone", "position", "direction", "radius", "angle_degrees", "duration", "force", "friction_loss", "falloff", "detach_flow", "control_suppression", "control_suppression_duration", "ignored_agent_id", "affected_smash_classes", "follow_offset", "damage"), &SteeringSystemNative::spawn_aoe_zone);
    ClassDB::bind_method(D_METHOD("start_continuous_aoe", "position", "direction", "radius", "angle_degrees", "force", "friction_loss", "falloff", "detach_flow", "control_suppression", "control_suppression_duration", "ignored_agent_id", "affected_smash_classes", "follow_offset", "damage", "damage_frequency", "repulse_frequency"), &SteeringSystemNative::start_continuous_aoe);
    ClassDB::bind_method(D_METHOD("update_continuous_aoe", "continuous_id", "direction", "follow_offset"), &SteeringSystemNative::update_continuous_aoe);
    ClassDB::bind_method(D_METHOD("stop_continuous_aoe", "continuous_id"), &SteeringSystemNative::stop_continuous_aoe);
    ClassDB::bind_method(D_METHOD("take_damage_events"), &SteeringSystemNative::take_damage_events);
    ClassDB::bind_method(D_METHOD("register_static_obstacle", "obstacle_id", "position", "radius", "push_strength"), &SteeringSystemNative::register_static_obstacle, DEFVAL(1.0));
    ClassDB::bind_method(D_METHOD("unregister_static_obstacle", "obstacle_id"), &SteeringSystemNative::unregister_static_obstacle);
    ClassDB::bind_method(D_METHOD("clear_static_obstacles"), &SteeringSystemNative::clear_static_obstacles);
    ClassDB::bind_method(D_METHOD("get_static_obstacle_count"), &SteeringSystemNative::get_static_obstacle_count);
    ClassDB::bind_method(D_METHOD("set_directional_cell_field", "field_id", "origin_world", "tile_size", "speed", "cells", "directions", "sample_offset_world", "sample_radius_world"), &SteeringSystemNative::set_directional_cell_field, DEFVAL(Vector2()), DEFVAL(0.0));
    ClassDB::bind_method(D_METHOD("clear_directional_cell_field", "field_id"), &SteeringSystemNative::clear_directional_cell_field);
    ClassDB::bind_method(D_METHOD("clear_directional_cell_fields"), &SteeringSystemNative::clear_directional_cell_fields);
    ClassDB::bind_method(D_METHOD("bind_phase_directional_cell_field", "phase", "field_id"), &SteeringSystemNative::bind_phase_directional_cell_field);
    ClassDB::bind_method(D_METHOD("clear_phase_directional_cell_field", "phase"), &SteeringSystemNative::clear_phase_directional_cell_field);
    ClassDB::bind_method(D_METHOD("get_agents_in_map_cell", "cell"), &SteeringSystemNative::get_agents_in_map_cell);
    ClassDB::bind_method(D_METHOD("get_agent_debug_snapshot", "agent_id"), &SteeringSystemNative::get_agent_debug_snapshot);
    ClassDB::bind_method(D_METHOD("set_paused", "paused"), &SteeringSystemNative::set_paused);
    ClassDB::bind_method(D_METHOD("set_debug_disable_all_debug", "enabled"), &SteeringSystemNative::set_debug_disable_all_debug);
    ClassDB::bind_method(D_METHOD("get_debug_disable_all_debug"), &SteeringSystemNative::get_debug_disable_all_debug);
    ClassDB::bind_method(D_METHOD("set_debug_draw_world_hitbox", "enabled"), &SteeringSystemNative::set_debug_draw_world_hitbox);
    ClassDB::bind_method(D_METHOD("get_debug_draw_world_hitbox"), &SteeringSystemNative::get_debug_draw_world_hitbox);
    ClassDB::bind_method(D_METHOD("set_debug_draw_bottleneck_zones", "enabled"), &SteeringSystemNative::set_debug_draw_bottleneck_zones);
    ClassDB::bind_method(D_METHOD("get_debug_draw_bottleneck_zones"), &SteeringSystemNative::get_debug_draw_bottleneck_zones);
    ClassDB::bind_method(D_METHOD("set_debug_disable_bottlenecks", "enabled"), &SteeringSystemNative::set_debug_disable_bottlenecks);
    ClassDB::bind_method(D_METHOD("get_debug_disable_bottlenecks"), &SteeringSystemNative::get_debug_disable_bottlenecks);
    ClassDB::bind_method(D_METHOD("set_debug_draw_fight_hitbox", "enabled"), &SteeringSystemNative::set_debug_draw_fight_hitbox);
    ClassDB::bind_method(D_METHOD("get_debug_draw_fight_hitbox"), &SteeringSystemNative::get_debug_draw_fight_hitbox);
    ClassDB::bind_method(D_METHOD("set_debug_show_agent_state_labels", "enabled"), &SteeringSystemNative::set_debug_show_agent_state_labels);
    ClassDB::bind_method(D_METHOD("get_debug_show_agent_state_labels"), &SteeringSystemNative::get_debug_show_agent_state_labels);
    ClassDB::bind_method(D_METHOD("set_debug_redraw_interval", "seconds"), &SteeringSystemNative::set_debug_redraw_interval);
    ClassDB::bind_method(D_METHOD("get_debug_redraw_interval"), &SteeringSystemNative::get_debug_redraw_interval);
    ClassDB::bind_method(D_METHOD("set_debug_static_obstacles", "enabled"), &SteeringSystemNative::set_debug_static_obstacles);
    ClassDB::bind_method(D_METHOD("get_debug_static_obstacles"), &SteeringSystemNative::get_debug_static_obstacles);

}

SteeringSystemNative::SteeringSystemNative()
{
}
SteeringSystemNative::~SteeringSystemNative() {}

void SteeringSystemNative::_ready()
{
    if (Engine::get_singleton()->is_editor_hint())
        return;

    set_z_index(3000);
    set_z_as_relative(false);
    set_as_top_level(true);

    Node *parent = get_parent();
    if (!parent)
        return;

    flowfield = Object::cast_to<Node2D>(parent->get_node_or_null("FlowFieldNative"));
    grid = Object::cast_to<Node2D>(parent->get_node_or_null("SpatialGridNative"));
    agent_manager = Object::cast_to<AgentManagerNative>(parent->get_node_or_null("AgentManagerNative"));

    if (flowfield && grid)
    {
        auto *ff_native = Object::cast_to<FlowFieldNative>(flowfield);
        auto *grid_native = Object::cast_to<SpatialGridNative>(grid);

        if (ff_native && grid_native)
        {
            system.set_default_flowfield(ff_native->get_field());
            system.set_grid(grid_native->get_grid());
            system.set_agent_manager(ffcore::get_global_agent_manager());
        }
    }
}

void SteeringSystemNative::set_flowfield(Object *obj)
{
    flowfield = Object::cast_to<Node2D>(obj);
}

void SteeringSystemNative::register_node_mapping(Node2D *node, int agent_id)
{
    agent_map[node] = agent_id;
}

void SteeringSystemNative::unregister_node_mapping(int agent_id)
{
    for (auto it = agent_map.begin(); it != agent_map.end();)
    {
        if (it->second == agent_id)
            it = agent_map.erase(it);
        else
            ++it;
    }
    // Full per-agent cleanup: label caches plus the state-tracking maps.
    agent_last_flow.erase(agent_id);
    agent_last_active.erase(agent_id);
    agent_last_phase.erase(agent_id);
    _reset_agent_cache(agent_id);
}

void SteeringSystemNative::set_grid(Object *obj)
{
    grid = Object::cast_to<Node2D>(obj);
}

void SteeringSystemNative::set_paused(bool p)
{
    ffcore::globalconfig().paused = p;
}

void SteeringSystemNative::set_debug_disable_all_debug(bool enabled)
{
    ffcore::globalconfig().debug_disable_all_debug = enabled;
    queue_redraw();
}
bool SteeringSystemNative::get_debug_disable_all_debug() const { return ffcore::globalconfig().debug_disable_all_debug; }

void SteeringSystemNative::set_debug_draw_world_hitbox(bool enabled)
{
    ffcore::globalconfig().debug_draw_world_hitbox = enabled;
    queue_redraw();
}
bool SteeringSystemNative::get_debug_draw_world_hitbox() const { return ffcore::globalconfig().effective_debug_draw_world_hitbox(); }

void SteeringSystemNative::set_debug_draw_bottleneck_zones(bool enabled)
{
    ffcore::globalconfig().debug_draw_bottleneck_zones = enabled;
    queue_redraw();
}
bool SteeringSystemNative::get_debug_draw_bottleneck_zones() const { return ffcore::globalconfig().effective_debug_draw_bottleneck_zones(); }

void SteeringSystemNative::set_debug_disable_bottlenecks(bool enabled)
{
    ffcore::globalconfig().debug_disable_bottlenecks = enabled;
    queue_redraw();
}
bool SteeringSystemNative::get_debug_disable_bottlenecks() const { return ffcore::globalconfig().effective_debug_disable_bottlenecks(); }

void SteeringSystemNative::set_debug_draw_fight_hitbox(bool enabled)
{
    ffcore::globalconfig().debug_draw_fight_hitbox = enabled;
    queue_redraw();
}
bool SteeringSystemNative::get_debug_draw_fight_hitbox() const { return ffcore::globalconfig().effective_debug_draw_fight_hitbox(); }

void SteeringSystemNative::set_debug_show_agent_state_labels(bool enabled)
{
    ffcore::globalconfig().debug_show_agent_state_labels = enabled;
    queue_redraw();
}
bool SteeringSystemNative::get_debug_show_agent_state_labels() const { return ffcore::globalconfig().effective_debug_show_agent_state_labels(); }

void SteeringSystemNative::set_debug_redraw_interval(double seconds)
{
    ffcore::globalconfig().debug_redraw_interval = seconds < 0.0 ? 0.0 : seconds;
    ffcore::globalconfig().debug_redraw_accum = 0.0;
    queue_redraw();
}
double SteeringSystemNative::get_debug_redraw_interval() const { return ffcore::globalconfig().debug_redraw_interval; }

void SteeringSystemNative::set_debug_static_obstacles(bool enabled)
{
    ffcore::globalconfig().debug_static_obstacles = enabled;
}
bool SteeringSystemNative::get_debug_static_obstacles() const { return ffcore::globalconfig().debug_static_obstacles; }

void SteeringSystemNative::apply_explosion(const Vector2 &position, double radius, double intensity, double friction_loss)
{
    system.apply_explosion(ffcore::Vec2(position.x, position.y), radius, intensity, friction_loss);
}

void SteeringSystemNative::apply_explosion_filtered(const Vector2 &position, double radius, double intensity, double friction_loss, double falloff, int ignored_agent_id, double control_suppression, double control_suppression_duration, int affected_smash_classes)
{
    system.apply_explosion_filtered(ffcore::Vec2(position.x, position.y), radius, intensity, friction_loss, falloff, ignored_agent_id, control_suppression, control_suppression_duration, affected_smash_classes);
}

void SteeringSystemNative::spawn_aoe_zone(const Vector2 &position, const Vector2 &direction, double radius, double angle_degrees, double duration, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes, const Vector2 &follow_offset, int damage)
{
    system.spawn_aoe_zone(
        ffcore::Vec2(position.x, position.y),
        ffcore::Vec2(direction.x, direction.y),
        radius,
        angle_degrees,
        duration,
        force,
        friction_loss,
        falloff,
        detach_flow,
        control_suppression,
        control_suppression_duration,
        ignored_agent_id,
        affected_smash_classes,
        ffcore::Vec2(follow_offset.x, follow_offset.y),
        damage);
}

int SteeringSystemNative::start_continuous_aoe(const Vector2 &position, const Vector2 &direction, double radius, double angle_degrees, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes, const Vector2 &follow_offset, int damage, double damage_frequency, double repulse_frequency)
{
    return system.start_continuous_aoe(
        ffcore::Vec2(position.x, position.y), ffcore::Vec2(direction.x, direction.y), radius,
        angle_degrees, force, friction_loss, falloff, detach_flow, control_suppression,
        control_suppression_duration, ignored_agent_id, affected_smash_classes,
        ffcore::Vec2(follow_offset.x, follow_offset.y), damage, damage_frequency, repulse_frequency);
}

bool SteeringSystemNative::update_continuous_aoe(int continuous_id, const Vector2 &direction, const Vector2 &follow_offset)
{
    return system.update_continuous_aoe(continuous_id, ffcore::Vec2(direction.x, direction.y), ffcore::Vec2(follow_offset.x, follow_offset.y));
}

void SteeringSystemNative::stop_continuous_aoe(int continuous_id)
{
    system.stop_continuous_aoe(continuous_id);
}

Array SteeringSystemNative::take_damage_events()
{
    Array out;
    for (const ffcore::DamageEvent &event : system.take_damage_events())
    {
        Dictionary data;
        data["agent_id"] = event.agent_id;
        data["damage"] = event.damage;
        data["position"] = Vector2(event.position.x, event.position.y);
        out.push_back(data);
    }
    return out;
}

void SteeringSystemNative::apply_smash_impulse(int agent_id, const Vector2 &direction, double force, double friction_loss, double delay, bool detach_flow, double control_suppression, double control_suppression_duration)
{
    system.apply_smash_impulse(agent_id, ffcore::Vec2(direction.x, direction.y), force, friction_loss, delay, detach_flow, control_suppression, control_suppression_duration);
}

void SteeringSystemNative::apply_area_smash(const Vector2 &position, double radius, const Vector2 &direction, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes)
{
    system.apply_area_smash(
        ffcore::Vec2(position.x, position.y),
        radius,
        ffcore::Vec2(direction.x, direction.y),
        force,
        friction_loss,
        falloff,
        detach_flow,
        control_suppression,
        control_suppression_duration,
        ignored_agent_id,
        affected_smash_classes);
}

void SteeringSystemNative::apply_cone_smash(const Vector2 &position, double radius, const Vector2 &direction, double angle_degrees, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes)
{
    system.apply_cone_smash(
        ffcore::Vec2(position.x, position.y),
        radius,
        ffcore::Vec2(direction.x, direction.y),
        angle_degrees,
        force,
        friction_loss,
        falloff,
        detach_flow,
        control_suppression,
        control_suppression_duration,
        ignored_agent_id,
        affected_smash_classes);
}

void SteeringSystemNative::set_agent_control_mode(int agent_id, int mode)
{
    system.set_agent_control_mode(agent_id, mode);
}

void SteeringSystemNative::set_agent_input(int agent_id, const Vector2 &direction)
{
    system.set_agent_input(agent_id, ffcore::Vec2(direction.x, direction.y));
}

void SteeringSystemNative::set_agent_manual_motion(int agent_id, double acceleration, double deceleration)
{
    system.set_agent_manual_motion(agent_id, acceleration, deceleration);
}

void SteeringSystemNative::set_agent_profile(int agent_id, const Dictionary &profile)
{
    ffcore::AgentProfile native_profile;
    if (const ffcore::AgentData *existing = system.get_agent(agent_id))
        native_profile = existing->profile;

    if (profile.has("crowd_push_strength"))
        native_profile.crowd_push_strength = double(profile["crowd_push_strength"]);
    if (profile.has("crowd_resist_strength"))
        native_profile.crowd_resist_strength = double(profile["crowd_resist_strength"]);
    if (profile.has("world_radius"))
        native_profile.world_radius = double(profile["world_radius"]);
    if (profile.has("max_speed"))
        native_profile.max_speed = double(profile["max_speed"]);
    if (profile.has("foot_offset_y"))
        native_profile.foot_offset_y = double(profile["foot_offset_y"]);
    if (profile.has("fight_offset_y"))
        native_profile.fight_offset_y = double(profile["fight_offset_y"]);
    if (profile.has("fight_half_w"))
        native_profile.fight_half_w = double(profile["fight_half_w"]);
    if (profile.has("fight_half_h"))
        native_profile.fight_half_h = double(profile["fight_half_h"]);
    if (profile.has("smash_class"))
        native_profile.smash_class = int(profile["smash_class"]);
    if (profile.has("weapon_immune"))
        native_profile.weapon_immune = bool(profile["weapon_immune"]);

    system.set_agent_profile(agent_id, native_profile);
}

Vector2 SteeringSystemNative::get_agent_position(int agent_id) const
{
    const ffcore::AgentData *a = system.get_agent(agent_id);
    if (!a)
        return Vector2();
    return Vector2(a->position.x, a->position.y);
}

Vector2 SteeringSystemNative::get_agent_velocity(int agent_id) const
{
    const ffcore::AgentData *a = system.get_agent(agent_id);
    if (!a)
        return Vector2();
    return Vector2(a->velocity.x, a->velocity.y);
}

void SteeringSystemNative::_reset_agent_cache(int agent_id)
{
    // Clears only the label caches. The per-agent state maps (flow/active/phase) are
    // owned by _process(), which re-stores them on the same transition that triggers
    // this reset; full removal of those happens in unregister_node_mapping().
    debug_agent_label_cache.erase(agent_id);
    debug_agent_label_next_refresh.erase(agent_id);
}

int SteeringSystemNative::_direction_code(const Vector2 &v) const
{
    if (v.length_squared() < 1e-6)
        return -1;
    if (Math::abs(v.x) >= Math::abs(v.y))
        return v.x >= 0.0 ? 0 : 1; // E or W
    return v.y >= 0.0 ? 2 : 3;     // S or N
}

Vector2 SteeringSystemNative::_goal_position_for_agent(const ffcore::AgentData *a) const
{
    if (!a || !a->flow)
        return Vector2();
    ffcore::Vec2 g = a->flow->goal_center_world();
    return Vector2(g.x, g.y);
}

Dictionary SteeringSystemNative::_agent_summary(const ffcore::AgentData *a) const
{
    Dictionary d;
    if (!a)
        return d;
    Vector2 vel(a->velocity.x, a->velocity.y);

    d["id"] = a->id;
    d["is_moving"] = a->moving;
    d["velocity"] = vel;
    d["velocity_len"] = vel.length();
    int code = _direction_code(vel);
    d["dir_code"] = code;
    ffcore::Vec2 pos = a->position + ffcore::Vec2(0, a->profile.foot_offset_y);
    d["world_pos"] = Vector2(pos.x, pos.y);
    return d;
}

String SteeringSystemNative::_agent_phase_label(const ffcore::AgentData *a) const
{
    if (!a)
        return String();
    switch (a->phase)
    {
    case ffcore::AgentPhase::FlowIn:
        return "flow in";
    case ffcore::AgentPhase::AstarIn:
        return "astar in";
    case ffcore::AgentPhase::Eating:
        return String("eating ") + String::num_int64((int64_t)a->eating_seconds) + "s";
    case ffcore::AgentPhase::AstarOut:
        return "astar out";
    case ffcore::AgentPhase::FlowOut:
        return "flow out";
    case ffcore::AgentPhase::WaitingNewStatus:
        return "waiting new status";
    case ffcore::AgentPhase::Drowning:
        return "drowning";
    case ffcore::AgentPhase::None:
    default:
        return String();
    }
}

String SteeringSystemNative::_agent_physics_label(const ffcore::AgentData *a) const
{
    if (!a)
        return "missing";

    Vector2 vel(a->velocity.x, a->velocity.y);
    double velocity_len = vel.length();

    if (a->smash_pending)
        return "smash pending";
    if (a->is_propelled)
        return "propelled";
    if (a->phase != ffcore::AgentPhase::None)
        return String();
    if (a->control_mode == ffcore::AgentControlMode::Manual)
        return velocity_len > 1.0 ? "manual moving" : "manual idle";
    if (!a->active)
    {
        if (a->phase == ffcore::AgentPhase::Eating)
            return "eating idle";
        if (a->path_arrived)
            return "path arrived";
        return a->flow ? "inactive" : "inactive / no flow";
    }
    if (!a->flow)
    {
        // No flow pointer is normal during A* path-follow states; don't report it as
        // broken. Prefer the path-follow state, then fall back to a phase-aware hint.
        if (a->path_active)
            return "path";
        if (a->path_arrived)
            return "path arrived";
        if (a->phase != ffcore::AgentPhase::None)
            return "no flow ptr";
        return "no flow";
    }
    if (!a->flow->is_ready())
        return "flow not ready";
    if (a->lost_timer > 0.0)
        return "lost";
    if (a->debug_bottleneck_wait)
        return "bottleneck wait";
    if (a->debug_in_bottleneck_state)
        return "bottleneck";
    if (a->stuck_in_wall_accum > 0.0)
        return "stuck in wall";
    if (a->target_radius_timer > 0.0)
        return "target wait";
    if (a->micro_osc >= ffcore::globalconfig().micro_osc_label_min)
        return "flow osc";
    if (velocity_len <= 1.0)
        return "flow idle";

    return "flow";
}

void SteeringSystemNative::register_static_obstacle(int obstacle_id, const Vector2 &position, double radius, double push_strength)
{
    system.register_static_obstacle(obstacle_id, ffcore::Vec2(position.x, position.y), radius, push_strength);
}

void SteeringSystemNative::unregister_static_obstacle(int obstacle_id)
{
    system.unregister_static_obstacle(obstacle_id);
}

void SteeringSystemNative::clear_static_obstacles()
{
    system.clear_static_obstacles();
}

int SteeringSystemNative::get_static_obstacle_count() const
{
    return system.get_static_obstacle_count();
}

void SteeringSystemNative::set_directional_cell_field(int field_id, const Vector2 &origin_world, double tile_size, double speed, const PackedVector2Array &cells, const PackedVector2Array &directions, const Vector2 &sample_offset_world, double sample_radius_world)
{
    const int count = std::min(cells.size(), directions.size());
    std::vector<ffcore::Vec2i> native_cells;
    std::vector<ffcore::Vec2> native_directions;
    native_cells.reserve(count);
    native_directions.reserve(count);
    for (int i = 0; i < count; ++i)
    {
        const Vector2 cell = cells[i];
        const Vector2 direction = directions[i];
        native_cells.emplace_back((int)cell.x, (int)cell.y);
        native_directions.emplace_back(direction.x, direction.y);
    }
    system.set_directional_cell_field(
        field_id,
        ffcore::Vec2(origin_world.x, origin_world.y),
        tile_size,
        speed,
        native_cells,
        native_directions,
        ffcore::Vec2(sample_offset_world.x, sample_offset_world.y),
        sample_radius_world);
}

void SteeringSystemNative::clear_directional_cell_field(int field_id)
{
    system.clear_directional_cell_field(field_id);
}

void SteeringSystemNative::clear_directional_cell_fields()
{
    system.clear_directional_cell_fields();
}

void SteeringSystemNative::bind_phase_directional_cell_field(int phase, int field_id)
{
    system.bind_phase_directional_cell_field((ffcore::AgentPhase)phase, field_id);
}

void SteeringSystemNative::clear_phase_directional_cell_field(int phase)
{
    system.clear_phase_directional_cell_field((ffcore::AgentPhase)phase);
}

Array SteeringSystemNative::get_agents_in_map_cell(const Vector2i &cell) const
{
    Array out;
    for (const auto &[node, id] : agent_map)
    {
        const ffcore::AgentData *a = system.get_agent(id);
        if (!a || !a->flow || !a->flow->is_ready())
            continue;
        ffcore::Vec2 foot = a->position + ffcore::Vec2(0, a->profile.foot_offset_y);
        ffcore::Vec2i rel = a->flow->world_to_cell(foot);
        ffcore::Vec2i map(rel.x + a->flow->get_cell_origin().x, rel.y + a->flow->get_cell_origin().y);
        if (map.x == cell.x && map.y == cell.y)
            out.push_back(_agent_summary(a));
    }
    return out;
}

Dictionary SteeringSystemNative::get_agent_debug_snapshot(int agent_id) const
{
    Dictionary d;
    const ffcore::AgentData *a = system.get_agent(agent_id);
    if (!a)
        return d;

    const auto &cfg = ffcore::globalconfig();
    const ffcore::Vec2 foot = a->position + ffcore::Vec2(0, a->profile.foot_offset_y);
    const Vector2 velocity(a->velocity.x, a->velocity.y);
    const Vector2 nav_dir(a->debug_nav_dir.x, a->debug_nav_dir.y);
    const Vector2 desired_dir(a->debug_desired_dir.x, a->debug_desired_dir.y);
    const Vector2 target_velocity(a->debug_target_velocity.x, a->debug_target_velocity.y);
    const Vector2 wall_repel(a->debug_wall_repel.x, a->debug_wall_repel.y);
    const Vector2 separation(a->debug_separation.x, a->debug_separation.y);
    const double velocity_along_desired = velocity.dot(desired_dir);
    const double speed = velocity.length();
    const double target_speed = target_velocity.length();
    const double wall_repel_len = wall_repel.length();
    const double separation_len = separation.length();

    d["id"] = a->id;
    d["phase"] = _agent_phase_label(a);
    d["physics"] = _agent_physics_label(a);
    if (a->lost_timer > 0.0)
        d["diagnostic"] = "lost";
    else if (a->debug_bottleneck_wait)
        d["diagnostic"] = "bottleneck wait";
    else if (a->stuck_in_wall_accum > 0.0)
        d["diagnostic"] = "stuck in wall accumulating";
    else if (a->target_radius_timer > 0.0)
        d["diagnostic"] = "target wait";
    else if (a->is_propelled)
        d["diagnostic"] = "propelled";
    else if (speed <= 1.0 && target_speed > 1.0)
        d["diagnostic"] = "slow below target";
    else
        d["diagnostic"] = "normal";
    d["active"] = a->active;
    d["moving"] = a->moving;
    d["control_mode"] = static_cast<int>(a->control_mode);
    d["group"] = a->group;
    d["has_flow"] = a->flow != nullptr;
    d["flow_ready"] = a->flow ? a->flow->is_ready() : false;
    d["path_active"] = a->path_active;
    d["path_arrived"] = a->path_arrived;
    d["path_index"] = a->path_index;
    d["path_count"] = static_cast<int>(a->path_waypoints.size());
    d["position"] = Vector2(a->position.x, a->position.y);
    d["foot_position"] = Vector2(foot.x, foot.y);
    d["velocity"] = velocity;
    d["speed"] = speed;
    d["max_speed"] = a->max_speed;
    d["speed_ratio"] = a->max_speed > 0.001 ? speed / a->max_speed : 0.0;
    d["nav_dir"] = nav_dir;
    d["desired_dir"] = desired_dir;
    d["target_velocity"] = target_velocity;
    d["target_speed"] = target_speed;
    d["target_speed_ratio"] = a->max_speed > 0.001 ? target_speed / a->max_speed : 0.0;
    d["velocity_along_desired"] = velocity_along_desired;
    d["velocity_along_desired_ratio"] = a->max_speed > 0.001 ? velocity_along_desired / a->max_speed : 0.0;
    d["wall_repel"] = wall_repel;
    d["wall_repel_len"] = wall_repel_len;
    d["separation"] = separation;
    d["separation_len"] = separation_len;
    d["wall_vs_sep_ratio"] = separation_len > 0.001 ? wall_repel_len / separation_len : wall_repel_len;
    d["is_propelled"] = a->is_propelled;
    d["propelled_timer"] = a->propelled_timer;
    d["smash_pending"] = a->smash_pending;
    d["smash_delay"] = a->smash_delay;
    d["smash_control_suppression"] = a->smash_control_suppression;
    d["smash_control_suppression_timer"] = a->smash_control_suppression_timer;
    d["lost_timer"] = a->lost_timer;
    d["stuck_in_wall_accum"] = a->stuck_in_wall_accum;
    d["target_radius_timer"] = a->target_radius_timer;
    d["micro_osc"] = a->micro_osc;
    d["bottleneck_wait"] = a->debug_bottleneck_wait;
    d["in_bottleneck_state"] = a->debug_in_bottleneck_state;
    d["bottleneck_core"] = a->debug_bottleneck_core;
    d["bottleneck_zone"] = a->debug_bottleneck_zone;
    d["active_bottleneck"] = a->active_bottleneck;
    d["completed_bottleneck"] = a->completed_bottleneck;
    d["config_flow_weight"] = cfg.flow_weight;
    d["config_lerp_general"] = cfg.lerp_general;
    d["config_wall_avoid_radius"] = cfg.wall_avoid_radius;
    d["config_wall_repel_strength"] = cfg.wall_repel_strength;
    d["config_bottleneck_wait_speed_ratio"] = cfg.bottleneck_wait_speed_ratio;
    d["config_wall_stuck_detect_seconds"] = cfg.wall_stuck_detect_seconds;
    d["config_wall_stuck_velocity_ratio"] = cfg.wall_stuck_velocity_ratio;
    d["config_wall_stuck_wall_vs_sep_ratio"] = cfg.wall_stuck_wall_vs_sep_ratio;

    const ffcore::DirectionalCellFieldSample directional_sample = system.directional_cell_field_sample_for_agent(*a);
    Dictionary directional_field;
    directional_field["phase_bound"] = directional_sample.phase_bound;
    directional_field["field_found"] = directional_sample.field_found;
    directional_field["exact"] = directional_sample.exact;
    directional_field["fallback"] = directional_sample.fallback;
    directional_field["field_id"] = directional_sample.field_id;
    directional_field["sample_world"] = Vector2(directional_sample.sample_world.x, directional_sample.sample_world.y);
    directional_field["sample_cell"] = Vector2i(directional_sample.sample_cell.x, directional_sample.sample_cell.y);
    directional_field["velocity"] = Vector2(directional_sample.velocity.x, directional_sample.velocity.y);
    directional_field["speed"] = Vector2(directional_sample.velocity.x, directional_sample.velocity.y).length();
    d["directional_cell_field"] = directional_field;

    if (a->flow)
    {
        const ffcore::Vec2i rel_cell = a->flow->world_to_cell(foot);
        const ffcore::Vec2i origin = a->flow->get_cell_origin();
        const ffcore::Vec2 goal = a->flow->goal_center_world();
        d["flow_cell"] = Vector2i(rel_cell.x, rel_cell.y);
        d["map_cell"] = Vector2i(rel_cell.x + origin.x, rel_cell.y + origin.y);
        d["flow_goal"] = Vector2(goal.x, goal.y);
        d["dist_to_flow_goal"] = Vector2(goal.x - foot.x, goal.y - foot.y).length();
        d["route_cost"] = a->flow->route_cost_at_cell(rel_cell);
        d["target_radius"] = a->flow->get_ff_target_radius();
        d["bottleneck_core_at_cell"] = a->flow->bottleneck_core_at_cell(rel_cell);
        d["bottleneck_zone_at_cell"] = a->flow->bottleneck_zone_at_cell(rel_cell);
    }

    return d;
}

void SteeringSystemNative::_process(double delta)
{
    auto &cfg = ffcore::globalconfig();
    if (cfg.paused)
        return;

    cfg.debug_label_time += delta;

    if (!flowfield || !grid)
        return;

    system.update_all(delta);

    for (auto &[node, id] : agent_map)
    {
        const ffcore::AgentData *a = system.get_agent(id);
        if (!a)
            continue;

        const ffcore::FlowField *flow_ptr = a->flow;

        auto it_last_flow = agent_last_flow.find(id);
        bool flow_changed = (it_last_flow == agent_last_flow.end()) || (it_last_flow->second != flow_ptr);

        auto it_last_active = agent_last_active.find(id);
        bool active_changed = (it_last_active == agent_last_active.end()) || (it_last_active->second != a->active);

        auto it_last_phase = agent_last_phase.find(id);
        bool phase_changed = (it_last_phase == agent_last_phase.end()) || (it_last_phase->second != a->phase);

        // Only reset the label cache on an actual state transition. Eating agents are
        // inactive with a nullptr flow every frame; resetting on raw !active (or on an
        // uncached nullptr flow) wiped the label cache before it could be drawn. By
        // caching active and phase too, an inactive/eating agent is a stable state and
        // its labels survive between refreshes.
        if (flow_changed || active_changed || phase_changed)
        {
            _reset_agent_cache(id);
            agent_last_flow[id] = flow_ptr; // store nullptr too
            agent_last_active[id] = a->active;
            agent_last_phase[id] = a->phase;
        }

        auto it_propelled_state = agent_propelled_states.find(id);
        bool prev_propelled = false;
        if (it_propelled_state != agent_propelled_states.end())
            prev_propelled = it_propelled_state->second;

        bool control_impaired = a->is_propelled && a->smash_control_suppression_timer > 0.0 && a->smash_control_suppression > 0.001;
        auto it_control_impaired_state = agent_control_impaired_states.find(id);
        bool prev_control_impaired = false;
        if (it_control_impaired_state != agent_control_impaired_states.end())
            prev_control_impaired = it_control_impaired_state->second;

        bool propelled_changed = it_propelled_state == agent_propelled_states.end() || prev_propelled != a->is_propelled;
        bool control_impaired_changed = it_control_impaired_state == agent_control_impaired_states.end() || prev_control_impaired != control_impaired;
        if (propelled_changed || control_impaired_changed)
        {
            _reset_agent_cache(id);
            agent_propelled_states[id] = a->is_propelled;
            agent_control_impaired_states[id] = control_impaired;
            if (agent_manager)
            {
                Dictionary payload;
                payload["is_propelled"] = a->is_propelled;
                payload["controls_impaired"] = control_impaired;
                payload["control_suppression"] = a->smash_control_suppression;
                agent_manager->send_agent_event("propelled_state_update", id, payload);
            }
        }

        node->set_global_position(Vector2(a->position.x, a->position.y));
    }

    if (cfg.effective_steering_debug_draw_enabled())
    {
        cfg.debug_redraw_accum += delta;
        if (cfg.debug_redraw_accum < cfg.debug_redraw_interval)
            return;
        cfg.debug_redraw_accum = 0.0;
        queue_redraw();
    }
}

void SteeringSystemNative::_draw()
{
    auto &cfg = ffcore::globalconfig();
    if (!cfg.effective_steering_debug_draw_enabled())
        return;

    const Color world_color(0.1, 0.85, 0.35, 0.8);
    const Color bottleneck_zone_color(0.0, 0.2, 1.0, 0.5);
    const Color bottleneck_core_color(0.0, 0.2, 1.0, 1.0);
    const Color nav_color(0.0, 0.9, 1.0, 0.95);
    const Color wall_color(1.0, 0.65, 0.0, 0.95);
    const Color sep_color(1.0, 0.0, 1.0, 0.95);
    const Color desired_color(1.0, 1.0, 1.0, 0.95);
    const Color fight_color(1.0, 0.25, 0.1, 0.8);
    const Color label_color(1.0, 1.0, 1.0, 0.95);        // physics line (white)
    const Color phase_label_color(0.45, 0.85, 1.0, 0.95); // phase line (cyan)
    const Color label_shadow_color(0.0, 0.0, 0.0, 0.8);
    const int label_font_size = 16;                       // both lines, same "big" size
    const double label_line_height = 17.0;                // vertical gap so lines never overlap
    Ref<Font> debug_font;
    if (cfg.effective_debug_show_agent_state_labels() && ThemeDB::get_singleton())
    {
        ThemeDB *theme_db = ThemeDB::get_singleton();
        debug_font = theme_db->get_fallback_font();
        if (!debug_font.is_valid())
        {
            Ref<Theme> default_theme = theme_db->get_default_theme();
            if (default_theme.is_valid())
                debug_font = default_theme->get_default_font();
        }
    }

    if (cfg.effective_debug_draw_bottleneck_zones() && !cfg.effective_debug_disable_bottlenecks())
    {
        auto *ff_native = Object::cast_to<FlowFieldNative>(flowfield);
        const ffcore::FlowField *ff = ff_native ? ff_native->get_field() : nullptr;
        if (ff)
        {
            const double tile = ff->tile_size();
            for (const ffcore::BottleneckInfo &bottleneck : ff->get_bottlenecks())
            {
                for (const ffcore::Vec2i &cell : bottleneck.zone_cells)
                {
                    ffcore::Vec2 center = ff->cell_to_world(cell);
                    Vector2 top_left = to_local(Vector2(center.x - tile * 0.5, center.y - tile * 0.5));
                    Vector2 bottom_right = to_local(Vector2(center.x + tile * 0.5, center.y + tile * 0.5));
                    Rect2 rect(top_left, bottom_right - top_left);
                    draw_rect(rect, bottleneck_zone_color, true);
                }

                ffcore::Vec2 center = ff->cell_to_world(bottleneck.cell);
                Vector2 top_left = to_local(Vector2(center.x - tile * 0.5, center.y - tile * 0.5));
                Vector2 bottom_right = to_local(Vector2(center.x + tile * 0.5, center.y + tile * 0.5));
                Rect2 rect(top_left, bottom_right - top_left);
                draw_rect(rect, bottleneck_core_color, true);
            }
        }
    }

    for (const auto &entry : agent_map)
    {
        int id = entry.second;
        const ffcore::AgentData *a = system.get_agent(id);
        if (!a)
            continue;

        if (cfg.effective_debug_draw_world_hitbox() && a->profile.world_radius > 0.0)
        {
            Vector2 world_center = to_local(Vector2(a->position.x, a->position.y + a->profile.foot_offset_y));
            const std::vector<Vector2> &circle = debug_unit_circle_points();
            for (int i = 1; i < static_cast<int>(circle.size()); ++i)
            {
                draw_line(
                    world_center + circle[i - 1] * a->profile.world_radius,
                    world_center + circle[i] * a->profile.world_radius,
                    world_color,
                    2.0);
            }

            if (a->debug_bottleneck_core >= 0 || a->debug_bottleneck_zone >= 0)
            {
                auto draw_vec = [&](const ffcore::Vec2 &v, const Color &color, double scale)
                {
                    Vector2 end = world_center + Vector2(v.x, v.y) * scale;
                    draw_line(world_center, end, color, 2.0);
                };
                draw_vec(a->debug_nav_dir, nav_color, 24.0);
                draw_vec(a->debug_wall_repel, wall_color, 0.12);
                draw_vec(a->debug_separation, sep_color, 0.02);
                draw_vec(a->debug_desired_dir, desired_color, 18.0);
            }
        }

        if (cfg.effective_debug_draw_fight_hitbox())
        {
            Vector2 fight_center = to_local(Vector2(a->position.x, a->position.y + a->profile.fight_offset_y));
            Vector2 half_size(a->profile.fight_half_w, a->profile.fight_half_h);
            Rect2 rect(fight_center - half_size, half_size * 2.0);
            draw_rect(rect, fight_color, false, 2.0);
        }

        if (cfg.effective_debug_show_agent_state_labels() && debug_font.is_valid())
        {
            // Refresh cadence: spread agents across the interval with a per-id stagger so
            // the string rebuild cost is amortized across frames, while keeping each label
            // fresh enough (default 0.2s) to stay in sync with the agent's real state.
            const double refresh = std::max(0.0, cfg.debug_label_refresh_interval);
            const double stagger = refresh * (double((id * 37) % 100) * 0.01);

            auto next_label_it = debug_agent_label_next_refresh.find(id);
            if (next_label_it == debug_agent_label_next_refresh.end())
                debug_agent_label_next_refresh[id] = cfg.debug_label_time + stagger;

            if (cfg.debug_label_time >= debug_agent_label_next_refresh[id])
            {
                DebugAgentLabels &slot = debug_agent_label_cache[id];
                slot.physics = _agent_physics_label(a);
                slot.phase = _agent_phase_label(a);
                debug_agent_label_next_refresh[id] = cfg.debug_label_time + refresh + stagger;
            }

            auto label_it = debug_agent_label_cache.find(id);
            if (label_it == debug_agent_label_cache.end())
                continue;

            const DebugAgentLabels &labels = label_it->second;
            // Anchor above the fight box; phase line on top, physics line below it.
            Vector2 base_pos = to_local(Vector2(a->position.x - a->profile.fight_half_w, a->position.y + a->profile.fight_offset_y - a->profile.fight_half_h - 8.0));

            // Phase line (top). Skipped only when the agent has no active phase.
            if (!labels.phase.is_empty())
            {
                Vector2 phase_pos = base_pos - Vector2(0.0, label_line_height);
                draw_string(debug_font, phase_pos + Vector2(1.0, 1.0), labels.phase, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_font_size, label_shadow_color);
                draw_string(debug_font, phase_pos, labels.phase, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_font_size, phase_label_color);
            }

            // Physics line (bottom). Always present.
            draw_string(debug_font, base_pos + Vector2(1.0, 1.0), labels.physics, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_font_size, label_shadow_color);
            draw_string(debug_font, base_pos, labels.physics, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_font_size, label_color);
        }
    }
}

int SteeringSystemNative::get_agent_id(Node2D *node)
{
    auto it = agent_map.find(node);
    if (it == agent_map.end())
        return -1;
    return it->second;
}
