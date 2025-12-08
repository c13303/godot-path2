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
    ClassDB::bind_method(D_METHOD("get_agents_in_map_cell", "cell"), &SteeringSystemNative::get_agents_in_map_cell);
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

void SteeringSystemNative::_reset_agent_cache(int agent_id)
{
    agent_direction_codes.erase(agent_id);
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

        bool moving;
        int code;
        ffcore::Vec2 vel;
        if (system.consume_anim_state(id, moving, code, vel))
        {
            Vector2 vel_vec(vel.x, vel.y);
            if (agent_manager)
            {
                Dictionary payload;
                payload["moving"] = moving;
                payload["code"] = code;
                payload["direction"] = (moving && vel_vec.length_squared() > 1e-6) ? vel_vec.normalized() : vel_vec;
                agent_manager->send_agent_event("direction", id, payload);
            }
            agent_direction_codes[id] = code;
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
