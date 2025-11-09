#include "steering_system_native.h"
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void SteeringSystemNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("register_agent", "agent", "max_speed"), &SteeringSystemNative::register_agent);
    ClassDB::bind_method(D_METHOD("unregister_agent", "agent"), &SteeringSystemNative::unregister_agent);
    ClassDB::bind_method(D_METHOD("set_flowfield", "flowfield"), &SteeringSystemNative::set_flowfield);
    ClassDB::bind_method(D_METHOD("set_grid", "grid"), &SteeringSystemNative::set_grid);
}

SteeringSystemNative::SteeringSystemNative() {}
SteeringSystemNative::~SteeringSystemNative() {}

void SteeringSystemNative::set_flowfield(Object* obj) {
    // en attente de FlowFieldNative
    flowfield = nullptr;
}

void SteeringSystemNative::set_grid(Object* obj) {
    // en attente de SpatialGridNative
    grid = nullptr;
}


void SteeringSystemNative::register_agent(Node2D* node, double max_speed) {
    if (!node) return;
    Vector2 gp = node->get_global_position();
    ffcore::Vec2 pos(gp.x, gp.y); // conversion explicite
    int id = system.register_agent(pos, max_speed);
    agent_map[node] = id;
}


void SteeringSystemNative::unregister_agent(Node2D* node) {
    if (!node || !agent_map.count(node)) return;
    system.unregister_agent(agent_map[node]);
    agent_map.erase(node);
}

void SteeringSystemNative::_process(double delta) {
    system.update_all(delta);
    for (auto& [node, id] : agent_map) {
        const ffcore::AgentData* a = system.get_agent(id);
        if (!a) continue;
        node->set_global_position(Vector2(a->position.x, a->position.y));
    }
}
