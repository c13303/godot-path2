#include "steering_system_native.h"
#include "flow_field_native.h"
#include "spatial_grid_native.h"
#include <godot_cpp/variant/utility_functions.hpp>


using namespace godot;

void SteeringSystemNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("register_agent", "agent", "max_speed"), &SteeringSystemNative::register_agent);
    ClassDB::bind_method(D_METHOD("unregister_agent", "agent"), &SteeringSystemNative::unregister_agent);
    ClassDB::bind_method(D_METHOD("set_flowfield", "flowfield"), &SteeringSystemNative::set_flowfield);
    ClassDB::bind_method(D_METHOD("set_grid", "grid"), &SteeringSystemNative::set_grid);
}

SteeringSystemNative::SteeringSystemNative() {}
SteeringSystemNative::~SteeringSystemNative() {}

void SteeringSystemNative::_ready()
{
    Node *parent = get_parent();
    if (!parent)
    {
        UtilityFunctions::print("SteeringSystemNative: no parent");
        return;
    }

    flowfield = Object::cast_to<Node2D>(parent->get_node_or_null("FlowFieldNative"));
    grid = Object::cast_to<Node2D>(parent->get_node_or_null("SpatialGridNative"));

    if (flowfield && grid)
    {
        UtilityFunctions::print("SteeringSystemNative: linked FlowField + Grid");

        // Connexion native
        auto *ff_native = Object::cast_to<FlowFieldNative>(flowfield);
        auto *grid_native = Object::cast_to<SpatialGridNative>(grid);
        if (ff_native && grid_native)
        {
            system.set_flowfield(ff_native->get_field());
            system.set_grid(grid_native->get_grid());
            UtilityFunctions::print("SteeringSystemNative: native system connected.");
        }
        else
        {
            UtilityFunctions::print("SteeringSystemNative: cast failed, check node types.");
        }
    }
    else
    {
        UtilityFunctions::print("SteeringSystemNative: waiting for flowfield/grid...");
    }
}

void SteeringSystemNative::set_flowfield(Object *obj)
{
    flowfield = Object::cast_to<Node2D>(obj);
}

void SteeringSystemNative::set_grid(Object *obj)
{
    grid = Object::cast_to<Node2D>(obj);
}

void SteeringSystemNative::register_agent(Node2D *node, double max_speed)
{
    if (!node)
        return;
    int id = system.register_agent(ffcore::Vec2(node->get_global_position().x, node->get_global_position().y), max_speed);
    agent_map[node] = id;
}

void SteeringSystemNative::unregister_agent(Node2D *node)
{
    if (!node)
        return;
    auto it = agent_map.find(node);
    if (it == agent_map.end())
        return;
    system.unregister_agent(it->second);
    agent_map.erase(it);
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
        node->set_global_position(Vector2(a->position.x, a->position.y));
    }
}
