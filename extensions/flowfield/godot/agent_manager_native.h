#ifndef AGENT_MANAGER_NATIVE_H
#define AGENT_MANAGER_NATIVE_H

#include "../core/nav_config.h"

#include "../core/types.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/vector2.hpp>

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
        ffcore::GroupID current_selected_group = ffcore::GROUP_IDLE;

    public:
        static void _bind_methods();

        AgentManagerNative();
        ~AgentManagerNative() override;

        int create_group();
        int get_group_flow(int group) const;

        ffcore::AgentManager *get_internal();

        void assign_agent(Node2D *agent, int group);
        int spawn_agent(Node2D *node, int group_id);
        void _ready() override;
        void set_current_selected_group(ffcore::GroupID group);
        void cleanup_groups();
        void mark_group_has_order(ffcore::GroupID group);
    };
}

#endif
