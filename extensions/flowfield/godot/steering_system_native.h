#ifndef STEERING_SYSTEM_NATIVE_H
#define STEERING_SYSTEM_NATIVE_H

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <unordered_map>

#include "../steering/steering_system.h"
#include "../flow/flow_field.h"
#include "../grid/spatial_grid.h"

namespace godot
{
    class AgentManagerNative;

    class SteeringSystemNative : public Node2D
    {
        GDCLASS(SteeringSystemNative, Node2D);

    private:
        ffcore::SteeringSystem system;

        Node2D *flowfield = nullptr;
        Node2D *grid = nullptr;
        AgentManagerNative *agent_manager = nullptr;

        std::unordered_map<Node2D *, int> agent_map;
        std::unordered_map<int, int> agent_direction_codes;
        std::unordered_map<int, const ffcore::FlowField *> agent_last_flow;

        int _direction_code(const Vector2 &v) const;
        Vector2 _goal_position_for_agent(const ffcore::AgentData *a) const;
        void _reset_agent_cache(int agent_id);
        Dictionary _agent_summary(const ffcore::AgentData *a) const;

    public:
        static void _bind_methods();

        SteeringSystemNative();
        ~SteeringSystemNative() override;

        void _ready() override;
        void _process(double delta) override;

        void set_flowfield(Object *obj);
        void set_grid(Object *obj);

        void register_node_mapping(Node2D *node, int agent_id);

        int get_agent_id(Node2D *node);
        void apply_explosion(const Vector2 &position, double radius, double intensity, double friction_loss);

        Array get_agents_in_map_cell(const Vector2i &cell) const;
    };

}

#endif
