#include "agent_manager_native.h"
#include "../core/types.h"
#include "../core/nav_config.h"
#include "../flow/flow_field.h"
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include "../agent_manager/agent_manager.h"
#include <cstdlib>
#include "../godot/steering_system_native.h"
#include <godot_cpp/classes/engine.hpp>

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/object.hpp>

using namespace godot;

void AgentManagerNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("create_group"), &AgentManagerNative::create_group);
    ClassDB::bind_method(D_METHOD("spawn_agent", "node", "group_id"), &AgentManagerNative::spawn_agent);
    ClassDB::bind_method(D_METHOD("assign_agent", "agent", "group"), &AgentManagerNative::assign_agent);
    ClassDB::bind_method(D_METHOD("set_current_selected_group", "group_id"), &AgentManagerNative::set_current_selected_group);
    ClassDB::bind_method(D_METHOD("cleanup_groups"), &AgentManagerNative::cleanup_groups);
    ClassDB::bind_method(D_METHOD("mark_group_has_order", "group_id"), &AgentManagerNative::mark_group_has_order);
}

void AgentManagerNative::_ready()
{
    if (Engine::get_singleton()->is_editor_hint())
        return;

    core_mgr = ffcore::get_global_agent_manager();
    steering = ffcore::get_global_steering_system();

    Node *parent = get_parent();
    if (parent)
    {
        steering_native = Object::cast_to<SteeringSystemNative>(
            parent->get_node_or_null("SteeringSystemNative"));
    }

    if (!steering_native)
        UtilityFunctions::print("⚠️ AgentManagerNative: SteeringSystemNative introuvable");
}

AgentManagerNative::~AgentManagerNative() {}

AgentManagerNative::AgentManagerNative() : next_id(1) {}

int AgentManagerNative::create_group()
{
    return core_mgr ? core_mgr->create_group() : -1;
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
    if (group_id < 0)
    {
        UtilityFunctions::printerr("spawn_agent : group_id invalide");
        std::abort();
    }

    if (!core_mgr || !steering)
    {
        UtilityFunctions::printerr("spawn_agent : core_mgr ou steering absent");
        std::abort();
    }

    ffcore::Vec2 pos(node->get_global_position().x, node->get_global_position().y);

    int nav_id = next_id++;
    core_mgr->create_agent_entry(nav_id, pos, group_id);

    if (core_mgr->get(nav_id) == nullptr)
    {
        UtilityFunctions::print("CRITICAL: AgentManager n’a pas enregistré l’agent ", nav_id);
        std::abort();
    }

    double max_speed = 150.0;
    steering->register_agent_with_id(nav_id, pos, max_speed, nullptr);

    if (auto *sn = get_node<SteeringSystemNative>(NodePath("/root/Node2D/SteeringSystemNative")))
        sn->register_node_mapping(node, nav_id);

    return nav_id;
}

void AgentManagerNative::set_current_selected_group(ffcore::GroupID group)
{
    current_selected_group = group;
}

void AgentManagerNative::cleanup_groups()
{
    if (!core_mgr)
        return;

    for (ffcore::GroupID g = 1; g < ffcore::MAX_GROUPS; g++)
    {
        if (g == current_selected_group)
            continue;

        if (!core_mgr->is_group_active(g))
            continue;

        if (core_mgr->all_agents_inactive(g))
        {
            core_mgr->dissolve_group(g);
            continue;
        }

        core_mgr->mark_group_finished(g);
    }
}

void AgentManagerNative::mark_group_has_order(ffcore::GroupID group)
{
    if (!core_mgr)
        return;

    core_mgr->mark_group_has_order(group);
}
