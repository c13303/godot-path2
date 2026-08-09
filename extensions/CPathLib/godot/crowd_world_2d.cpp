#include "crowd_world_2d.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <vector>

namespace godot
{
    void CrowdWorld2D::_bind_methods()
    {
        ClassDB::bind_method(D_METHOD("set_automatic_step", "enabled"), &CrowdWorld2D::set_automatic_step);
        ClassDB::bind_method(D_METHOD("is_automatic_step_enabled"), &CrowdWorld2D::is_automatic_step_enabled);
        ClassDB::bind_method(D_METHOD("step", "delta"), &CrowdWorld2D::step);
        ClassDB::bind_method(D_METHOD("set_world_paused", "paused"), &CrowdWorld2D::set_world_paused);
        ClassDB::bind_method(D_METHOD("is_world_paused"), &CrowdWorld2D::is_world_paused);
        ClassDB::bind_method(D_METHOD("use_navigation_flow", "navigation"), &CrowdWorld2D::use_navigation_flow);
        ClassDB::bind_method(D_METHOD("use_navigation_flow_handle", "navigation", "flow_handle"), &CrowdWorld2D::use_navigation_flow_handle);
        ClassDB::bind_method(D_METHOD("install_navigation_flow", "navigation", "flow_handle"), &CrowdWorld2D::install_navigation_flow);
        ClassDB::bind_method(D_METHOD("remove_navigation_flow", "flow_handle"), &CrowdWorld2D::remove_navigation_flow);
        ClassDB::bind_method(D_METHOD("configure_default_profile", "radius", "maximum_speed", "acceleration", "deceleration", "separation_radius", "separation_weight", "arrival_radius", "terrain_speed_channel", "category_mask"), &CrowdWorld2D::configure_default_profile);
        ClassDB::bind_method(D_METHOD("create_profile", "radius", "maximum_speed", "acceleration", "deceleration", "separation_radius", "separation_weight", "arrival_radius", "terrain_speed_channel", "category_mask"), &CrowdWorld2D::create_profile);
        ClassDB::bind_method(D_METHOD("update_profile", "profile_handle", "radius", "maximum_speed", "acceleration", "deceleration", "separation_radius", "separation_weight", "arrival_radius", "terrain_speed_channel", "category_mask"), &CrowdWorld2D::update_profile);
        ClassDB::bind_method(D_METHOD("remove_profile", "profile_handle"), &CrowdWorld2D::remove_profile);
        ClassDB::bind_method(D_METHOD("add_agent", "position", "radius", "maximum_speed", "separation_radius", "separation_weight"), &CrowdWorld2D::add_agent);
        ClassDB::bind_method(D_METHOD("add_agent_with_profile", "position", "profile_handle"), &CrowdWorld2D::add_agent_with_profile);
        ClassDB::bind_method(D_METHOD("remove_agent", "agent_handle"), &CrowdWorld2D::remove_agent);
        ClassDB::bind_method(D_METHOD("set_agent_profile", "agent_handle", "profile_handle"), &CrowdWorld2D::set_agent_profile);
        ClassDB::bind_method(D_METHOD("set_agent_position", "agent_handle", "position", "clear_velocity"), &CrowdWorld2D::set_agent_position, DEFVAL(true));
        ClassDB::bind_method(D_METHOD("set_agent_motion_limits", "agent_handle", "maximum_speed", "acceleration", "deceleration"), &CrowdWorld2D::set_agent_motion_limits);
        ClassDB::bind_method(D_METHOD("set_agent_collision_offset", "agent_handle", "offset"), &CrowdWorld2D::set_agent_collision_offset);
        ClassDB::bind_method(D_METHOD("set_agent_avoidance_profile", "agent_handle", "push_strength", "resistance"), &CrowdWorld2D::set_agent_avoidance_profile);
        ClassDB::bind_method(D_METHOD("set_agent_impulse_resistance", "agent_handle", "resistance"), &CrowdWorld2D::set_agent_impulse_resistance);
        ClassDB::bind_method(D_METHOD("set_agent_query_shape", "agent_handle", "offset", "half_extents"), &CrowdWorld2D::set_agent_query_shape);
        ClassDB::bind_method(D_METHOD("set_agent_contact_profile", "agent_handle", "push_strength", "resistance", "cooldown", "impulse_decay", "control_suppression", "feedback_enabled"), &CrowdWorld2D::set_agent_contact_profile, DEFVAL(true));
        ClassDB::bind_method(D_METHOD("set_agent_traffic_state", "agent_handle", "group_token", "priority"), &CrowdWorld2D::set_agent_traffic_state);
        ClassDB::bind_method(D_METHOD("configure_agent_interactions", "contact_push_enabled", "right_of_way_enabled", "right_of_way_push_speed", "right_of_way_cooldown", "right_of_way_control_suppression"), &CrowdWorld2D::configure_agent_interactions);
        ClassDB::bind_method(D_METHOD("configure_impulse_response", "speed_cap", "maximum_duration", "minimum_speed"), &CrowdWorld2D::configure_impulse_response);
        ClassDB::bind_method(D_METHOD("create_cohort"), &CrowdWorld2D::create_cohort);
        ClassDB::bind_method(D_METHOD("remove_cohort", "cohort_handle"), &CrowdWorld2D::remove_cohort);
        ClassDB::bind_method(D_METHOD("assign_agent_to_cohort", "agent_handle", "cohort_handle"), &CrowdWorld2D::assign_agent_to_cohort);
        ClassDB::bind_method(D_METHOD("remove_agent_from_cohort", "agent_handle"), &CrowdWorld2D::remove_agent_from_cohort);
        ClassDB::bind_method(D_METHOD("assign_cohort_flow", "cohort_handle", "flow_handle"), &CrowdWorld2D::assign_cohort_flow);
        ClassDB::bind_method(D_METHOD("get_cohort_member_count", "cohort_handle"), &CrowdWorld2D::get_cohort_member_count);
        ClassDB::bind_method(D_METHOD("follow_flow", "agent_handle"), &CrowdWorld2D::follow_flow);
        ClassDB::bind_method(D_METHOD("follow_flow_handle", "agent_handle", "flow_handle"), &CrowdWorld2D::follow_flow_handle);
        ClassDB::bind_method(D_METHOD("follow_path", "agent_handle", "world_points"), &CrowdWorld2D::follow_path);
        ClassDB::bind_method(D_METHOD("set_manual_direction", "agent_handle", "direction"), &CrowdWorld2D::set_manual_direction);
        ClassDB::bind_method(D_METHOD("stop_navigation", "agent_handle"), &CrowdWorld2D::stop_navigation);
        ClassDB::bind_method(D_METHOD("set_agent_paused", "agent_handle", "paused"), &CrowdWorld2D::set_agent_paused);
        ClassDB::bind_method(D_METHOD("set_agent_pause_allows_impulses", "agent_handle", "enabled"), &CrowdWorld2D::set_agent_pause_allows_impulses);
        ClassDB::bind_method(D_METHOD("set_agent_navigation_suspended", "agent_handle", "suspended"), &CrowdWorld2D::set_agent_navigation_suspended);
        ClassDB::bind_method(D_METHOD("set_agent_forces_enabled", "agent_handle", "enabled"), &CrowdWorld2D::set_agent_forces_enabled);
        ClassDB::bind_method(D_METHOD("set_agent_continue_at_flow_goal", "agent_handle", "enabled"), &CrowdWorld2D::set_agent_continue_at_flow_goal);
        ClassDB::bind_method(D_METHOD("clear_agent_forces", "agent_handle"), &CrowdWorld2D::clear_agent_forces);
        ClassDB::bind_method(D_METHOD("configure_navigation_behavior", "automatic_bottleneck_gating", "bottleneck_wait_speed_ratio", "flow_goal_stop_delay", "flow_goal_group_delay", "flow_goal_slow_speed_ratio", "zero_flow_retry_seconds", "zero_flow_recovery_speed_ratio", "blocked_motion_retry_seconds"), &CrowdWorld2D::configure_navigation_behavior);
        ClassDB::bind_method(D_METHOD("configure_static_obstacle_avoidance", "strength", "query_padding"), &CrowdWorld2D::configure_static_obstacle_avoidance);
        ClassDB::bind_method(D_METHOD("create_static_obstacle", "position", "radius", "push_strength"), &CrowdWorld2D::create_static_obstacle, DEFVAL(1.0));
        ClassDB::bind_method(D_METHOD("update_static_obstacle", "obstacle_handle", "position", "radius", "push_strength"), &CrowdWorld2D::update_static_obstacle, DEFVAL(1.0));
        ClassDB::bind_method(D_METHOD("remove_static_obstacle", "obstacle_handle"), &CrowdWorld2D::remove_static_obstacle);
        ClassDB::bind_method(D_METHOD("clear_static_obstacles"), &CrowdWorld2D::clear_static_obstacles);
        ClassDB::bind_method(D_METHOD("get_static_obstacle_count"), &CrowdWorld2D::get_static_obstacle_count);
        ClassDB::bind_method(D_METHOD("create_directional_motion_field", "world_origin", "cell_size", "speed", "cells", "directions", "sample_offset", "fallback_radius"), &CrowdWorld2D::create_directional_motion_field, DEFVAL(Vector2()), DEFVAL(0.0));
        ClassDB::bind_method(D_METHOD("update_directional_motion_field", "field_handle", "world_origin", "cell_size", "speed", "cells", "directions", "sample_offset", "fallback_radius"), &CrowdWorld2D::update_directional_motion_field, DEFVAL(Vector2()), DEFVAL(0.0));
        ClassDB::bind_method(D_METHOD("remove_directional_motion_field", "field_handle"), &CrowdWorld2D::remove_directional_motion_field);
        ClassDB::bind_method(D_METHOD("clear_directional_motion_fields"), &CrowdWorld2D::clear_directional_motion_fields);
        ClassDB::bind_method(D_METHOD("follow_directional_motion_field", "agent_handle", "field_handle"), &CrowdWorld2D::follow_directional_motion_field);
        ClassDB::bind_method(D_METHOD("apply_impulse", "agent_handle", "velocity", "delay", "decay_per_second", "control_suppression_seconds", "preserve_navigation", "priority", "apply_agent_resistance"), &CrowdWorld2D::apply_impulse, DEFVAL(false));
        ClassDB::bind_method(D_METHOD("apply_impulse_batch", "agent_handles", "velocities", "delay", "decay_per_second", "control_suppression_seconds", "preserve_navigation", "priority", "apply_agent_resistance"), &CrowdWorld2D::apply_impulse_batch, DEFVAL(false));
        ClassDB::bind_method(D_METHOD("create_external_velocity_source"), &CrowdWorld2D::create_external_velocity_source);
        ClassDB::bind_method(D_METHOD("remove_external_velocity_source", "source_handle"), &CrowdWorld2D::remove_external_velocity_source);
        ClassDB::bind_method(D_METHOD("refresh_external_velocity", "agent_handle", "source_handle", "velocity", "response_seconds", "expiry_seconds"), &CrowdWorld2D::refresh_external_velocity);
        ClassDB::bind_method(D_METHOD("release_external_velocity", "agent_handle", "source_handle"), &CrowdWorld2D::release_external_velocity);
        ClassDB::bind_method(D_METHOD("create_effect_volume", "configuration"), &CrowdWorld2D::create_effect_volume);
        ClassDB::bind_method(D_METHOD("update_effect_volume", "volume_handle", "position", "direction", "follow_offset"), &CrowdWorld2D::update_effect_volume);
        ClassDB::bind_method(D_METHOD("remove_effect_volume", "volume_handle"), &CrowdWorld2D::remove_effect_volume);
        ClassDB::bind_method(D_METHOD("get_effect_volume_count"), &CrowdWorld2D::get_effect_volume_count);
        ClassDB::bind_method(D_METHOD("take_effect_events"), &CrowdWorld2D::take_effect_events);
        ClassDB::bind_method(D_METHOD("configure_bottleneck", "bottleneck_id", "capacity", "reservation_timeout"), &CrowdWorld2D::configure_bottleneck);
        ClassDB::bind_method(D_METHOD("request_bottleneck", "bottleneck_id", "agent_handle", "direction", "priority"), &CrowdWorld2D::request_bottleneck);
        ClassDB::bind_method(D_METHOD("has_bottleneck_access", "bottleneck_id", "agent_handle"), &CrowdWorld2D::has_bottleneck_access);
        ClassDB::bind_method(D_METHOD("release_bottleneck", "bottleneck_id", "agent_handle"), &CrowdWorld2D::release_bottleneck);
        ClassDB::bind_method(D_METHOD("replace_terrain_speed_channel", "cells", "multipliers", "channel"), &CrowdWorld2D::replace_terrain_speed_channel);
        ClassDB::bind_method(D_METHOD("set_terrain_speed_cell", "cell", "multiplier", "channel"), &CrowdWorld2D::set_terrain_speed_cell, DEFVAL(0));
        ClassDB::bind_method(D_METHOD("set_terrain_speed_cells", "cells", "multipliers", "channel"), &CrowdWorld2D::set_terrain_speed_cells, DEFVAL(0));
        ClassDB::bind_method(D_METHOD("clear_terrain_speed_cell", "cell", "channel"), &CrowdWorld2D::clear_terrain_speed_cell, DEFVAL(0));
        ClassDB::bind_method(D_METHOD("clear_terrain_speed_cells", "cells", "channel"), &CrowdWorld2D::clear_terrain_speed_cells, DEFVAL(0));
        ClassDB::bind_method(D_METHOD("clear_terrain_speed_channel", "channel"), &CrowdWorld2D::clear_terrain_speed_channel, DEFVAL(0));
        ClassDB::bind_method(D_METHOD("get_agent_position", "agent_handle"), &CrowdWorld2D::get_agent_position);
        ClassDB::bind_method(D_METHOD("get_agent_velocity", "agent_handle"), &CrowdWorld2D::get_agent_velocity);
        ClassDB::bind_method(D_METHOD("get_agent_route_progress", "agent_handle"), &CrowdWorld2D::get_agent_route_progress);
        ClassDB::bind_method(D_METHOD("get_agent_diagnostics", "agent_handle"), &CrowdWorld2D::get_agent_diagnostics);
        ClassDB::bind_method(D_METHOD("get_active_impulse_states"), &CrowdWorld2D::get_active_impulse_states);
        ClassDB::bind_method(D_METHOD("query_agents_in_circle", "position", "radius", "category_mask", "ignored_agent_handle"), &CrowdWorld2D::query_agents_in_circle, DEFVAL(0));
        ClassDB::bind_method(D_METHOD("query_agents_in_cone", "position", "radius", "direction", "angle_degrees", "category_mask", "ignored_agent_handle"), &CrowdWorld2D::query_agents_in_cone, DEFVAL(0));
        ClassDB::bind_method(D_METHOD("query_agents_in_aabb", "bounds", "category_mask", "ignored_agent_handle"), &CrowdWorld2D::query_agents_in_aabb, DEFVAL(0));
        ClassDB::bind_method(D_METHOD("get_agents_in_navigation_cell", "navigation", "cell"), &CrowdWorld2D::get_agents_in_navigation_cell);
        ClassDB::bind_method(D_METHOD("get_agent_handles"), &CrowdWorld2D::get_agent_handles);
        ClassDB::bind_method(D_METHOD("get_agent_positions"), &CrowdWorld2D::get_agent_positions);
        ClassDB::bind_method(D_METHOD("get_agent_velocities"), &CrowdWorld2D::get_agent_velocities);
        ClassDB::bind_method(D_METHOD("get_agent_count"), &CrowdWorld2D::get_agent_count);
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "automatic_step"), "set_automatic_step", "is_automatic_step_enabled");
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "world_paused"), "set_world_paused", "is_world_paused");
    }

    std::int64_t CrowdWorld2D::encode_handle(ffcore::AgentHandle handle)
    {
        return static_cast<std::int64_t>(
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index);
    }

    ffcore::AgentHandle CrowdWorld2D::decode_handle(std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    std::int64_t CrowdWorld2D::encode_profile_handle(ffcore::ProfileHandle handle)
    {
        return static_cast<std::int64_t>(
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index);
    }

    ffcore::ProfileHandle CrowdWorld2D::decode_profile_handle(std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    std::int64_t CrowdWorld2D::encode_cohort_handle(ffcore::CohortHandle handle)
    {
        return static_cast<std::int64_t>(
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index);
    }

    ffcore::CohortHandle CrowdWorld2D::decode_cohort_handle(std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    ffcore::FlowHandle CrowdWorld2D::decode_flow_handle(std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    std::int64_t CrowdWorld2D::encode_obstacle_handle(ffcore::StaticObstacleHandle handle)
    {
        return static_cast<std::int64_t>(
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index);
    }

    ffcore::StaticObstacleHandle CrowdWorld2D::decode_obstacle_handle(std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    std::int64_t CrowdWorld2D::encode_directional_field_handle(
        ffcore::DirectionalMotionFieldHandle handle)
    {
        return static_cast<std::int64_t>(
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index);
    }

    ffcore::DirectionalMotionFieldHandle CrowdWorld2D::decode_directional_field_handle(
        std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    std::int64_t CrowdWorld2D::encode_effect_volume_handle(ffcore::EffectVolumeHandle handle)
    {
        return static_cast<std::int64_t>(
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index);
    }

    ffcore::EffectVolumeHandle CrowdWorld2D::decode_effect_volume_handle(
        std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    std::int64_t CrowdWorld2D::encode_external_velocity_source_handle(
        ffcore::ExternalVelocitySourceHandle handle)
    {
        return static_cast<std::int64_t>(
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index);
    }

    ffcore::ExternalVelocitySourceHandle CrowdWorld2D::decode_external_velocity_source_handle(
        std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    ffcore::CrowdAgentProfile CrowdWorld2D::make_profile(
        double radius,
        double maximum_speed,
        double acceleration,
        double deceleration,
        double separation_radius,
        double separation_weight,
        double arrival_radius,
        int terrain_speed_channel,
        std::int64_t category_mask)
    {
        ffcore::CrowdAgentProfile profile;
        profile.radius = radius;
        profile.maximum_speed = maximum_speed;
        profile.acceleration = acceleration;
        profile.deceleration = deceleration;
        profile.separation_radius = separation_radius;
        profile.separation_weight = separation_weight;
        profile.arrival_radius = arrival_radius;
        profile.terrain_speed_channel = terrain_speed_channel;
        profile.category_mask = static_cast<std::uint32_t>(category_mask);
        return profile;
    }

    void CrowdWorld2D::_physics_process(double delta)
    {
        if (automatic_step)
            crowd.update(delta);
    }

    void CrowdWorld2D::step(double delta)
    {
        crowd.update(delta);
    }

    void CrowdWorld2D::set_world_paused(bool paused)
    {
        ffcore::CrowdWorldConfig config = crowd.get_config();
        config.paused = paused;
        crowd.set_config(config);
    }

    bool CrowdWorld2D::is_world_paused() const
    {
        return crowd.get_config().paused;
    }

    bool CrowdWorld2D::use_navigation_flow(NavigationWorld2D *navigation)
    {
        if (navigation == nullptr)
            return false;
        ffcore::FlowField field;
        if (!navigation->copy_latest_flow(field))
            return false;
        crowd.set_shared_flow(field);
        return true;
    }

    bool CrowdWorld2D::use_navigation_flow_handle(
        NavigationWorld2D *navigation, std::int64_t encoded_flow)
    {
        if (navigation == nullptr)
            return false;
        ffcore::FlowField field;
        if (!navigation->copy_flow(decode_flow_handle(encoded_flow), field))
            return false;
        crowd.set_shared_flow(field);
        return true;
    }

    bool CrowdWorld2D::install_navigation_flow(
        NavigationWorld2D *navigation,
        std::int64_t encoded_flow)
    {
        if (navigation == nullptr)
            return false;
        const ffcore::FlowHandle flow_handle = decode_flow_handle(encoded_flow);
        ffcore::FlowField field;
        return navigation->copy_flow(flow_handle, field) && crowd.install_flow(flow_handle, field);
    }

    bool CrowdWorld2D::remove_navigation_flow(std::int64_t encoded_flow)
    {
        return crowd.remove_flow(decode_flow_handle(encoded_flow));
    }

    void CrowdWorld2D::configure_default_profile(
        double radius,
        double maximum_speed,
        double acceleration,
        double deceleration,
        double separation_radius,
        double separation_weight,
        double arrival_radius,
        int terrain_speed_channel,
        std::int64_t category_mask)
    {
        ffcore::CrowdWorldConfig config = crowd.get_config();
        config.default_agent_profile = make_profile(
            radius, maximum_speed, acceleration, deceleration, separation_radius,
            separation_weight, arrival_radius, terrain_speed_channel, category_mask);
        crowd.set_config(config);
    }

    std::int64_t CrowdWorld2D::create_profile(
        double radius,
        double maximum_speed,
        double acceleration,
        double deceleration,
        double separation_radius,
        double separation_weight,
        double arrival_radius,
        int terrain_speed_channel,
        std::int64_t category_mask)
    {
        return encode_profile_handle(crowd.create_profile(make_profile(
            radius, maximum_speed, acceleration, deceleration, separation_radius,
            separation_weight, arrival_radius, terrain_speed_channel, category_mask)));
    }

    bool CrowdWorld2D::update_profile(
        std::int64_t encoded_profile,
        double radius,
        double maximum_speed,
        double acceleration,
        double deceleration,
        double separation_radius,
        double separation_weight,
        double arrival_radius,
        int terrain_speed_channel,
        std::int64_t category_mask)
    {
        return crowd.update_profile(decode_profile_handle(encoded_profile), make_profile(
            radius, maximum_speed, acceleration, deceleration, separation_radius,
            separation_weight, arrival_radius, terrain_speed_channel, category_mask));
    }

    bool CrowdWorld2D::remove_profile(std::int64_t encoded_profile)
    {
        return crowd.remove_profile(decode_profile_handle(encoded_profile));
    }

    std::int64_t CrowdWorld2D::add_agent(
        Vector2 position,
        double radius,
        double maximum_speed,
        double separation_radius,
        double separation_weight)
    {
        ffcore::CrowdAgentProfile profile;
        profile.radius = radius;
        profile.maximum_speed = maximum_speed;
        profile.separation_radius = separation_radius;
        profile.separation_weight = separation_weight;
        return encode_handle(crowd.add_agent({position.x, position.y}, profile));
    }

    bool CrowdWorld2D::remove_agent(std::int64_t agent_handle)
    {
        return crowd.remove_agent(decode_handle(agent_handle));
    }

    std::int64_t CrowdWorld2D::add_agent_with_profile(
        Vector2 position,
        std::int64_t encoded_profile)
    {
        return encode_handle(crowd.add_agent(
            {position.x, position.y}, decode_profile_handle(encoded_profile)));
    }

    bool CrowdWorld2D::set_agent_profile(
        std::int64_t agent_handle,
        std::int64_t profile_handle)
    {
        return crowd.set_agent_profile(
            decode_handle(agent_handle), decode_profile_handle(profile_handle));
    }

    bool CrowdWorld2D::set_agent_position(
        std::int64_t agent_handle, Vector2 position, bool clear_velocity)
    {
        return crowd.set_agent_position(
            decode_handle(agent_handle), {position.x, position.y}, clear_velocity);
    }

    bool CrowdWorld2D::set_agent_motion_limits(
        std::int64_t agent_handle, double maximum_speed,
        double acceleration, double deceleration)
    {
        return crowd.set_agent_motion_limits(
            decode_handle(agent_handle), maximum_speed, acceleration, deceleration);
    }

    bool CrowdWorld2D::set_agent_collision_offset(
        std::int64_t agent_handle, Vector2 offset)
    {
        return crowd.set_agent_collision_offset(
            decode_handle(agent_handle), {offset.x, offset.y});
    }

    bool CrowdWorld2D::set_agent_avoidance_profile(
        std::int64_t agent_handle, double push_strength, double resistance)
    {
        return crowd.set_agent_avoidance_profile(
            decode_handle(agent_handle), push_strength, resistance);
    }

    bool CrowdWorld2D::set_agent_impulse_resistance(
        std::int64_t agent_handle, double resistance)
    {
        return crowd.set_agent_impulse_resistance(
            decode_handle(agent_handle), resistance);
    }

    bool CrowdWorld2D::set_agent_query_shape(
        std::int64_t agent_handle, Vector2 offset, Vector2 half_extents)
    {
        return crowd.set_agent_query_shape(
            decode_handle(agent_handle), {offset.x, offset.y},
            {half_extents.x, half_extents.y});
    }

    std::int64_t CrowdWorld2D::create_cohort()
    {
        return encode_cohort_handle(crowd.create_cohort());
    }

    bool CrowdWorld2D::remove_cohort(std::int64_t cohort_handle)
    {
        return crowd.remove_cohort(decode_cohort_handle(cohort_handle));
    }

    bool CrowdWorld2D::assign_agent_to_cohort(
        std::int64_t agent_handle,
        std::int64_t cohort_handle)
    {
        return crowd.assign_agent_to_cohort(
            decode_handle(agent_handle), decode_cohort_handle(cohort_handle));
    }

    bool CrowdWorld2D::remove_agent_from_cohort(std::int64_t agent_handle)
    {
        return crowd.remove_agent_from_cohort(decode_handle(agent_handle));
    }

    bool CrowdWorld2D::assign_cohort_flow(
        std::int64_t cohort_handle,
        std::int64_t flow_handle)
    {
        return crowd.assign_cohort_flow(
            decode_cohort_handle(cohort_handle), decode_flow_handle(flow_handle));
    }

    int CrowdWorld2D::get_cohort_member_count(std::int64_t cohort_handle) const
    {
        return static_cast<int>(crowd.cohort_member_count(decode_cohort_handle(cohort_handle)));
    }

    bool CrowdWorld2D::follow_flow(std::int64_t agent_handle)
    {
        return crowd.follow_flow(decode_handle(agent_handle));
    }

    bool CrowdWorld2D::follow_flow_handle(
        std::int64_t agent_handle,
        std::int64_t flow_handle)
    {
        return crowd.follow_flow(decode_handle(agent_handle), decode_flow_handle(flow_handle));
    }

    bool CrowdWorld2D::follow_path(
        std::int64_t agent_handle,
        const PackedVector2Array &world_points)
    {
        std::vector<ffcore::Vec2> points;
        points.reserve(world_points.size());
        for (int index = 0; index < world_points.size(); ++index)
            points.push_back({world_points[index].x, world_points[index].y});
        return crowd.follow_path(decode_handle(agent_handle), points);
    }

    bool CrowdWorld2D::set_manual_direction(std::int64_t agent_handle, Vector2 direction)
    {
        return crowd.set_manual_direction(decode_handle(agent_handle), {direction.x, direction.y});
    }

    bool CrowdWorld2D::stop_navigation(std::int64_t agent_handle)
    {
        return crowd.stop_navigation(decode_handle(agent_handle));
    }

    bool CrowdWorld2D::set_agent_paused(std::int64_t agent_handle, bool paused)
    {
        return crowd.set_paused(decode_handle(agent_handle), paused);
    }

    bool CrowdWorld2D::set_agent_pause_allows_impulses(
        std::int64_t agent_handle, bool enabled)
    {
        return crowd.set_pause_allows_impulses(decode_handle(agent_handle), enabled);
    }

    bool CrowdWorld2D::set_agent_navigation_suspended(
        std::int64_t agent_handle, bool suspended)
    {
        return crowd.set_navigation_suspended(decode_handle(agent_handle), suspended);
    }

    bool CrowdWorld2D::set_agent_forces_enabled(
        std::int64_t agent_handle, bool enabled)
    {
        return crowd.set_forces_enabled(decode_handle(agent_handle), enabled);
    }

    bool CrowdWorld2D::set_agent_continue_at_flow_goal(
        std::int64_t agent_handle, bool enabled)
    {
        return crowd.set_continue_at_flow_goal(decode_handle(agent_handle), enabled);
    }

    void CrowdWorld2D::clear_agent_forces(std::int64_t agent_handle)
    {
        crowd.clear_agent_forces(decode_handle(agent_handle));
    }

    void CrowdWorld2D::configure_navigation_behavior(
        bool automatic_bottleneck_gating, double bottleneck_wait_speed_ratio,
        double flow_goal_stop_delay, double flow_goal_group_delay,
        double flow_goal_slow_speed_ratio, double zero_flow_retry_seconds,
        double zero_flow_recovery_speed_ratio, double blocked_motion_retry_seconds)
    {
        ffcore::CrowdWorldConfig config = crowd.get_config();
        config.automatic_bottleneck_gating = automatic_bottleneck_gating;
        config.bottleneck_wait_speed_ratio = bottleneck_wait_speed_ratio;
        config.flow_goal_stop_delay = flow_goal_stop_delay;
        config.flow_goal_group_delay = flow_goal_group_delay;
        config.flow_goal_slow_speed_ratio = flow_goal_slow_speed_ratio;
        config.zero_flow_retry_seconds = zero_flow_retry_seconds;
        config.zero_flow_recovery_speed_ratio = zero_flow_recovery_speed_ratio;
        config.blocked_motion_retry_seconds = blocked_motion_retry_seconds;
        crowd.set_config(config);
    }

    void CrowdWorld2D::configure_bottleneck(
        std::int64_t bottleneck_id,
        int capacity,
        double reservation_timeout)
    {
        ffcore::BottleneckTrafficConfig config;
        config.capacity = static_cast<std::uint32_t>(std::max(1, capacity));
        config.reservation_timeout = reservation_timeout;
        crowd.configure_bottleneck(static_cast<std::uint64_t>(bottleneck_id), config);
    }

    bool CrowdWorld2D::request_bottleneck(
        std::int64_t bottleneck_id,
        std::int64_t agent_handle,
        int direction,
        int priority)
    {
        const ffcore::TrafficDirection traffic_direction = direction < 0
            ? ffcore::TrafficDirection::Reverse : ffcore::TrafficDirection::Forward;
        return crowd.request_bottleneck(
            static_cast<std::uint64_t>(bottleneck_id),
            decode_handle(agent_handle), traffic_direction, priority);
    }

    bool CrowdWorld2D::has_bottleneck_access(
        std::int64_t bottleneck_id,
        std::int64_t agent_handle) const
    {
        return crowd.has_bottleneck_access(
            static_cast<std::uint64_t>(bottleneck_id), decode_handle(agent_handle));
    }

    void CrowdWorld2D::release_bottleneck(
        std::int64_t bottleneck_id,
        std::int64_t agent_handle)
    {
        crowd.release_bottleneck(
            static_cast<std::uint64_t>(bottleneck_id), decode_handle(agent_handle));
    }

    void CrowdWorld2D::replace_terrain_speed_channel(
        const PackedVector2Array &cells,
        const PackedFloat64Array &multipliers,
        int channel)
    {
        std::vector<ffcore::Vec2i> converted_cells;
        std::vector<double> converted_multipliers;
        const int count = std::min(cells.size(), multipliers.size());
        converted_cells.reserve(count);
        converted_multipliers.reserve(count);
        for (int index = 0; index < count; ++index)
        {
            converted_cells.push_back({static_cast<int>(cells[index].x), static_cast<int>(cells[index].y)});
            converted_multipliers.push_back(multipliers[index]);
        }
        crowd.terrain_speed_grid().replace_channel(converted_cells, converted_multipliers, channel);
    }

    Vector2 CrowdWorld2D::get_agent_position(std::int64_t agent_handle) const
    {
        const ffcore::CrowdAgentState *agent = crowd.get_agent(decode_handle(agent_handle));
        return agent == nullptr ? Vector2() : Vector2(agent->position.x, agent->position.y);
    }

    Vector2 CrowdWorld2D::get_agent_velocity(std::int64_t agent_handle) const
    {
        const ffcore::CrowdAgentState *agent = crowd.get_agent(decode_handle(agent_handle));
        return agent == nullptr ? Vector2() : Vector2(agent->velocity.x, agent->velocity.y);
    }

    int CrowdWorld2D::get_agent_route_progress(std::int64_t agent_handle) const
    {
        const ffcore::CrowdAgentState *agent = crowd.get_agent(decode_handle(agent_handle));
        return agent == nullptr ? static_cast<int>(ffcore::RouteProgress::Failed)
                                : static_cast<int>(agent->route_progress);
    }

    PackedInt64Array CrowdWorld2D::get_agent_handles() const
    {
        const std::vector<ffcore::AgentHandle> handles = crowd.active_agents();
        PackedInt64Array result;
        result.resize(static_cast<int>(handles.size()));
        for (int index = 0; index < static_cast<int>(handles.size()); ++index)
            result.set(index, encode_handle(handles[index]));
        return result;
    }

    PackedVector2Array CrowdWorld2D::get_agent_positions() const
    {
        const std::vector<ffcore::AgentHandle> handles = crowd.active_agents();
        PackedVector2Array result;
        result.resize(static_cast<int>(handles.size()));
        for (int index = 0; index < static_cast<int>(handles.size()); ++index)
        {
            const ffcore::CrowdAgentState *agent = crowd.get_agent(handles[index]);
            result.set(index, Vector2(agent->position.x, agent->position.y));
        }
        return result;
    }

    PackedVector2Array CrowdWorld2D::get_agent_velocities() const
    {
        const std::vector<ffcore::AgentHandle> handles = crowd.active_agents();
        PackedVector2Array result;
        result.resize(static_cast<int>(handles.size()));
        for (int index = 0; index < static_cast<int>(handles.size()); ++index)
        {
            const ffcore::CrowdAgentState *agent = crowd.get_agent(handles[index]);
            result.set(index, Vector2(agent->velocity.x, agent->velocity.y));
        }
        return result;
    }

    int CrowdWorld2D::get_agent_count() const
    {
        return static_cast<int>(crowd.size());
    }
} // namespace godot
