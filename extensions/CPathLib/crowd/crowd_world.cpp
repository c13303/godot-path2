#include "crowd_world.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <unordered_map>

namespace ffcore
{
    std::uint64_t CrowdWorld::key(AgentHandle handle)
    {
        return (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index;
    }

    std::uint64_t CrowdWorld::key(FlowHandle handle)
    {
        return (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index;
    }

    void CrowdWorld::set_config(const CrowdWorldConfig &new_config)
    {
        config = new_config;
        config.default_agent_profile = CrowdProfileStore::sanitize(new_config.default_agent_profile);
    }

    ProfileHandle CrowdWorld::create_profile(const CrowdAgentProfile &profile)
    {
        return profiles.create(profile);
    }

    bool CrowdWorld::update_profile(ProfileHandle handle, const CrowdAgentProfile &profile)
    {
        return profiles.update(handle, profile);
    }

    bool CrowdWorld::remove_profile(ProfileHandle handle)
    {
        return profiles.remove(handle);
    }

    const CrowdAgentProfile *CrowdWorld::get_profile(ProfileHandle handle) const
    {
        return profiles.get(handle);
    }

    AgentHandle CrowdWorld::add_agent(const Vec2 &position)
    {
        return agents.create(position, config.default_agent_profile);
    }

    AgentHandle CrowdWorld::add_agent(const Vec2 &position, const CrowdAgentProfile &profile)
    {
        return agents.create(position, profile);
    }

    AgentHandle CrowdWorld::add_agent(const Vec2 &position, ProfileHandle profile_handle)
    {
        const CrowdAgentProfile *profile = profiles.get(profile_handle);
        if (profile == nullptr)
            return {};
        const AgentHandle handle = agents.create(position, *profile);
        agents.get(handle)->profile_handle = profile_handle;
        return handle;
    }

    bool CrowdWorld::remove_agent(AgentHandle handle)
    {
        if (agents.get(handle) == nullptr)
            return false;
        impulses.remove(handle);
        traffic.remove_agent(key(handle));
        remove_agent_from_cohort(handle);
        return agents.remove(handle);
    }

    bool CrowdWorld::set_agent_profile(AgentHandle agent_handle, ProfileHandle profile_handle)
    {
        CrowdAgentState *agent = agents.get(agent_handle);
        const CrowdAgentProfile *profile = profiles.get(profile_handle);
        if (agent == nullptr || profile == nullptr)
            return false;
        agent->profile_handle = profile_handle;
        agent->profile = *profile;
        return true;
    }

    CohortHandle CrowdWorld::create_cohort()
    {
        return cohorts.create();
    }

    bool CrowdWorld::remove_cohort(CohortHandle handle)
    {
        return cohorts.remove(handle);
    }

    bool CrowdWorld::assign_agent_to_cohort(AgentHandle agent, CohortHandle cohort)
    {
        if (agents.get(agent) == nullptr || cohorts.get(cohort) == nullptr)
            return false;
        remove_agent_from_cohort(agent);
        if (!cohorts.add_member(cohort, agent))
            return false;
        const CohortState *state = cohorts.get(cohort);
        if (state->flow_handle.is_valid())
            return follow_flow(agent, state->flow_handle);
        return true;
    }

    bool CrowdWorld::remove_agent_from_cohort(AgentHandle agent)
    {
        const CohortHandle cohort = cohorts.find_cohort(agent);
        if (!cohort.is_valid())
            return false;
        return cohorts.remove_member(cohort, agent);
    }

    bool CrowdWorld::assign_cohort_flow(CohortHandle cohort_handle, FlowHandle flow_handle)
    {
        CohortState *cohort = cohorts.get(cohort_handle);
        if (cohort == nullptr || installed_flows.find(key(flow_handle)) == installed_flows.end())
            return false;
        cohort->flow_handle = flow_handle;
        for (AgentHandle member : cohort->members)
        {
            if (!follow_flow(member, flow_handle))
                return false;
        }
        return true;
    }

    std::size_t CrowdWorld::cohort_member_count(CohortHandle cohort) const
    {
        const CohortState *state = cohorts.get(cohort);
        return state == nullptr ? 0 : state->members.size();
    }

    bool CrowdWorld::install_flow(FlowHandle handle, const FlowField &flow)
    {
        if (!handle.is_valid() || !flow.is_ready())
            return false;
        installed_flows[key(handle)].copy_from(flow);
        return true;
    }

    bool CrowdWorld::remove_flow(FlowHandle handle)
    {
        if (installed_flows.erase(key(handle)) == 0)
            return false;
        for (AgentHandle agent_handle : agents.active_handles())
        {
            CrowdAgentState *agent = agents.get(agent_handle);
            if (agent->flow_handle == handle)
            {
                agent->flow_handle = {};
                agent->navigation_source = NavigationSource::None;
                agent->route_progress = RouteProgress::Failed;
            }
        }
        cohorts.clear_flow(handle);
        if (default_flow_handle == handle)
            default_flow_handle = {};
        return true;
    }

    void CrowdWorld::set_shared_flow(const FlowField &flow)
    {
        if (!default_flow_handle.is_valid())
            default_flow_handle = {
                std::numeric_limits<std::uint32_t>::max(),
                std::numeric_limits<std::uint32_t>::max()};
        install_flow(default_flow_handle, flow);
    }

    void CrowdWorld::clear_shared_flow()
    {
        if (default_flow_handle.is_valid())
            remove_flow(default_flow_handle);
    }

    bool CrowdWorld::follow_flow(AgentHandle handle)
    {
        if (!default_flow_handle.is_valid())
            return false;
        return follow_flow(handle, default_flow_handle);
    }

    bool CrowdWorld::follow_flow(AgentHandle handle, FlowHandle flow)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr || installed_flows.find(key(flow)) == installed_flows.end())
            return false;
        agent->flow_handle = flow;
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
        agent->flow_handle = {};
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
        agent->flow_handle = {};
        agent->route_progress = RouteProgress::Following;
        return true;
    }

