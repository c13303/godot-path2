#ifndef AGENT_MANAGER_NATIVE_H
#define AGENT_MANAGER_NATIVE_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include "../steering/agent_manager.h"
#include <godot_cpp/classes/node2d.hpp>

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
        void register_agent_raw(Node2D *agent);
        void assign_agent(Node2D *agent, int group);
    };
}

#endif
