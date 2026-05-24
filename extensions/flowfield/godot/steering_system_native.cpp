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

using namespace godot;

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
    ClassDB::bind_method(D_METHOD("apply_smash_impulse", "agent_id", "direction", "force", "friction_loss", "delay", "detach_flow", "control_suppression", "control_suppression_duration"), &SteeringSystemNative::apply_smash_impulse);
    ClassDB::bind_method(D_METHOD("apply_area_smash", "position", "radius", "direction", "force", "friction_loss", "falloff", "detach_flow", "control_suppression", "control_suppression_duration", "ignored_agent_id", "affected_smash_classes"), &SteeringSystemNative::apply_area_smash);
    ClassDB::bind_method(D_METHOD("apply_cone_smash", "position", "radius", "direction", "angle_degrees", "force", "friction_loss", "falloff", "detach_flow", "control_suppression", "control_suppression_duration", "ignored_agent_id", "affected_smash_classes"), &SteeringSystemNative::apply_cone_smash);
    ClassDB::bind_method(D_METHOD("apply_explosion", "position", "radius", "intensity", "friction_loss"), &SteeringSystemNative::apply_explosion);
    ClassDB::bind_method(D_METHOD("apply_explosion_filtered", "position", "radius", "intensity", "friction_loss", "falloff", "ignored_agent_id", "control_suppression", "control_suppression_duration", "affected_smash_classes"), &SteeringSystemNative::apply_explosion_filtered);
    ClassDB::bind_method(D_METHOD("spawn_aoe_zone", "position", "direction", "radius", "angle_degrees", "duration", "force", "friction_loss", "falloff", "detach_flow", "control_suppression", "control_suppression_duration", "ignored_agent_id", "affected_smash_classes"), &SteeringSystemNative::spawn_aoe_zone);
    ClassDB::bind_method(D_METHOD("get_agents_in_map_cell", "cell"), &SteeringSystemNative::get_agents_in_map_cell);
    ClassDB::bind_method(D_METHOD("set_paused", "paused"), &SteeringSystemNative::set_paused);
    ClassDB::bind_method(D_METHOD("set_debug_draw_world_hitbox", "enabled"), &SteeringSystemNative::set_debug_draw_world_hitbox);
    ClassDB::bind_method(D_METHOD("get_debug_draw_world_hitbox"), &SteeringSystemNative::get_debug_draw_world_hitbox);
    ClassDB::bind_method(D_METHOD("set_debug_draw_fight_hitbox", "enabled"), &SteeringSystemNative::set_debug_draw_fight_hitbox);
    ClassDB::bind_method(D_METHOD("get_debug_draw_fight_hitbox"), &SteeringSystemNative::get_debug_draw_fight_hitbox);
    ClassDB::bind_method(D_METHOD("set_debug_show_agent_state_labels", "enabled"), &SteeringSystemNative::set_debug_show_agent_state_labels);
    ClassDB::bind_method(D_METHOD("get_debug_show_agent_state_labels"), &SteeringSystemNative::get_debug_show_agent_state_labels);

    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_world_hitbox"), "set_debug_draw_world_hitbox", "get_debug_draw_world_hitbox");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_fight_hitbox"), "set_debug_draw_fight_hitbox", "get_debug_draw_fight_hitbox");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_show_agent_state_labels"), "set_debug_show_agent_state_labels", "get_debug_show_agent_state_labels");
}

SteeringSystemNative::SteeringSystemNative() {}
SteeringSystemNative::~SteeringSystemNative() {}

void SteeringSystemNative::_ready()
{
    if (Engine::get_singleton()->is_editor_hint())
        return;

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

void SteeringSystemNative::set_grid(Object *obj)
{
    grid = Object::cast_to<Node2D>(obj);
}

void SteeringSystemNative::set_debug_draw_world_hitbox(bool enabled)
{
    debug_draw_world_hitbox = enabled;
    queue_redraw();
}

void SteeringSystemNative::set_debug_draw_fight_hitbox(bool enabled)
{
    debug_draw_fight_hitbox = enabled;
    queue_redraw();
}

void SteeringSystemNative::set_debug_show_agent_state_labels(bool enabled)
{
    debug_show_agent_state_labels = enabled;
    queue_redraw();
}

void SteeringSystemNative::apply_explosion(const Vector2 &position, double radius, double intensity, double friction_loss)
{
    system.apply_explosion(ffcore::Vec2(position.x, position.y), radius, intensity, friction_loss);
}

void SteeringSystemNative::apply_explosion_filtered(const Vector2 &position, double radius, double intensity, double friction_loss, double falloff, int ignored_agent_id, double control_suppression, double control_suppression_duration, int affected_smash_classes)
{
    system.apply_explosion_filtered(ffcore::Vec2(position.x, position.y), radius, intensity, friction_loss, falloff, ignored_agent_id, control_suppression, control_suppression_duration, affected_smash_classes);
}

void SteeringSystemNative::spawn_aoe_zone(const Vector2 &position, const Vector2 &direction, double radius, double angle_degrees, double duration, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes)
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
        affected_smash_classes);
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

