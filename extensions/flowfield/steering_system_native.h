#ifndef STEERING_SYSTEM_NATIVE_H
#define STEERING_SYSTEM_NATIVE_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <vector>
#include <unordered_map>

#include "flow_field.h"

namespace godot {

struct AgentData {
	Node2D* node = nullptr;
	Vector2 position;
	Vector2 velocity;
	double max_speed = 100.0;
	int32_t group_id = 0;
	bool arrived = false;
};

class SteeringSystemNative : public Node {
	GDCLASS(SteeringSystemNative, Node)

protected:
	static void _bind_methods();

public:
	SteeringSystemNative();
	~SteeringSystemNative();

	void register_agent(Node2D* agent, int32_t group_id, double max_speed);
	void unregister_agent(Node2D* agent);
	void set_flowfield_for_group(int32_t group_id, FlowField* ff);
	void update_all_agents(double delta);

private:
	std::vector<AgentData> agents;
	std::unordered_map<Node2D*, int32_t> agent_indices;
	std::unordered_map<int32_t, FlowField*> flowfields;
	bool dirty = false;
};

}

#endif
