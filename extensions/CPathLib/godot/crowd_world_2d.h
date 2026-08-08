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

    protected:
        static void _bind_methods();

    public:
        void _physics_process(double delta) override;

        void set_automatic_step(bool enabled) { automatic_step = enabled; }
        bool is_automatic_step_enabled() const { return automatic_step; }
        void step(double delta);

        bool use_navigation_flow(NavigationWorld2D *navigation);
        std::int64_t add_agent(Vector2 position, double radius, double maximum_speed,
                               double separation_radius, double separation_weight);
        bool remove_agent(std::int64_t agent_handle);
        bool follow_flow(std::int64_t agent_handle);
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
