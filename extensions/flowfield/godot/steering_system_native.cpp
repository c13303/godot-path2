#include "steering_system_native.h"
#include "flow_field_native.h"
#include "spatial_grid_native.h"
#include <godot_cpp/variant/utility_functions.hpp>
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
    ClassDB::bind_method(D_METHOD("apply_explosion", "position", "radius", "intensity", "friction_loss"), &SteeringSystemNative::apply_explosion);
    ClassDB::bind_method(D_METHOD("get_arrival_goal_radius"), &SteeringSystemNative::get_arrival_goal_radius);
    ClassDB::bind_method(D_METHOD("set_arrival_goal_radius", "value"), &SteeringSystemNative::set_arrival_goal_radius);
    ClassDB::bind_method(D_METHOD("get_arrival_hysteresis_margin"), &SteeringSystemNative::get_arrival_hysteresis_margin);
    ClassDB::bind_method(D_METHOD("set_arrival_hysteresis_margin", "value"), &SteeringSystemNative::set_arrival_hysteresis_margin);
    ClassDB::bind_method(D_METHOD("get_arrival_velocity_threshold"), &SteeringSystemNative::get_arrival_velocity_threshold);
    ClassDB::bind_method(D_METHOD("set_arrival_velocity_threshold", "value"), &SteeringSystemNative::set_arrival_velocity_threshold);
    ClassDB::bind_method(D_METHOD("get_arrival_time_requirement"), &SteeringSystemNative::get_arrival_time_requirement);
    ClassDB::bind_method(D_METHOD("set_arrival_time_requirement", "value"), &SteeringSystemNative::set_arrival_time_requirement);
    ClassDB::bind_method(D_METHOD("get_arrival_enable_signals"), &SteeringSystemNative::get_arrival_enable_signals);
    ClassDB::bind_method(D_METHOD("set_arrival_enable_signals", "value"), &SteeringSystemNative::set_arrival_enable_signals);
    ClassDB::bind_method(D_METHOD("get_arrival_signals_per_frame_cap"), &SteeringSystemNative::get_arrival_signals_per_frame_cap);
    ClassDB::bind_method(D_METHOD("set_arrival_signals_per_frame_cap", "value"), &SteeringSystemNative::set_arrival_signals_per_frame_cap);
    ClassDB::bind_method(D_METHOD("get_arrival_debug_logs"), &SteeringSystemNative::get_arrival_debug_logs);
    ClassDB::bind_method(D_METHOD("set_arrival_debug_logs", "value"), &SteeringSystemNative::set_arrival_debug_logs);
    ClassDB::bind_method(D_METHOD("get_agent_arrival_metrics", "agent_id"), &SteeringSystemNative::get_agent_arrival_metrics);
    ClassDB::bind_method(D_METHOD("get_agents_in_map_cell", "cell"), &SteeringSystemNative::get_agents_in_map_cell);
    ADD_SIGNAL(MethodInfo("agent_propelled_state_changed",
                          PropertyInfo(Variant::INT, "agent_id"),
                          PropertyInfo(Variant::BOOL, "propelled")));
    ADD_SIGNAL(MethodInfo("agent_arrival_state_changed",
                          PropertyInfo(Variant::INT, "agent_id"),
                          PropertyInfo(Variant::BOOL, "arrived"),
                          PropertyInfo(Variant::DICTIONARY, "metrics")));
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

void SteeringSystemNative::apply_explosion(const Vector2 &position, double radius, double intensity, double friction_loss)
{
    system.apply_explosion(ffcore::Vec2(position.x, position.y), radius, intensity, friction_loss);
}

void SteeringSystemNative::_reset_agent_cache(int agent_id, bool preserve_arrival)
{
    agent_direction_codes.erase(agent_id);
    agent_last_cells.erase(agent_id);
    if (!preserve_arrival)
    {
        agent_arrived_states.erase(agent_id);
        arrival_states.erase(agent_id);
    }
    agent_last_flow.erase(agent_id);
}

void SteeringSystemNative::maybe_emit_propelled_state(int agent_id, bool propelled)
{
    auto it = agent_propelled_states.find(agent_id);
    bool last = (it != agent_propelled_states.end()) ? it->second : false;
    if (last == propelled)
        return;
    agent_propelled_states[agent_id] = propelled;
    emit_signal("agent_propelled_state_changed", agent_id, propelled);
}

int SteeringSystemNative::_direction_code(const Vector2 &v) const
{
    if (v.length_squared() < 1e-6)
        return -1;
    if (Math::abs(v.x) >= Math::abs(v.y))
        return v.x >= 0.0 ? 0 : 1; // E or W
    return v.y >= 0.0 ? 2 : 3;     // S or N
}

void SteeringSystemNative::maybe_emit_direction_changed(int agent_id, int code, const Vector2 &flow_dir, bool force)
{
    if (!agent_manager)
        return;

    auto it = agent_direction_codes.find(agent_id);
    int last = (it != agent_direction_codes.end()) ? it->second : -2;
    if (!force && last == code)
        return;

    agent_direction_codes[agent_id] = code;

    Dictionary payload;
    payload["direction"] = flow_dir;
    payload["code"] = code;
    payload["moving"] = true;
    agent_manager->send_agent_event("direction", agent_id, payload);
}

