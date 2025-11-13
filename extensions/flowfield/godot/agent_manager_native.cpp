#include "agent_manager_native.h"

using namespace godot;

void AgentManagerNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("create_group"), &AgentManagerNative::create_group);
    ClassDB::bind_method(D_METHOD("set_group_flow", "group", "flow_id"), &AgentManagerNative::set_group_flow);
    ClassDB::bind_method(D_METHOD("get_group_flow", "group"), &AgentManagerNative::get_group_flow);
}

AgentManagerNative::AgentManagerNative() {}
AgentManagerNative::~AgentManagerNative() {}

int AgentManagerNative::create_group() {
    return manager.create_group();
}

void AgentManagerNative::set_group_flow(int group, int flow_id) {
    manager.set_group_flow(group, flow_id);
}

int AgentManagerNative::get_group_flow(int group) const {
    return manager.get_group_flow(group);
}

ffcore::AgentManager *AgentManagerNative::get_internal() {
    return &manager;
}