    bool CrowdWorld::stop_navigation(AgentHandle handle)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->navigation_source = NavigationSource::None;
        agent->flow_handle = {};
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
        return traffic.request(bottleneck_id, key(handle), direction, priority);
    }

    bool CrowdWorld::has_bottleneck_access(
        std::uint64_t bottleneck_id,
        AgentHandle handle) const
    {
        return agents.get(handle) != nullptr && traffic.is_granted(bottleneck_id, key(handle));
    }

    void CrowdWorld::release_bottleneck(std::uint64_t bottleneck_id, AgentHandle handle)
    {
        traffic.release(bottleneck_id, key(handle));
    }

    Vec2 CrowdWorld::approach(const Vec2 &current, const Vec2 &target, double maximum_change)
    {
        const Vec2 difference = target - current;
        const double distance = difference.length();
        if (distance <= maximum_change || distance <= 1e-8)
            return target;
        return current + difference * (maximum_change / distance);
    }

    const FlowField *CrowdWorld::flow_for(const CrowdAgentState &agent) const
    {
        const FlowHandle handle = agent.flow_handle.is_valid() ? agent.flow_handle : default_flow_handle;
        const auto existing = installed_flows.find(key(handle));
        return existing == installed_flows.end() ? nullptr : &existing->second;
    }

    Vec2 CrowdWorld::resolve_motion(
        const CrowdAgentState &agent,
        const Vec2 &candidate,
        const FlowField *flow) const
    {
        if (flow == nullptr || flow->is_cell_physics_passable(flow->world_to_cell(candidate)))
            return candidate;
        const Vec2 x_only(candidate.x, agent.position.y);
        if (flow->is_cell_physics_passable(flow->world_to_cell(x_only)))
            return x_only;
        const Vec2 y_only(agent.position.x, candidate.y);
        if (flow->is_cell_physics_passable(flow->world_to_cell(y_only)))
            return y_only;
        return agent.position;
    }

    void CrowdWorld::update(double delta)
    {
        if (!std::isfinite(delta) || delta <= 0.0 || config.paused)
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
            const FlowField *flow = flow_for(*agent);
            const Vec2 navigation = SteeringSolver::navigation_direction(
                *agent, flow);
            const Vec2 separation = SteeringSolver::separation(
                *agent, agents, spatial, handles_by_index);
            Vec2 desired_direction = navigation + separation;
            if (!desired_direction.is_zero())
                desired_direction = desired_direction.normalized();

            double terrain_multiplier = 1.0;
            if (flow != nullptr)
                terrain_multiplier = terrain_speeds.multiplier_at(
                    flow->world_to_cell(agent->position), agent->profile.terrain_speed_channel);
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
            const Vec2 resolved = resolve_motion(
                *agent, agent->position + total_velocity * delta, flow);
            if ((resolved - agent->position).length_squared() < 1e-12 && !total_velocity.is_zero())
                agent->velocity = {};
            agent->position = resolved;
        }
    }
} // namespace ffcore
