#include "agent_manager_native.h"
#include "../core/types.h"
#include "../flow/flow_field.h"
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include "../agent_manager/agent_manager.h"

using namespace godot;

void AgentManagerNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("create_group"), &AgentManagerNative::create_group);
    ClassDB::bind_method(D_METHOD("get_group_flow", "group"), &AgentManagerNative::get_group_flow);
    ClassDB::bind_method(D_METHOD("assign_agent", "agent", "group"), &AgentManagerNative::assign_agent);
    ClassDB::bind_method(D_METHOD("create_flow_for_group", "group", "goal_world_pos"),
                         &AgentManagerNative::create_flow_for_group);
}

AgentManagerNative::AgentManagerNative() {}
AgentManagerNative::~AgentManagerNative() {}

int AgentManagerNative::create_group()
{
    return manager.create_group();
}

ffcore::FlowFieldID AgentManagerNative::create_flow_for_group(int group, const Vector2 &goal_world_pos)
{
    ffcore::Vec2 p(goal_world_pos.x, goal_world_pos.y);
    return manager.create_flow_for_group(group, p);
}

int AgentManagerNative::get_group_flow(int group) const
{
    return manager.get_group_flow(group);
}

ffcore::AgentManager *AgentManagerNative::get_internal()
{
    return &manager;
}

void AgentManagerNative::assign_agent(Node2D *agent, int group)
{
    if (!agent)
        return;

    Vector2 p = agent->get_global_position();
    ffcore::Vec2 pos(p.x, p.y);

    manager.add_agent_to_group(pos, group);
}
