#ifndef AGENT_MANAGER_NATIVE_H
#define AGENT_MANAGER_NATIVE_H

#include "../core/nav_config.h"
#include "../core/types.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <unordered_map>

#include "../agent_manager/agent_manager.h"
#include "../steering/steering_system.h"
#include "../godot/steering_system_native.h"

namespace godot
{

    class AgentManagerNative : public Node
    {
        GDCLASS(AgentManagerNative, Node);

    private:
        ffcore::AgentManager *core_mgr = nullptr;
        ffcore::SteeringSystem *steering = nullptr;
        SteeringSystemNative *steering_native = nullptr;

        int next_id = 1;

        double default_speed = 150.0;

        struct LinkEntry
        {
            int steering_id;
            int nav_id;
        };

        std::unordered_map<Node2D *, LinkEntry> link_table;
        std::unordered_map<int, Node2D *> id_to_node;

        ffcore::GroupID current_selected_group = ffcore::GROUP_IDLE;
        void emit_agent_event(const String &event_name, int agent_id, const Variant &payload);

    public:
        static void _bind_methods();

        AgentManagerNative();
        ~AgentManagerNative() override;

        int create_group();

        void assign_agent(Node2D *agent, int group);
        int spawn_agent(Node2D *node, int group_id);

        void _ready() override;

        void set_current_selected_group(ffcore::GroupID group);
        void cleanup_groups();
        void dissolve_group(ffcore::GroupID group);
        void mark_group_has_order(ffcore::GroupID group);
        int count_group_members(ffcore::GroupID group) const;
        int count_group_route_references(ffcore::GroupID group) const;
        int get_group_flow_wait(ffcore::GroupID group) const;

        void update_godot_agent(Node2D *node, int agent_id);
        Node2D *find_node_by_agent(int agent_id);
        void unregister_agent(int agent_id);

        // Read-only, gameplay-agnostic registration snapshot for the debug
        // consistency watcher. Returns the registered agent ids of the four
        // native ownership structures this node drives, each as a sorted
        // PackedInt32Array: "core_agent_ids", "steering_agent_ids",
        // "agent_node_mapping_ids", "steering_node_mapping_ids". No mutation,
        // no cleanup, no node-pointer dereferencing.
        Dictionary get_registration_debug_snapshot() const;

        void send_agent_event(const String &event_name, int agent_id, const Variant &payload);
        void set_agent_never_rest(int agent_id, bool value);
        void set_agent_paused(int agent_id, bool value);
        void set_agent_waiting_flow_group(int agent_id, int group_id);
        void set_agent_phase(int agent_id, int phase, float eating_seconds);
        void detach_agent_flow(int agent_id);

        void assign_agent_path(int agent_id, const PackedVector2Array &waypoints_world);
        void detach_agent_path(int agent_id);
        bool agent_path_arrived(int agent_id) const;
    };

}

#endif
