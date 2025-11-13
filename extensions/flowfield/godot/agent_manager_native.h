#ifndef AGENT_MANAGER_NATIVE_H
#define AGENT_MANAGER_NATIVE_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include "../steering/agent_manager.h"

namespace godot
{

    class AgentManagerNative : public Node
    {
        GDCLASS(AgentManagerNative, Node)

    public:
        static void _bind_methods();

        AgentManagerNative();
        ~AgentManagerNative() override;

        int create_group();
        void set_group_flow(int group, int flow_id);
        void assign_agent(Node2D *agent, int group);

        ffcore::AgentManager *get_manager() { return &manager; }

    private:
        ffcore::AgentManager manager;
    };

}

#endif
