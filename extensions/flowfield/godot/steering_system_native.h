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
        // Debug toggles + paused now live in ffcore::globalconfig() (see global_config.h).

        std::unordered_map<Node2D *, int> agent_map;
        std::unordered_map<int, const ffcore::FlowField *> agent_last_flow;
        std::unordered_map<int, bool> agent_propelled_states;
        std::unordered_map<int, bool> agent_control_impaired_states;
        struct DebugAgentLabels
        {
            String physics;
            String phase;
        };
        std::unordered_map<int, DebugAgentLabels> debug_agent_label_cache;
        std::unordered_map<int, double> debug_agent_label_next_refresh;

        int _direction_code(const Vector2 &v) const;
        Vector2 _goal_position_for_agent(const ffcore::AgentData *a) const;
        void _reset_agent_cache(int agent_id);
        Dictionary _agent_summary(const ffcore::AgentData *a) const;
        String _agent_physics_label(const ffcore::AgentData *a) const;
        String _agent_phase_label(const ffcore::AgentData *a) const;

    public:
        static void _bind_methods();

        SteeringSystemNative();
        ~SteeringSystemNative() override;

        void _ready() override;
        void _process(double delta) override;
        void _draw() override;

        void set_flowfield(Object *obj);
        void set_grid(Object *obj);

        void register_node_mapping(Node2D *node, int agent_id);
        void unregister_node_mapping(int agent_id);

        int get_agent_id(Node2D *node);
        void set_agent_control_mode(int agent_id, int mode);
        void set_agent_input(int agent_id, const Vector2 &direction);
        void set_agent_manual_motion(int agent_id, double acceleration, double deceleration);
        void set_agent_profile(int agent_id, const Dictionary &profile);
        Vector2 get_agent_position(int agent_id) const;
        void apply_smash_impulse(int agent_id, const Vector2 &direction, double force, double friction_loss, double delay, bool detach_flow, double control_suppression, double control_suppression_duration);
        void apply_area_smash(const Vector2 &position, double radius, const Vector2 &direction, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes);
        void apply_cone_smash(const Vector2 &position, double radius, const Vector2 &direction, double angle_degrees, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes);
        void apply_explosion(const Vector2 &position, double radius, double intensity, double friction_loss);
        void apply_explosion_filtered(const Vector2 &position, double radius, double intensity, double friction_loss, double falloff, int ignored_agent_id, double control_suppression, double control_suppression_duration, int affected_smash_classes);
        void spawn_aoe_zone(const Vector2 &position, const Vector2 &direction, double radius, double angle_degrees, double duration, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes, const Vector2 &follow_offset = Vector2(0, 0));

        Array get_agents_in_map_cell(const Vector2i &cell) const;
        void set_paused(bool p);
        void set_debug_disable_all_debug(bool enabled);
        bool get_debug_disable_all_debug() const;
        void set_debug_draw_world_hitbox(bool enabled);
        bool get_debug_draw_world_hitbox() const;
        void set_debug_draw_bottleneck_zones(bool enabled);
        bool get_debug_draw_bottleneck_zones() const;
        void set_debug_disable_bottlenecks(bool enabled);
        bool get_debug_disable_bottlenecks() const;
        void set_debug_draw_fight_hitbox(bool enabled);
        bool get_debug_draw_fight_hitbox() const;
        void set_debug_show_agent_state_labels(bool enabled);
        bool get_debug_show_agent_state_labels() const;
        void set_debug_redraw_interval(double seconds);
        double get_debug_redraw_interval() const;

        ffcore::SteeringSystem *get_system() { return &system; }
    };

}

#endif