Vector2 SteeringSystemNative::_goal_position_for_agent(const ffcore::AgentData *a) const
{
    if (!a)
        return Vector2();
    if (a->claimed_tile.x > -100000 && a->claimed_tile.y > -100000 && a->flow)
    {
        ffcore::Vec2i rel(a->claimed_tile.x - a->flow->get_cell_origin().x,
                          a->claimed_tile.y - a->flow->get_cell_origin().y);
        ffcore::Vec2 g = a->flow->cell_to_world(rel);
        return Vector2(g.x, g.y);
    }
    if (a->flow)
    {
        ffcore::Vec2 g = a->flow->goal_center_world();
        return Vector2(g.x, g.y);
    }
    return Vector2();
}

void SteeringSystemNative::_update_arrival_state(int agent_id, const ffcore::AgentData *a, double delta)
{
    if (a && a->reached_claim_tile)
    {
        ArrivalState &st = arrival_states[agent_id];
        st.goal_position = _goal_position_for_agent(a);
        st.distance_to_goal = 0.0;
        st.velocity_magnitude = 0.0;
        st.is_near_goal = true;
        st.is_stopped = true;
        st.time_at_goal = arrival_time_requirement;
        st.has_arrived = true;
        st.arrived_last_frame = true;
        return;
    }

    if (!a || !a->flow || !a->flow->is_ready())
    {
        arrival_states.erase(agent_id);
        return;
    }

    ArrivalState &st = arrival_states[agent_id];
    st.goal_position = _goal_position_for_agent(a);

    Vector2 pos(a->position.x, a->position.y);
    st.distance_to_goal = pos.distance_to(st.goal_position);
    st.velocity_magnitude = Vector2(a->velocity.x, a->velocity.y).length();

    double effective_radius = arrival_goal_radius;
    if (st.has_arrived)
        effective_radius += arrival_hysteresis_margin;

    st.is_near_goal = st.distance_to_goal <= effective_radius;
    st.is_stopped = st.velocity_magnitude <= arrival_velocity_threshold;

    if (st.is_near_goal)
        st.time_at_goal += delta;
    else
        st.time_at_goal = 0.0;

    // Allow arrival if near goal and either stopped or has lingered long enough.
    bool new_arrived = st.is_near_goal && ((st.is_stopped && st.time_at_goal >= arrival_time_requirement) ||
                                           (st.time_at_goal >= arrival_time_requirement));
    st.has_arrived = new_arrived;
}

bool SteeringSystemNative::_maybe_emit_arrival_changed(int agent_id, int &emitted_count)
{
    auto it = arrival_states.find(agent_id);
    if (it == arrival_states.end())
        return false;
    bool current = it->second.has_arrived;
    bool last = it->second.arrived_last_frame;
    if (last == current)
        return false;
    it->second.arrived_last_frame = current;

    if (arrival_debug_logs)
    {
        // kept for optional debug logging
    }

    if (arrival_enable_signals && emitted_count < arrival_signals_per_frame_cap)
    {
        if (agent_manager)
        {
            Dictionary payload;
            payload["arrived"] = current;
            payload["distance"] = it->second.distance_to_goal;
            payload["velocity"] = it->second.velocity_magnitude;
            payload["time_at_goal"] = it->second.time_at_goal;
            payload["near_goal"] = it->second.is_near_goal;
            payload["stopped"] = it->second.is_stopped;
            int last_code = -1;
            auto it_dir = agent_direction_codes.find(agent_id);
            if (it_dir != agent_direction_codes.end())
                last_code = it_dir->second;
            payload["last_code"] = last_code;
            agent_manager->send_agent_event("arrived", agent_id, payload);
        }
        emit_signal("agent_arrival_state_changed", agent_id, current, get_agent_arrival_metrics(agent_id));
        emitted_count++;
    }
    return true;
}

// Arrival metrics getters
double SteeringSystemNative::get_arrival_goal_radius() const { return arrival_goal_radius; }
void SteeringSystemNative::set_arrival_goal_radius(double v) { arrival_goal_radius = std::max(0.0, v); }
double SteeringSystemNative::get_arrival_hysteresis_margin() const { return arrival_hysteresis_margin; }
void SteeringSystemNative::set_arrival_hysteresis_margin(double v) { arrival_hysteresis_margin = std::max(0.0, v); }
double SteeringSystemNative::get_arrival_velocity_threshold() const { return arrival_velocity_threshold; }
void SteeringSystemNative::set_arrival_velocity_threshold(double v) { arrival_velocity_threshold = std::max(0.0, v); }
double SteeringSystemNative::get_arrival_time_requirement() const { return arrival_time_requirement; }
void SteeringSystemNative::set_arrival_time_requirement(double v) { arrival_time_requirement = std::max(0.0, v); }
bool SteeringSystemNative::get_arrival_enable_signals() const { return arrival_enable_signals; }
void SteeringSystemNative::set_arrival_enable_signals(bool v) { arrival_enable_signals = v; }
int SteeringSystemNative::get_arrival_signals_per_frame_cap() const { return arrival_signals_per_frame_cap; }
void SteeringSystemNative::set_arrival_signals_per_frame_cap(int v) { arrival_signals_per_frame_cap = std::max(0, v); }
bool SteeringSystemNative::get_arrival_debug_logs() const { return arrival_debug_logs; }
void SteeringSystemNative::set_arrival_debug_logs(bool v) { arrival_debug_logs = v; }

