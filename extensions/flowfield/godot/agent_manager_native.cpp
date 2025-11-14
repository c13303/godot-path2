#include "agent_manager_native.h"
#include "../core/types.h"
#include "../flow/flow_field.h"
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include "../agent_manager/agent_manager.h"
#include <cstdlib>

using namespace godot;

void AgentManagerNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("create_group"), &AgentManagerNative::create_group);
    ClassDB::bind_method(D_METHOD("get_group_flow", "group"), &AgentManagerNative::get_group_flow);
    ClassDB::bind_method(D_METHOD("assign_agent", "agent", "group"), &AgentManagerNative::assign_agent);
    ClassDB::bind_method(D_METHOD("spawn_agent", "node", "group_id"), &AgentManagerNative::spawn_agent);
}

void AgentManagerNative::_ready()
{
    core_mgr = ffcore::get_global_agent_manager();
    steering = ffcore::get_global_steering_system();

    godot::UtilityFunctions::print(
        "AgentManagerNative READY: core_mgr=", (uint64_t)core_mgr,
        " steering=", (uint64_t)steering);
}

AgentManagerNative::AgentManagerNative() {}
AgentManagerNative::~AgentManagerNative() {}

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

    core_mgr->add_agent_to_group(pos, group);
}

int AgentManagerNative::spawn_agent(Node2D *node, int group_id)
{
    godot::UtilityFunctions::print("spawn_agent GDSCRIPT APPELÉ");
    godot::UtilityFunctions::print("core_mgr ptr = ", (uint64_t)core_mgr);

    if (!core_mgr || !steering)
    {
        godot::UtilityFunctions::printerr(
            "AgentManagerNative.spawn_agent : core_mgr ou steering non initialisé. Arrêt immédiat.");

        std::abort();
    }

    ffcore::Vec2 pos(node->get_global_position().x,
                     node->get_global_position().y);

    int nav_id = core_mgr->add_agent_to_group(pos, group_id);

    int steering_id = steering->register_agent_with_id(
        nav_id, pos, default_speed, nullptr);

    link_table[node] = {steering_id, nav_id};

    godot::UtilityFunctions::print(
        "Agent créé : ID=", nav_id,
        " steering=", steering_id,
        " group=", group_id);

    return nav_id;
}
