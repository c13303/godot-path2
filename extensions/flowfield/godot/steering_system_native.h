#ifndef STEERING_SYSTEM_NATIVE_H
#define STEERING_SYSTEM_NATIVE_H

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/vector2.hpp>
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
        std::unordered_map<int, bool> agent_propelled_states;
        std::unordered_map<int, int> agent_direction_codes;

        void maybe_emit_propelled_state(int agent_id, bool propelled);
        void maybe_emit_direction_changed(int agent_id, const Vector2 &velocity);
        int _direction_code(const Vector2 &v) const;

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
    };

}

#endif
