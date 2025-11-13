#include "agent_manager_native.h"
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include "../agent_manager/agent_manager.h"
#include "../core/types.h"

using namespace godot;

void AgentManagerNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("create_group"), &AgentManagerNative::create_group);
    ClassDB::bind_method(D_METHOD("set_group_flow", "group", "flow_id"), &AgentManagerNative::set_group_flow);
    ClassDB::bind_method(D_METHOD("get_group_flow", "group"), &AgentManagerNative::get_group_flow);
    ClassDB::bind_method(D_METHOD("assign_agent", "agent", "group"), &AgentManagerNative::assign_agent);
    ClassDB::bind_method(D_METHOD("create_group_with_flow", "goal_world_pos"), &AgentManagerNative::create_group_with_flow);
}

AgentManagerNative::AgentManagerNative() {}
AgentManagerNative::~AgentManagerNative() {}

int AgentManagerNative::create_group()
{
    return manager.create_group();
}

void AgentManagerNative::set_group_flow(int group, int flow_id)
{
    manager.set_group_flow(group, flow_id);
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

ffcore::GroupID AgentManagerNative::create_group_with_flow(const Vector2 &goal_world_pos)
{
    ffcore::Vec2 p(goal_world_pos.x, goal_world_pos.y);
    return manager.create_group_with_flow(p);
}
