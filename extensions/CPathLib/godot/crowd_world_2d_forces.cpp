#include "crowd_world_2d.h"

#include <vector>

namespace godot
{
    bool CrowdWorld2D::set_agent_contact_profile(
        std::int64_t agent_handle, double push_strength, double resistance,
        double cooldown, double impulse_decay, double control_suppression,
        bool feedback_enabled)
    {
        return crowd.set_agent_contact_profile(
            decode_handle(agent_handle), push_strength, resistance,
            cooldown, impulse_decay, control_suppression, feedback_enabled);
    }

    bool CrowdWorld2D::set_agent_traffic_state(
        std::int64_t agent_handle, std::int64_t group_token, int priority)
    {
        return crowd.set_agent_traffic_state(
            decode_handle(agent_handle), group_token, priority);
    }

    void CrowdWorld2D::configure_agent_interactions(
        bool contact_push_enabled, bool right_of_way_enabled,
        double right_of_way_push_speed, double right_of_way_cooldown,
        double right_of_way_control_suppression)
    {
        ffcore::CrowdWorldConfig config = crowd.get_config();
        config.interactions.contact_push_enabled = contact_push_enabled;
        config.interactions.right_of_way_enabled = right_of_way_enabled;
        config.interactions.right_of_way_push_speed = right_of_way_push_speed;
        config.interactions.right_of_way_cooldown = right_of_way_cooldown;
        config.interactions.right_of_way_control_suppression =
            right_of_way_control_suppression;
        crowd.set_config(config);
    }

    void CrowdWorld2D::apply_impulse(
        std::int64_t agent_handle, Vector2 velocity, double delay,
        double decay_per_second, double control_suppression_seconds,
        bool preserve_navigation, int priority, bool apply_agent_resistance)
    {
        ffcore::ImpulseRequest request;
        request.velocity = {velocity.x, velocity.y};
        request.delay = delay;
        request.decay_per_second = decay_per_second;
        request.control_suppression_seconds = control_suppression_seconds;
        request.preserve_navigation = preserve_navigation;
        request.priority = priority;
        request.apply_agent_resistance = apply_agent_resistance;
        crowd.apply_impulse(decode_handle(agent_handle), request);
    }

    int CrowdWorld2D::apply_impulse_batch(
        const PackedInt64Array &agent_handles,
        const PackedVector2Array &velocities, double delay,
        double decay_per_second, double control_suppression_seconds,
        bool preserve_navigation, int priority, bool apply_agent_resistance)
    {
        if (agent_handles.size() != velocities.size())
            return 0;
        std::vector<ffcore::AgentHandle> converted_handles;
        std::vector<ffcore::Vec2> converted_velocities;
        converted_handles.reserve(agent_handles.size());
        converted_velocities.reserve(velocities.size());
        for (int index = 0; index < agent_handles.size(); ++index)
        {
            converted_handles.push_back(decode_handle(agent_handles[index]));
            converted_velocities.push_back({velocities[index].x, velocities[index].y});
        }
        ffcore::ImpulseRequest settings;
        settings.delay = delay;
        settings.decay_per_second = decay_per_second;
        settings.control_suppression_seconds = control_suppression_seconds;
        settings.preserve_navigation = preserve_navigation;
        settings.priority = priority;
        settings.apply_agent_resistance = apply_agent_resistance;
        return static_cast<int>(crowd.apply_impulses(
            converted_handles, converted_velocities, settings));
    }

    std::int64_t CrowdWorld2D::create_external_velocity_source()
    {
        return encode_external_velocity_source_handle(
            crowd.create_external_velocity_source());
    }

    bool CrowdWorld2D::remove_external_velocity_source(std::int64_t source_handle)
    {
        return crowd.remove_external_velocity_source(
            decode_external_velocity_source_handle(source_handle));
    }

    bool CrowdWorld2D::refresh_external_velocity(
        std::int64_t agent_handle, std::int64_t source_handle,
        Vector2 velocity, double response_seconds, double expiry_seconds)
    {
        return crowd.refresh_external_velocity(
            decode_handle(agent_handle),
            decode_external_velocity_source_handle(source_handle),
            {velocity.x, velocity.y}, response_seconds, expiry_seconds);
    }

    bool CrowdWorld2D::release_external_velocity(
        std::int64_t agent_handle, std::int64_t source_handle)
    {
        return crowd.release_external_velocity(
            decode_handle(agent_handle),
            decode_external_velocity_source_handle(source_handle));
    }
} // namespace godot
