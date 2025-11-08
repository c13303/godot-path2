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
		int32_t group_id = 0;
		double max_speed = 0.0;
		Vector2 position;
		Vector2 velocity;
		bool arrived = false;

		// --- Ajouts pour suivi du progrès ---
		double progress_sum = 0.0;		 // cumul du progrès signé
		double progress_timer = 0.0;	 // temps accumulé depuis dernière vérif
		bool parked = false;			 // état "en pause"
		std::deque<Vector2> pos_history; // historique des positions (fenêtre glissante)
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