Dictionary SteeringSystemNative::get_agent_arrival_metrics(int agent_id) const
{
    Dictionary d;
    auto it = arrival_states.find(agent_id);
    if (it == arrival_states.end())
        return d;
    const ArrivalState &s = it->second;
    d["distance"] = s.distance_to_goal;
    d["velocity"] = s.velocity_magnitude;
    d["near_goal"] = s.is_near_goal;
    d["stopped"] = s.is_stopped;
    d["time_at_goal"] = s.time_at_goal;
    d["arrived"] = s.has_arrived;
    d["goal"] = s.goal_position;
    return d;
}

Dictionary SteeringSystemNative::_agent_summary(const ffcore::AgentData *a) const
{
    Dictionary d;
    if (!a)
        return d;
    Vector2 vel(a->velocity.x, a->velocity.y);
    double thresh = ffcore::globalconfig().velocity_min_trig_walk_animation;
    double thresh2 = thresh * thresh;
    bool moving = vel.length_squared() > thresh2;
    d["id"] = a->id;
    d["is_moving"] = moving;
    d["velocity"] = vel;
    d["velocity_len"] = vel.length();
    int code = _direction_code(vel);
    d["dir_code"] = code;
    ffcore::Vec2 pos = a->position + ffcore::Vec2(0, ffcore::globalconfig().agent_offset_y);
    d["world_pos"] = Vector2(pos.x, pos.y);
    return d;
}

Array SteeringSystemNative::get_agents_in_map_cell(const Vector2i &cell) const
{
    Array out;
    double offset_y = ffcore::globalconfig().agent_offset_y;
    for (const auto &[node, id] : agent_map)
    {
        const ffcore::AgentData *a = system.get_agent(id);
        if (!a || !a->flow || !a->flow->is_ready())
            continue;
        ffcore::Vec2 foot = a->position + ffcore::Vec2(0, offset_y);
        ffcore::Vec2i rel = a->flow->world_to_cell(foot);
        ffcore::Vec2i map(rel.x + a->flow->get_cell_origin().x, rel.y + a->flow->get_cell_origin().y);
        if (map.x == cell.x && map.y == cell.y)
            out.push_back(_agent_summary(a));
    }
    return out;
}

void SteeringSystemNative::_process(double delta)
{
    if (!flowfield || !grid)
        return;

    arrival_debug_frame++;

    int arrival_events_this_frame = 0;

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
            bool preserve_arrival = (!flow_changed && !a->active);
            _reset_agent_cache(id, preserve_arrival);
            if (flow_ptr)
                agent_last_flow[id] = flow_ptr;
        }

        maybe_emit_propelled_state(id, a->is_propelled);
        bool moving;
        int code;
        ffcore::Vec2 vel;
        if (system.consume_anim_state(id, moving, code, vel))
        {
            Vector2 vel_vec(vel.x, vel.y);
            if (moving && code >= 0)
            {
                maybe_emit_direction_changed(id, code, vel_vec.normalized(), true);
            }
            else
            {
                if (code < 0 && agent_direction_codes.count(id))
                    code = agent_direction_codes[id];
                if (agent_manager)
                {
                    Dictionary payload;
                    payload["moving"] = moving;
                    payload["code"] = code;
                    payload["direction"] = vel_vec;
                    agent_manager->send_agent_event("direction", id, payload);
                }
                agent_direction_codes[id] = code;
            }
        }

        _update_arrival_state(id, a, delta);
        _maybe_emit_arrival_changed(id, arrival_events_this_frame);

        if (arrival_debug_logs && arrival_debug_frame % 30 == 0)
        {
            static int debug_printed = 0;
            if (debug_printed < 5 && arrival_states.find(id) != arrival_states.end())
            {
                const ArrivalState &st = arrival_states[id];
                UtilityFunctions::print("Arrival dbg frame=", arrival_debug_frame,
                                        " agent=", id,
                                        " dist=", st.distance_to_goal,
                                        " vel=", st.velocity_magnitude,
                                        " near=", st.is_near_goal,
                                        " stopped=", st.is_stopped,
                                        " t=", st.time_at_goal,
                                        " arrived=", st.has_arrived,
                                        " goal=", st.goal_position);
                debug_printed++;
            }
        }
        node->set_global_position(Vector2(a->position.x, a->position.y));
    }
}

int SteeringSystemNative::get_agent_id(Node2D *node)
{
    auto it = agent_map.find(node);
    if (it == agent_map.end())
        return -1;
    return it->second;
}
