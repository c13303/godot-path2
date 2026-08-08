#include "crowd_world.h"

#include <algorithm>
#include <cmath>
#include <unordered_map>

namespace ffcore
{
    AgentHandle CrowdWorld::add_agent(const Vec2 &position, const CrowdAgentProfile &profile)
    {
        return agents.create(position, profile);
    }

    bool CrowdWorld::remove_agent(AgentHandle handle)
    {
        impulses.remove(handle);
        traffic.remove_agent((static_cast<std::uint64_t>(handle.generation) << 32) | handle.index);
        return agents.remove(handle);
    }

    void CrowdWorld::set_shared_flow(const FlowField &flow)
    {
        shared_flow.copy_from(flow);
        has_shared_flow = flow.is_ready();
    }

    void CrowdWorld::clear_shared_flow()
    {
        shared_flow.clear();
        has_shared_flow = false;
    }

    bool CrowdWorld::follow_flow(AgentHandle handle)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr || !has_shared_flow)
            return false;
        agent->navigation_source = NavigationSource::FlowField;
        agent->route_progress = RouteProgress::Following;
        return true;
    }

    bool CrowdWorld::follow_path(AgentHandle handle, const std::vector<Vec2> &world_points)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr || world_points.empty())
            return false;
        agent->path = world_points;
        agent->path_index = 0;
        agent->navigation_source = NavigationSource::Path;
        agent->route_progress = RouteProgress::Following;
        return true;
    }

    bool CrowdWorld::set_manual_direction(AgentHandle handle, const Vec2 &direction)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->manual_direction = direction.normalized();
        agent->navigation_source = NavigationSource::Manual;
        agent->route_progress = RouteProgress::Following;
        return true;
    }

    bool CrowdWorld::stop_navigation(AgentHandle handle)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->navigation_source = NavigationSource::None;
        agent->route_progress = RouteProgress::Idle;
        agent->path.clear();
        agent->path_index = 0;
        return true;
    }

    bool CrowdWorld::set_paused(AgentHandle handle, bool paused)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->paused = paused;
        return true;
    }

    void CrowdWorld::apply_impulse(AgentHandle handle, const ImpulseRequest &request)
    {
        if (agents.get(handle) != nullptr)
            impulses.apply(handle, request);
    }

    bool CrowdWorld::refresh_external_velocity(
        AgentHandle handle,
        int source_id,
        const Vec2 &velocity,
        double response_seconds,
        double expiry_seconds)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->external_velocity.refresh_source(source_id, velocity, response_seconds, expiry_seconds);
        return true;
    }

    bool CrowdWorld::release_external_velocity(AgentHandle handle, int source_id)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->external_velocity.release_source(source_id);
        return true;
    }

    void CrowdWorld::configure_bottleneck(
        std::uint64_t bottleneck_id,
        const BottleneckTrafficConfig &config)
    {
        traffic.configure(bottleneck_id, config);
    }

    bool CrowdWorld::request_bottleneck(
        std::uint64_t bottleneck_id,
        AgentHandle handle,
        TrafficDirection direction,
        int priority)
    {
        if (agents.get(handle) == nullptr)
            return false;
        const std::uint64_t agent_id =
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index;
        return traffic.request(bottleneck_id, agent_id, direction, priority);
    }

    bool CrowdWorld::has_bottleneck_access(
        std::uint64_t bottleneck_id,
        AgentHandle handle) const
    {
        const std::uint64_t agent_id =
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index;
        return agents.get(handle) != nullptr && traffic.is_granted(bottleneck_id, agent_id);
    }

    void CrowdWorld::release_bottleneck(std::uint64_t bottleneck_id, AgentHandle handle)
    {
        const std::uint64_t agent_id =
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index;
        traffic.release(bottleneck_id, agent_id);
    }

    Vec2 CrowdWorld::approach(const Vec2 &current, const Vec2 &target, double maximum_change)
    {
        const Vec2 difference = target - current;
        const double distance = difference.length();
        if (distance <= maximum_change || distance <= 1e-8)
            return target;
        return current + difference * (maximum_change / distance);
    }

    Vec2 CrowdWorld::resolve_motion(const CrowdAgentState &agent, const Vec2 &candidate) const
    {
        if (!has_shared_flow || shared_flow.is_cell_physics_passable(shared_flow.world_to_cell(candidate)))
            return candidate;
        const Vec2 x_only(candidate.x, agent.position.y);
        if (shared_flow.is_cell_physics_passable(shared_flow.world_to_cell(x_only)))
            return x_only;
        const Vec2 y_only(agent.position.x, candidate.y);
        if (shared_flow.is_cell_physics_passable(shared_flow.world_to_cell(y_only)))
            return y_only;
        return agent.position;
    }

    void CrowdWorld::update(double delta)
    {
        if (!std::isfinite(delta) || delta <= 0.0)
            return;
        const std::vector<AgentHandle> handles = agents.active_handles();
        spatial.clear();
        std::unordered_map<int, AgentHandle> handles_by_index;
        for (AgentHandle handle : handles)
        {
            const CrowdAgentState *agent = agents.get(handle);
            spatial.insert(static_cast<int>(handle.index), agent->position);
            handles_by_index[static_cast<int>(handle.index)] = handle;
        }

        impulses.update(delta);
        traffic.update(delta);
        for (AgentHandle handle : handles)
        {
            CrowdAgentState *agent = agents.get(handle);
            agent->external_velocity.update(delta);
            const Vec2 navigation = SteeringSolver::navigation_direction(
                *agent, has_shared_flow ? &shared_flow : nullptr);
            const Vec2 separation = SteeringSolver::separation(
                *agent, agents, spatial, handles_by_index);
            Vec2 desired_direction = navigation + separation;
            if (!desired_direction.is_zero())
                desired_direction = desired_direction.normalized();

            double terrain_multiplier = 1.0;
            if (has_shared_flow)
                terrain_multiplier = terrain_speeds.multiplier_at(
                    shared_flow.world_to_cell(agent->position), agent->profile.terrain_speed_channel);
            const Vec2 desired_velocity = desired_direction *
                (agent->profile.maximum_speed * terrain_multiplier * impulses.navigation_control(handle));
            const double rate = desired_velocity.length_squared() > agent->velocity.length_squared()
                ? agent->profile.acceleration : agent->profile.deceleration;
            agent->velocity = approach(agent->velocity, desired_velocity, rate * delta);

            Vec2 total_velocity;
            if (!agent->paused)
            {
                total_velocity = agent->velocity;
                total_velocity += impulses.velocity(handle);
                total_velocity += agent->external_velocity.current_velocity();
            }
            const Vec2 resolved = resolve_motion(*agent, agent->position + total_velocity * delta);
            if ((resolved - agent->position).length_squared() < 1e-12 && !total_velocity.is_zero())
                agent->velocity = {};
            agent->position = resolved;
        }
    }
} // namespace ffcore
