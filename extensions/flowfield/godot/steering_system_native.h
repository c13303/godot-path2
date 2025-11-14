#ifndef STEERING_SYSTEM_NATIVE_H
#define STEERING_SYSTEM_NATIVE_H

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include "../steering/steering_system.h"
#include "../flow/flow_field.h"
#include "../grid/spatial_grid.h"

namespace godot
{

    class SteeringSystemNative : public Node2D
    {
        GDCLASS(SteeringSystemNative, Node2D);

    private:
        ffcore::SteeringSystem system;
        Node2D *flowfield = nullptr;
        Node2D *grid = nullptr;
        Node2D *agent_manager_node = nullptr;

        std::unordered_map<Node2D *, int> agent_map;

    public:
        static void _bind_methods();

        SteeringSystemNative();
        ~SteeringSystemNative() override;

        void _ready() override;
        void _process(double delta) override;

        void set_flowfield(Object *obj);
        void set_grid(Object *obj);
        void set_agent_manager(Object *obj);
        void register_node_mapping(Node2D *node, int agent_id);

        int get_agent_id(Node2D *node);
    };

} // namespace godot

#endif
