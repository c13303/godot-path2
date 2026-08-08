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
        ClassDB::bind_method(D_METHOD("use_navigation_flow", "navigation"), &CrowdWorld2D::use_navigation_flow);
        ClassDB::bind_method(D_METHOD("add_agent", "position", "radius", "maximum_speed", "separation_radius", "separation_weight"), &CrowdWorld2D::add_agent);
        ClassDB::bind_method(D_METHOD("remove_agent", "agent_handle"), &CrowdWorld2D::remove_agent);
        ClassDB::bind_method(D_METHOD("follow_flow", "agent_handle"), &CrowdWorld2D::follow_flow);
        ClassDB::bind_method(D_METHOD("follow_path", "agent_handle", "world_points"), &CrowdWorld2D::follow_path);
        ClassDB::bind_method(D_METHOD("set_manual_direction", "agent_handle", "direction"), &CrowdWorld2D::set_manual_direction);
        ClassDB::bind_method(D_METHOD("stop_navigation", "agent_handle"), &CrowdWorld2D::stop_navigation);
        ClassDB::bind_method(D_METHOD("set_agent_paused", "agent_handle", "paused"), &CrowdWorld2D::set_agent_paused);
        ClassDB::bind_method(D_METHOD("apply_impulse", "agent_handle", "velocity", "delay", "decay_per_second", "control_suppression_seconds", "preserve_navigation", "priority"), &CrowdWorld2D::apply_impulse);
        ClassDB::bind_method(D_METHOD("refresh_external_velocity", "agent_handle", "source_id", "velocity", "response_seconds", "expiry_seconds"), &CrowdWorld2D::refresh_external_velocity);
        ClassDB::bind_method(D_METHOD("release_external_velocity", "agent_handle", "source_id"), &CrowdWorld2D::release_external_velocity);
        ClassDB::bind_method(D_METHOD("configure_bottleneck", "bottleneck_id", "capacity", "reservation_timeout"), &CrowdWorld2D::configure_bottleneck);
        ClassDB::bind_method(D_METHOD("request_bottleneck", "bottleneck_id", "agent_handle", "direction", "priority"), &CrowdWorld2D::request_bottleneck);
        ClassDB::bind_method(D_METHOD("has_bottleneck_access", "bottleneck_id", "agent_handle"), &CrowdWorld2D::has_bottleneck_access);
        ClassDB::bind_method(D_METHOD("release_bottleneck", "bottleneck_id", "agent_handle"), &CrowdWorld2D::release_bottleneck);
        ClassDB::bind_method(D_METHOD("replace_terrain_speed_channel", "cells", "multipliers", "channel"), &CrowdWorld2D::replace_terrain_speed_channel);
        ClassDB::bind_method(D_METHOD("get_agent_position", "agent_handle"), &CrowdWorld2D::get_agent_position);
        ClassDB::bind_method(D_METHOD("get_agent_velocity", "agent_handle"), &CrowdWorld2D::get_agent_velocity);
        ClassDB::bind_method(D_METHOD("get_agent_route_progress", "agent_handle"), &CrowdWorld2D::get_agent_route_progress);
        ClassDB::bind_method(D_METHOD("get_agent_handles"), &CrowdWorld2D::get_agent_handles);
        ClassDB::bind_method(D_METHOD("get_agent_positions"), &CrowdWorld2D::get_agent_positions);
        ClassDB::bind_method(D_METHOD("get_agent_velocities"), &CrowdWorld2D::get_agent_velocities);
        ClassDB::bind_method(D_METHOD("get_agent_count"), &CrowdWorld2D::get_agent_count);
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "automatic_step"), "set_automatic_step", "is_automatic_step_enabled");
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

    void CrowdWorld2D::_physics_process(double delta)
    {
        if (automatic_step)
            crowd.update(delta);
    }

    void CrowdWorld2D::step(double delta)
    {
        crowd.update(delta);
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

    bool CrowdWorld2D::follow_flow(std::int64_t agent_handle)
    {
        return crowd.follow_flow(decode_handle(agent_handle));
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

    void CrowdWorld2D::apply_impulse(
        std::int64_t agent_handle,
        Vector2 velocity,
        double delay,
        double decay_per_second,
        double control_suppression_seconds,
        bool preserve_navigation,
        int priority)
    {
        ffcore::ImpulseRequest request;
        request.velocity = {velocity.x, velocity.y};
        request.delay = delay;
        request.decay_per_second = decay_per_second;
        request.control_suppression_seconds = control_suppression_seconds;
        request.preserve_navigation = preserve_navigation;
        request.priority = priority;
        crowd.apply_impulse(decode_handle(agent_handle), request);
    }

    bool CrowdWorld2D::refresh_external_velocity(
        std::int64_t agent_handle,
        int source_id,
        Vector2 velocity,
        double response_seconds,
        double expiry_seconds)
    {
        return crowd.refresh_external_velocity(
            decode_handle(agent_handle), source_id, {velocity.x, velocity.y},
            response_seconds, expiry_seconds);
    }

    bool CrowdWorld2D::release_external_velocity(std::int64_t agent_handle, int source_id)
    {
        return crowd.release_external_velocity(decode_handle(agent_handle), source_id);
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
