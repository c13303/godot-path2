#include "agent_manager_native.h"
#include "../core/types.h"
#include "../flow/flow_field.h"
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include "../agent_manager/agent_manager.h"
#include <cstdlib>
#include "../godot/steering_system_native.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void AgentManagerNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("create_group"), &AgentManagerNative::create_group);
    ClassDB::bind_method(D_METHOD("spawn_agent", "node", "group_id"), &AgentManagerNative::spawn_agent);

    ClassDB::bind_method(D_METHOD("get_group_flow", "group"), &AgentManagerNative::get_group_flow);
    ClassDB::bind_method(D_METHOD("assign_agent", "agent", "group"), &AgentManagerNative::assign_agent);
}
void AgentManagerNative::_ready()
{
    core_mgr = ffcore::get_global_agent_manager();
    steering = ffcore::get_global_steering_system();

    Node *parent = get_parent();
    if (parent)
    {
        steering_native = Object::cast_to<SteeringSystemNative>(
            parent->get_node_or_null("SteeringSystemNative"));
    }

    if (!steering_native)
    {
        UtilityFunctions::print("⚠️ AgentManagerNative: SteeringSystemNative introuvable");
    }
}

AgentManagerNative::~AgentManagerNative() {}

AgentManagerNative::AgentManagerNative() : next_id(1)
{
}

int AgentManagerNative::create_group()
{
    return core_mgr ? core_mgr->create_group() : -1;
}

int AgentManagerNative::get_group_flow(int group) const
{
    return core_mgr ? core_mgr->get_group_flow(group) : -1;
}

ffcore::AgentManager *AgentManagerNative::get_internal()
{
    return core_mgr;
}

void AgentManagerNative::assign_agent(Node2D *agent, int group)
{
    if (!agent || !core_mgr)
        return;

    Vector2 p = agent->get_global_position();
    ffcore::Vec2 pos(p.x, p.y);

    int64_t nav_id = agent->get("nav_id").operator int64_t();
    core_mgr->add_agent_to_group(nav_id, group);
}

int AgentManagerNative::spawn_agent(Node2D *node, int group_id)
{
    /*  godot::UtilityFunctions::print("spawn_agent()"); */

    if (group_id <= 0)
    {
        godot::UtilityFunctions::printerr("spawn_agent : group_id invalide");
        std::abort();
    }

    if (!core_mgr || !steering)
    {
        godot::UtilityFunctions::printerr(
            "AgentManagerNative.spawn_agent : core_mgr ou steering non initialisé. Arrêt immédiat.");

        std::abort();
    }

    ffcore::Vec2 pos(node->get_global_position().x, node->get_global_position().y);

    int nav_id = next_id++;
    core_mgr->create_agent_entry(nav_id, pos, group_id);
    core_mgr->add_agent_to_group(nav_id, group_id);

    if (core_mgr->get(nav_id) == nullptr)
    {
        godot::UtilityFunctions::print("CRITICAL: AgentManager n’a pas enregistré l’agent ", nav_id);
        std::abort();
    }

    double max_speed = 200.0; // Ou récupérer depuis le node
    steering->register_agent_with_id(nav_id, pos, max_speed, nullptr);

    if (auto *steering_native = get_node<SteeringSystemNative>(
            NodePath("/root/Node2D/SteeringSystemNative")))
    {
        steering_native->register_node_mapping(node, nav_id);
    }

    /*     godot::UtilityFunctions::print(
            "Agent créé : ID=", nav_id,
            " steering=", steering_id,
            " group=", group_id); */

    return nav_id;
}
