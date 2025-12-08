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
        std::unordered_map<int, bool> agent_propelled_states;
        std::unordered_map<int, int> agent_direction_codes;
        std::unordered_map<int, Vector2i> agent_last_cells;
        std::unordered_map<int, bool> agent_arrived_states;
        std::unordered_map<int, const ffcore::FlowField *> agent_last_flow;
        std::unordered_map<int, bool> agent_moving_states;
        struct ArrivalState
        {
            bool is_near_goal = false;
            bool is_stopped = false;
            bool has_arrived = false;
            double time_at_goal = 0.0;
            double distance_to_goal = 0.0;
            double velocity_magnitude = 0.0;
            Vector2 goal_position = Vector2();
            bool arrived_last_frame = false;
        };
        std::unordered_map<int, ArrivalState> arrival_states;

        double arrival_goal_radius = 10.0;
        double arrival_hysteresis_margin = 5.0;
        double arrival_velocity_threshold = 1.0;
        double arrival_time_requirement = 0.5;
        bool arrival_enable_signals = true;
        int arrival_signals_per_frame_cap = 64;
        bool arrival_debug_logs = false;
        int arrival_debug_frame = 0;

        void maybe_emit_propelled_state(int agent_id, bool propelled);
        void maybe_emit_direction_changed(int agent_id, int code, const Vector2 &dir);
        int _direction_code(const Vector2 &v) const;
        void _update_arrival_state(int agent_id, const ffcore::AgentData *a, double delta);
        bool _maybe_emit_arrival_changed(int agent_id, int &emitted_count);
        Vector2 _goal_position_for_agent(const ffcore::AgentData *a) const;
        void _reset_agent_cache(int agent_id, bool preserve_arrival = false);
        bool _compute_is_moving(const Vector2 &vel) const;
        int _compute_dir_from_velocity(const Vector2 &v) const;
        void _maybe_update_animation(int agent_id, const Vector2 &vel);

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

        double get_arrival_goal_radius() const;
        void set_arrival_goal_radius(double v);
        double get_arrival_hysteresis_margin() const;
        void set_arrival_hysteresis_margin(double v);
        double get_arrival_velocity_threshold() const;
        void set_arrival_velocity_threshold(double v);
        double get_arrival_time_requirement() const;
        void set_arrival_time_requirement(double v);
        bool get_arrival_enable_signals() const;
        void set_arrival_enable_signals(bool v);
        int get_arrival_signals_per_frame_cap() const;
        void set_arrival_signals_per_frame_cap(int v);
        bool get_arrival_debug_logs() const;
        void set_arrival_debug_logs(bool v);

        Dictionary get_agent_arrival_metrics(int agent_id) const;
    };

}

#endif
