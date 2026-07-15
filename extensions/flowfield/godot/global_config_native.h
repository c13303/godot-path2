#ifndef GLOBAL_CONFIG_NATIVE_H
#define GLOBAL_CONFIG_NATIVE_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include "../core/global_config.h"

namespace godot
{

    class GlobalConfigNative : public Node
    {
        GDCLASS(GlobalConfigNative, Node);

    protected:
        static void _bind_methods();

    public:
        GlobalConfigNative() = default;
        ~GlobalConfigNative() override = default;

        double get_flow_weight() const;
        void set_flow_weight(double v);
        double get_agent_max_speed() const;
        void set_agent_max_speed(double v);

        double get_center_pull() const;
        void set_center_pull(double v);

        double get_tile_size() const;
        void set_tile_size(double v);

        double get_wall_avoid_radius() const;
        void set_wall_avoid_radius(double v);

        double get_wall_repel_strength() const;
        void set_wall_repel_strength(double v);

        double get_movement_threshold() const;
        void set_movement_threshold(double v);

        double get_direct_steer_radius() const;
        void set_direct_steer_radius(double v);

        double get_min_speed_fraction() const;
        void set_min_speed_fraction(double v);

        double get_cellgoal_cooldown_sec() const;
        void set_cellgoal_cooldown_sec(double v);

        double get_target_T2_param_margin() const;
        void set_target_T2_param_margin(double v);

        double get_target_T2_param_speed_ratio() const;
        void set_target_T2_param_speed_ratio(double v);

        double get_target_T2_param_speed_lerp() const;
        void set_target_T2_param_speed_lerp(double v);

        double get_separation_radius() const;
        void set_separation_radius(double v);

        double get_agent_world_diameter_ratio() const;
        void set_agent_world_diameter_ratio(double v);
        double get_agent_world_radius() const;

        int get_bottleneck_zone_radius_tiles() const;
        void set_bottleneck_zone_radius_tiles(int v);
        double get_bottleneck_reservation_seconds() const;
        void set_bottleneck_reservation_seconds(double v);
        double get_bottleneck_wait_speed_ratio() const;
        void set_bottleneck_wait_speed_ratio(double v);
        double get_bottleneck_backoff_strength() const;
        void set_bottleneck_backoff_strength(double v);
        double get_bottleneck_backward_push_ratio() const;
        void set_bottleneck_backward_push_ratio(double v);
        double get_bottleneck_lateral_push_ratio() const;
        void set_bottleneck_lateral_push_ratio(double v);
        double get_priority_separation_bias() const;
        void set_priority_separation_bias(double v);
        bool get_traffic_right_of_way_enabled() const;
        void set_traffic_right_of_way_enabled(bool v);
        double get_traffic_push_force() const;
        void set_traffic_push_force(double v);
        double get_traffic_push_cooldown() const;
        void set_traffic_push_cooldown(double v);
        double get_traffic_control_lock_seconds() const;
        void set_traffic_control_lock_seconds(double v);

        double get_separation_strength() const;
        void set_separation_strength(double v);

        int get_max_neighbors() const;
        void set_max_neighbors(int v);

        double get_lerp_general() const;
        void set_lerp_general(double v);

        double get_friction_factor() const;
        void set_friction_factor(double v);

        double get_smash_threshold() const;
        void set_smash_threshold(double v);

        double get_smash_min_cutoff() const;
        void set_smash_min_cutoff(double v);

        double get_smash_cap() const;
        void set_smash_cap(double v);

        double get_shockwave_speed() const;
        void set_shockwave_speed(double v);

        double get_explosion_falloff() const;
        void set_explosion_falloff(double v);

        double get_shockwave_stop_ratio() const;
        void set_shockwave_stop_ratio(double v);

        double get_shockwave_stop_duration_ms() const;
        void set_shockwave_stop_duration_ms(double v);

        double get_flow_field_wall_clearance() const;
        void set_flow_field_wall_clearance(double v);

        double get_lost_retry_seconds() const;
        void set_lost_retry_seconds(double v);

        bool get_draw_flow_field() const;
        void set_draw_flow_field(bool v);
        bool get_debug_show_zones() const;
        void set_debug_show_zones(bool v);

        double get_debug_nav_frame_lag_ms() const;
        void set_debug_nav_frame_lag_ms(double v);
        double get_debug_flowfield_rebuild_lag_ms() const;
        void set_debug_flowfield_rebuild_lag_ms(double v);

        // Backward-compatible aliases (deprecated; forward to the generic names).
        bool get_debug_show_plant_zones() const;
        void set_debug_show_plant_zones(bool v);
        double get_debug_plantff_frame_lag_ms() const;
        void set_debug_plantff_frame_lag_ms(double v);
        double get_debug_plantff_ff_lag_ms() const;
        void set_debug_plantff_ff_lag_ms(double v);

        void reset_defaults();
    };

} // namespace godot

#endif // GLOBAL_CONFIG_NATIVE_H
