#pragma once

#include "navigation_world_2d.h"
#include "../crowd/crowd_world.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

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
        static ffcore::CrowdAgentProfile make_profile(
            double radius, double maximum_speed, double acceleration, double deceleration,
            double separation_radius, double separation_weight, double arrival_radius,
            int terrain_speed_channel, std::int64_t category_mask);

    protected:
        static void _bind_methods();

    public:
        void _physics_process(double delta) override;

        void set_automatic_step(bool enabled) { automatic_step = enabled; }
        bool is_automatic_step_enabled() const { return automatic_step; }
        void step(double delta);
        void set_world_paused(bool paused);
        bool is_world_paused() const;

        bool use_navigation_flow(NavigationWorld2D *navigation);
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
        void apply_impulse(std::int64_t agent_handle, Vector2 velocity, double delay,
                           double decay_per_second, double control_suppression_seconds,
                           bool preserve_navigation, int priority);
        bool refresh_external_velocity(std::int64_t agent_handle, int source_id,
                                       Vector2 velocity, double response_seconds,
                                       double expiry_seconds);
        bool release_external_velocity(std::int64_t agent_handle, int source_id);
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

        Vector2 get_agent_position(std::int64_t agent_handle) const;
        Vector2 get_agent_velocity(std::int64_t agent_handle) const;
        int get_agent_route_progress(std::int64_t agent_handle) const;
        PackedInt64Array get_agent_handles() const;
        PackedVector2Array get_agent_positions() const;
        PackedVector2Array get_agent_velocities() const;
        int get_agent_count() const;
    };
} // namespace godot
