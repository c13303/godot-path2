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
#include "spatial_grid_native.h"

namespace godot
{

	struct AgentData
	{
		Node2D *node = nullptr;
		Vector2 position;
		Vector2 velocity;
		double max_speed = 100.0;
		int32_t group_id = 0;
		bool arrived = false;

		double time_in_area = 0.0;
		Vector2 last_progress_pos;
		int direction_changes = 0;
		Vector2 last_velocity_dir;
		double last_direction_check = 0.0;
	};

	class SteeringSystemNative : public Node
	{
		GDCLASS(SteeringSystemNative, Node)

	protected:
		static void _bind_methods();

	public:
		SteeringSystemNative();
		~SteeringSystemNative();

		void register_agent(Node2D *agent, int32_t group_id, double max_speed);
		void unregister_agent(Node2D *agent);
		void set_flowfield_for_group(int32_t group_id, FlowField *ff);
		void update_all_agents(double delta);

		void set_grid(SpatialGridNative *g);
		SpatialGridNative *get_grid() const { return grid; }

		Vector2 compute_separation(Node2D *agent, double neighbor_radius);

	private:
		// Données internes
		std::vector<AgentData> agents;
		std::unordered_map<Node2D *, int32_t> agent_indices;
		std::unordered_map<int32_t, FlowField *> flowfields;
		SpatialGridNative *grid = nullptr;
		bool dirty = false;

		// Sous-fonctions (refactor)
		void _snapshot_agent_states();
		void _process_agent_movements(double delta);
		void _check_flowfield_updates();

		bool _check_direct_arrival(AgentData &a, FlowField &ff);
		bool _check_immobility_and_block(AgentData &a, FlowField &ff);
		bool _is_fully_blocked(AgentData &a, FlowField &ff);

		void _mark_agent_arrived(AgentData &a);
		void _apply_steering_and_movement(AgentData &a, FlowField &ff, double delta);
		double _compute_goal_radius_px(int group_size, double tile_px, double wall_factor);
	};

}

#endif
