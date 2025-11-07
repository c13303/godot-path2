#include "steering_system_native.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void SteeringSystemNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("register_agent", "agent", "group_id", "max_speed"), &SteeringSystemNative::register_agent);
	ClassDB::bind_method(D_METHOD("unregister_agent", "agent"), &SteeringSystemNative::unregister_agent);
	ClassDB::bind_method(D_METHOD("set_flowfield_for_group", "group_id", "flowfield"), &SteeringSystemNative::set_flowfield_for_group);
	ClassDB::bind_method(D_METHOD("update_all_agents", "delta"), &SteeringSystemNative::update_all_agents);
}

SteeringSystemNative::SteeringSystemNative() {}
SteeringSystemNative::~SteeringSystemNative() {}

void SteeringSystemNative::register_agent(Node2D* agent, int32_t group_id, double max_speed) {
	if (!agent) return;
	if (agent_indices.count(agent)) return;

	AgentData data;
	data.node = agent;
	data.group_id = group_id;
	data.max_speed = max_speed;
	data.position = agent->get_global_position();
	data.velocity = Vector2();

	agents.push_back(data);
	agent_indices[agent] = (int32_t)agents.size() - 1;
}

void SteeringSystemNative::unregister_agent(Node2D* agent) {
	if (!agent) return;
	auto it = agent_indices.find(agent);
	if (it == agent_indices.end()) return;

	int idx = it->second;
	int last = (int)agents.size() - 1;
	if (idx != last) {
		agents[idx] = agents[last];
		agent_indices[agents[idx].node] = idx;
	}
	agents.pop_back();
	agent_indices.erase(it);
}

void SteeringSystemNative::set_flowfield_for_group(int32_t group_id, FlowField* ff) {
	if (!ff) return;
	flowfields[group_id] = ff;
}

void SteeringSystemNative::update_all_agents(double delta) {
	if (agents.empty()) {
		return;
	}

	// Lecture des données actuelles depuis Godot (1 lecture unique par frame)
	for (auto &a : agents) {
		if (!a.node) continue;
		a.position = a.node->get_global_position();
		Variant v = a.node->get("velocity");
		if (v.get_type() == Variant::VECTOR2) {
			a.velocity = (Vector2)v;
		} else {
			a.velocity = Vector2();
		}
	}

	// Debug : affichage d’un résumé
	int64_t arrived_count = 0;
	for (auto &a : agents) {
		if (a.arrived) arrived_count++;
	}
	UtilityFunctions::print("Snapshot OK — total:", (int64_t)agents.size(), " arrived:", arrived_count, " delta:", delta);
}
