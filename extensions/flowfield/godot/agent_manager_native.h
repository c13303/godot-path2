#ifndef AGENT_MANAGER_NATIVE_H
#define AGENT_MANAGER_NATIVE_H

#include "../core/types.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include "../agent_manager/agent_manager.h"
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot
{
    class AgentManagerNative : public Node
    {
        GDCLASS(AgentManagerNative, Node);

    private:
        ffcore::AgentManager manager;

    public:
        static void _bind_methods();

        AgentManagerNative();
        ~AgentManagerNative() override;

        int create_group();
        void set_group_flow(int group, int flow_id);
        int get_group_flow(int group) const;
        ffcore::AgentManager *get_internal();
        void assign_agent(Node2D *agent, int group);
        ffcore::GroupID create_group_with_flow(const Vector2 &goal_world_pos);
    };
}

#endif