void SteeringSystemNative::_reset_agent_cache(int agent_id)
{
    agent_last_flow.erase(agent_id);
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

String SteeringSystemNative::_agent_debug_state_label(const ffcore::AgentData *a) const
{
    if (!a)
        return "missing";

    Vector2 vel(a->velocity.x, a->velocity.y);
    double velocity_len = vel.length();

    if (a->smash_pending)
        return "smash pending";
    if (a->is_propelled)
        return "propelled v=" + String::num_real(velocity_len) + " t=" + String::num_real(a->propelled_timer);
    if (a->control_mode == ffcore::AgentControlMode::Manual)
        return velocity_len > 1.0 ? "manual moving" : "manual idle";
    if (!a->active)
        return a->flow ? "inactive" : "inactive / no flow";
    if (!a->flow)
        return "no flow";
    if (!a->flow->is_ready())
        return "flow not ready";
    if (a->target_radius_timer > 0.0)
        return "target wait " + String::num_real(a->target_radius_timer);
    if (a->micro_osc > 0)
        return "following flow osc=" + String::num_int64(a->micro_osc);
    if (velocity_len <= 1.0)
        return "following flow idle";

    return "following flow";
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

void SteeringSystemNative::_process(double delta)
{
    if (paused)
        return;

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
        if (flow_changed || !a->active)
        {
            _reset_agent_cache(id);
            if (flow_ptr)
                agent_last_flow[id] = flow_ptr;
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

    if (debug_draw_world_hitbox || debug_draw_fight_hitbox || debug_show_agent_state_labels)
        queue_redraw();
}

void SteeringSystemNative::_draw()
{
    if (!debug_draw_world_hitbox && !debug_draw_fight_hitbox && !debug_show_agent_state_labels)
        return;

    const Color world_color(0.1, 0.85, 0.35, 0.8);
    const Color fight_color(1.0, 0.25, 0.1, 0.8);
    const Color label_color(1.0, 1.0, 1.0, 0.95);
    const Color label_shadow_color(0.0, 0.0, 0.0, 0.8);
    Ref<Font> debug_font;
    if (debug_show_agent_state_labels && ThemeDB::get_singleton())
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

    for (const auto &entry : agent_map)
    {
        int id = entry.second;
        const ffcore::AgentData *a = system.get_agent(id);
        if (!a)
            continue;

        if (debug_draw_world_hitbox && a->profile.world_radius > 0.0)
        {
            Vector2 world_center = to_local(Vector2(a->position.x, a->position.y + a->profile.foot_offset_y));
            draw_arc(world_center, a->profile.world_radius, 0.0, 6.28318530717958647692, 48, world_color, 2.0, true);
        }

        if (debug_draw_fight_hitbox)
        {
            Vector2 fight_center = to_local(Vector2(a->position.x, a->position.y + a->profile.fight_offset_y));
            Vector2 half_size(a->profile.fight_half_w, a->profile.fight_half_h);
            Rect2 rect(fight_center - half_size, half_size * 2.0);
            draw_rect(rect, fight_color, false, 2.0);
        }

        if (debug_show_agent_state_labels && debug_font.is_valid())
        {
            String label = _agent_debug_state_label(a);
            Vector2 label_pos = to_local(Vector2(a->position.x - a->profile.fight_half_w, a->position.y + a->profile.fight_offset_y - a->profile.fight_half_h - 8.0));
            draw_string(debug_font, label_pos + Vector2(1.0, 1.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, label_shadow_color);
            draw_string(debug_font, label_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, label_color);
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
