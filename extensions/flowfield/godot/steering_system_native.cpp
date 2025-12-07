#include "steering_system_native.h"
#include "flow_field_native.h"
#include "spatial_grid_native.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include "../agent_manager/agent_manager.h"
#include <godot_cpp/classes/engine.hpp>
#include "agent_manager_native.h"
#include <godot_cpp/variant/dictionary.hpp>
#include "../flow/flow_field.h"

using namespace godot;

void SteeringSystemNative::_bind_methods()
{

    ClassDB::bind_method(D_METHOD("set_flowfield", "flowfield"), &SteeringSystemNative::set_flowfield);
    ClassDB::bind_method(D_METHOD("set_grid", "grid"), &SteeringSystemNative::set_grid);
    ClassDB::bind_method(D_METHOD("get_agent_id", "agent"), &SteeringSystemNative::get_agent_id);
    ClassDB::bind_method(D_METHOD("register_node_mapping", "node", "agent_id"), &SteeringSystemNative::register_node_mapping);
    ClassDB::bind_method(D_METHOD("apply_explosion", "position", "radius", "intensity", "friction_loss"), &SteeringSystemNative::apply_explosion);
    ADD_SIGNAL(MethodInfo("agent_propelled_state_changed",
        PropertyInfo(Variant::INT, "agent_id"),
        PropertyInfo(Variant::BOOL, "propelled")));
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

void SteeringSystemNative::maybe_emit_direction_changed(int agent_id, int code, const Vector2 &flow_dir)
{
    if (!agent_manager)
        return;

    auto it = agent_direction_codes.find(agent_id);
    int last = (it != agent_direction_codes.end()) ? it->second : -2;
    if (last == code)
        return;

    agent_direction_codes[agent_id] = code;

    Dictionary payload;
    payload["direction"] = flow_dir;
    payload["code"] = code;
    agent_manager->send_agent_event("direction", agent_id, payload);
}

void SteeringSystemNative::maybe_emit_arrived(int agent_id, bool arrived)
{
    if (!agent_manager)
        return;

    auto it = agent_arrived_states.find(agent_id);
    bool last = (it != agent_arrived_states.end()) ? it->second : false;
    if (last == arrived)
        return;

    agent_arrived_states[agent_id] = arrived;
    Dictionary payload;
    payload["arrived"] = arrived;
    int last_code = -1;
    auto it_dir = agent_direction_codes.find(agent_id);
    if (it_dir != agent_direction_codes.end())
        last_code = it_dir->second;
    payload["last_code"] = last_code;
    agent_manager->send_agent_event("arrived", agent_id, payload);
}

void SteeringSystemNative::_process(double delta)
{
    if (!flowfield || !grid)
        return;

    // Back-pressure: cap direction event emissions per frame to avoid flooding GDScript.
    const int max_dir_events_per_frame = 512;
    int dir_events_this_frame = 0;

    system.update_all(delta);

    for (auto &[node, id] : agent_map)
    {
        const ffcore::AgentData *a = system.get_agent(id);
        if (!a)
            continue;
        maybe_emit_propelled_state(id, a->is_propelled);
        bool needs_direction = (agent_direction_codes.find(id) == agent_direction_codes.end());
        Vector2 flow_vec;
        if (a->flow && a->flow->is_ready())
        {
            ffcore::Vec2 world_pos(a->position.x, a->position.y);
            ffcore::Vec2i cell = a->flow->world_to_cell(world_pos);

            auto it_cell = agent_last_cells.find(id);
            if (it_cell == agent_last_cells.end() || it_cell->second != Vector2i(cell.x, cell.y))
            {
                agent_last_cells[id] = Vector2i(cell.x, cell.y);
                ffcore::Vec2 fd = a->flow->dir(cell.x, cell.y);
                flow_vec = Vector2(fd.x, fd.y);
                needs_direction = true;
            }
        }
        else
        {
            // Flow missing/unready: drop caches; do not emit.
            agent_direction_codes.erase(id);
            agent_last_cells.erase(id);
            needs_direction = false;
        }
        // Emit only on state change with a non-zero flow vector.
        if (needs_direction && flow_vec.length_squared() > 1e-6)
        {
            int code = _direction_code(flow_vec);
            if (code >= 0 && dir_events_this_frame < max_dir_events_per_frame)
            {
                maybe_emit_direction_changed(id, code, flow_vec);
                dir_events_this_frame++;
            }
        }
        maybe_emit_arrived(id, a->has_arrived);
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
