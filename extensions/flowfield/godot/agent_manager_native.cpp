#include "agent_manager_native.h"
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void AgentManagerNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("create_group"), &AgentManagerNative::create_group);
    ClassDB::bind_method(D_METHOD("set_group_flow", "group", "flow_id"), &AgentManagerNative::set_group_flow);
    ClassDB::bind_method(D_METHOD("get_group_flow", "group"), &AgentManagerNative::get_group_flow);
    ClassDB::bind_method(D_METHOD("register_agent_raw", "agent"), &AgentManagerNative::register_agent_raw);
    ClassDB::bind_method(D_METHOD("assign_agent", "agent", "group"), &AgentManagerNative::assign_agent);
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

void AgentManagerNative::register_agent_raw(Node2D *agent)
{
    if (!agent)
        return;

    Vector2 p = agent->get_global_position();
    ffcore::Vec2 pos(p.x, p.y);

    manager.create_agent(pos, -1);
}

void AgentManagerNative::assign_agent(Node2D *agent, int group)
{
    if (!agent)
        return;

    Vector2 p = agent->get_global_position();
    ffcore::Vec2 pos(p.x, p.y);

    manager.create_agent(pos, group);
}
