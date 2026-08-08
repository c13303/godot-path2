#pragma once

#include "navigation_world_2d.h"
#include "../crowd/crowd_world.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot
{
    class CrowdWorld2D : public Node
    {
        GDCLASS(CrowdWorld2D, Node);

    private:
        ffcore::CrowdWorld crowd;
        bool automatic_step = true;

        static std::int64_t encode_handle(ffcore::AgentHandle handle);
        static ffcore::AgentHandle decode_handle(std::int64_t encoded);
        static std::int64_t encode_profile_handle(ffcore::ProfileHandle handle);
        static ffcore::ProfileHandle decode_profile_handle(std::int64_t encoded);
        static std::int64_t encode_cohort_handle(ffcore::CohortHandle handle);
        static ffcore::CohortHandle decode_cohort_handle(std::int64_t encoded);
        static ffcore::FlowHandle decode_flow_handle(std::int64_t encoded);
        static std::int64_t encode_obstacle_handle(ffcore::StaticObstacleHandle handle);
        static ffcore::StaticObstacleHandle decode_obstacle_handle(std::int64_t encoded);
        static std::int64_t encode_directional_field_handle(
            ffcore::DirectionalMotionFieldHandle handle);
        static ffcore::DirectionalMotionFieldHandle decode_directional_field_handle(
            std::int64_t encoded);
        static std::int64_t encode_effect_volume_handle(ffcore::EffectVolumeHandle handle);
        static ffcore::EffectVolumeHandle decode_effect_volume_handle(std::int64_t encoded);
        static std::int64_t encode_external_velocity_source_handle(
            ffcore::ExternalVelocitySourceHandle handle);
        static ffcore::ExternalVelocitySourceHandle decode_external_velocity_source_handle(
            std::int64_t encoded);
        static ffcore::CrowdAgentProfile make_profile(
            double radius, double maximum_speed, double acceleration, double deceleration,
            double separation_radius, double separation_weight, double arrival_radius,
            int terrain_speed_channel, std::int64_t category_mask);

    protected:
        static void _bind_methods();

    public:
        void _physics_process(double delta) override;
        ffcore::CrowdWorld &core_world() { return crowd; }

        void set_automatic_step(bool enabled) { automatic_step = enabled; }
        bool is_automatic_step_enabled() const { return automatic_step; }
        void step(double delta);
        void set_world_paused(bool paused);
        bool is_world_paused() const;

        bool use_navigation_flow(NavigationWorld2D *navigation);
        bool use_navigation_flow_handle(NavigationWorld2D *navigation,
                                        std::int64_t flow_handle);
        bool install_navigation_flow(NavigationWorld2D *navigation, std::int64_t flow_handle);
        bool remove_navigation_flow(std::int64_t flow_handle);
        void configure_default_profile(
            double radius, double maximum_speed, double acceleration, double deceleration,
            double separation_radius, double separation_weight, double arrival_radius,
            int terrain_speed_channel, std::int64_t category_mask);
        std::int64_t create_profile(
            double radius, double maximum_speed, double acceleration, double deceleration,
            double separation_radius, double separation_weight, double arrival_radius,
            int terrain_speed_channel, std::int64_t category_mask);
        bool update_profile(
            std::int64_t profile_handle, double radius, double maximum_speed,
            double acceleration, double deceleration, double separation_radius,
            double separation_weight, double arrival_radius, int terrain_speed_channel,
            std::int64_t category_mask);
        bool remove_profile(std::int64_t profile_handle);
        std::int64_t add_agent(Vector2 position, double radius, double maximum_speed,
                               double separation_radius, double separation_weight);
        std::int64_t add_agent_with_profile(Vector2 position, std::int64_t profile_handle);
        bool remove_agent(std::int64_t agent_handle);
        bool set_agent_profile(std::int64_t agent_handle, std::int64_t profile_handle);
        bool set_agent_position(std::int64_t agent_handle, Vector2 position,
                                bool clear_velocity = true);
        bool set_agent_motion_limits(std::int64_t agent_handle, double maximum_speed,
                                     double acceleration, double deceleration);
        bool set_agent_collision_offset(std::int64_t agent_handle, Vector2 offset);
        bool set_agent_avoidance_profile(std::int64_t agent_handle,
                                         double push_strength, double resistance);
        bool set_agent_impulse_resistance(std::int64_t agent_handle, double resistance);
        bool set_agent_query_shape(std::int64_t agent_handle, Vector2 offset,
                                   Vector2 half_extents);
        bool set_agent_contact_profile(
            std::int64_t agent_handle, double push_strength, double resistance,
            double cooldown, double impulse_decay, double control_suppression,
            bool feedback_enabled = true);
        bool set_agent_traffic_state(std::int64_t agent_handle,
                                     std::int64_t group_token, int priority);
        void configure_agent_interactions(
            bool contact_push_enabled, bool right_of_way_enabled,
            double right_of_way_push_speed, double right_of_way_cooldown,
            double right_of_way_control_suppression);
        std::int64_t create_cohort();
        bool remove_cohort(std::int64_t cohort_handle);
        bool assign_agent_to_cohort(std::int64_t agent_handle, std::int64_t cohort_handle);
        bool remove_agent_from_cohort(std::int64_t agent_handle);
        bool assign_cohort_flow(std::int64_t cohort_handle, std::int64_t flow_handle);
        int get_cohort_member_count(std::int64_t cohort_handle) const;
        bool follow_flow(std::int64_t agent_handle);
        bool follow_flow_handle(std::int64_t agent_handle, std::int64_t flow_handle);
        bool follow_path(std::int64_t agent_handle, const PackedVector2Array &world_points);
        bool set_manual_direction(std::int64_t agent_handle, Vector2 direction);
        bool stop_navigation(std::int64_t agent_handle);
        bool set_agent_paused(std::int64_t agent_handle, bool paused);
        bool set_agent_pause_allows_impulses(std::int64_t agent_handle, bool enabled);
        bool set_agent_navigation_suspended(std::int64_t agent_handle, bool suspended);
        bool set_agent_forces_enabled(std::int64_t agent_handle, bool enabled);
        bool set_agent_continue_at_flow_goal(std::int64_t agent_handle, bool enabled);
        void clear_agent_forces(std::int64_t agent_handle);
        void configure_navigation_behavior(
            bool automatic_bottleneck_gating, double bottleneck_wait_speed_ratio,
            double flow_goal_stop_delay, double flow_goal_group_delay,
            double flow_goal_slow_speed_ratio, double zero_flow_retry_seconds,
            double zero_flow_recovery_speed_ratio, double blocked_motion_retry_seconds);
        void configure_static_obstacle_avoidance(double strength, double query_padding);
        std::int64_t create_static_obstacle(Vector2 position, double radius,
                                            double push_strength = 1.0);
        bool update_static_obstacle(std::int64_t obstacle_handle, Vector2 position,
                                    double radius, double push_strength = 1.0);
        bool remove_static_obstacle(std::int64_t obstacle_handle);
        void clear_static_obstacles();
        int get_static_obstacle_count() const;
        std::int64_t create_directional_motion_field(
            Vector2 world_origin, double cell_size, double speed,
            const PackedVector2Array &cells, const PackedVector2Array &directions,
            Vector2 sample_offset = Vector2(), double fallback_radius = 0.0);
        bool update_directional_motion_field(
            std::int64_t field_handle, Vector2 world_origin, double cell_size, double speed,
            const PackedVector2Array &cells, const PackedVector2Array &directions,
            Vector2 sample_offset = Vector2(), double fallback_radius = 0.0);
        bool remove_directional_motion_field(std::int64_t field_handle);
        void clear_directional_motion_fields();
        bool follow_directional_motion_field(std::int64_t agent_handle,
                                             std::int64_t field_handle);
        void apply_impulse(std::int64_t agent_handle, Vector2 velocity, double delay,
                           double decay_per_second, double control_suppression_seconds,
                           bool preserve_navigation, int priority,
                           bool apply_agent_resistance = false);
        int apply_impulse_batch(
            const PackedInt64Array &agent_handles,
            const PackedVector2Array &velocities, double delay,
            double decay_per_second, double control_suppression_seconds,
            bool preserve_navigation, int priority,
            bool apply_agent_resistance = false);
        std::int64_t create_external_velocity_source();
        bool remove_external_velocity_source(std::int64_t source_handle);
        bool refresh_external_velocity(std::int64_t agent_handle, std::int64_t source_handle,
                                       Vector2 velocity, double response_seconds,
                                       double expiry_seconds);
        bool release_external_velocity(std::int64_t agent_handle,
                                       std::int64_t source_handle);
        std::int64_t create_effect_volume(const Dictionary &configuration);
        bool update_effect_volume(std::int64_t volume_handle, Vector2 position,
                                  Vector2 direction, Vector2 follow_offset);
        bool remove_effect_volume(std::int64_t volume_handle);
        int get_effect_volume_count() const;
        Array take_effect_events();
        void configure_bottleneck(std::int64_t bottleneck_id, int capacity,
                                  double reservation_timeout);
        bool request_bottleneck(std::int64_t bottleneck_id, std::int64_t agent_handle,
                                int direction, int priority);
        bool has_bottleneck_access(std::int64_t bottleneck_id,
                                   std::int64_t agent_handle) const;
        void release_bottleneck(std::int64_t bottleneck_id, std::int64_t agent_handle);
        void replace_terrain_speed_channel(const PackedVector2Array &cells,
                                           const PackedFloat64Array &multipliers,
                                           int channel);
        void set_terrain_speed_cell(Vector2i cell, double multiplier, int channel = 0);
        void set_terrain_speed_cells(const PackedVector2Array &cells,
                                     const PackedFloat64Array &multipliers, int channel = 0);
        void clear_terrain_speed_cell(Vector2i cell, int channel = 0);
        void clear_terrain_speed_cells(const PackedVector2Array &cells, int channel = 0);
        void clear_terrain_speed_channel(int channel = 0);

        Vector2 get_agent_position(std::int64_t agent_handle) const;
        Vector2 get_agent_velocity(std::int64_t agent_handle) const;
        int get_agent_route_progress(std::int64_t agent_handle) const;
        Dictionary get_agent_diagnostics(std::int64_t agent_handle) const;
        Dictionary get_active_impulse_states() const;
        PackedInt64Array query_agents_in_circle(
            Vector2 position, double radius, std::int64_t category_mask,
            std::int64_t ignored_agent_handle = 0) const;
        PackedInt64Array query_agents_in_cone(
            Vector2 position, double radius, Vector2 direction, double angle_degrees,
            std::int64_t category_mask, std::int64_t ignored_agent_handle = 0) const;
        PackedInt64Array query_agents_in_aabb(
            Rect2 bounds, std::int64_t category_mask,
            std::int64_t ignored_agent_handle = 0) const;
        PackedInt64Array get_agents_in_navigation_cell(
            NavigationWorld2D *navigation, Vector2i cell) const;
        PackedInt64Array get_agent_handles() const;
        PackedVector2Array get_agent_positions() const;
        PackedVector2Array get_agent_velocities() const;
        int get_agent_count() const;
    };
} // namespace godot
