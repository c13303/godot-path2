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
        config.static_obstacle_query_padding =
            std::isfinite(config.static_obstacle_query_padding)
            ? std::max(0.0, config.static_obstacle_query_padding) : 0.0;
        config.static_obstacle_repulsion_strength =
            std::isfinite(config.static_obstacle_repulsion_strength)
            ? std::max(0.0, config.static_obstacle_repulsion_strength) : 1.0;
        config.interactions.right_of_way_push_speed =
            std::isfinite(config.interactions.right_of_way_push_speed)
            ? std::max(0.0, config.interactions.right_of_way_push_speed) : 216.0;
        config.interactions.right_of_way_cooldown =
            std::isfinite(config.interactions.right_of_way_cooldown)
            ? std::max(0.0, config.interactions.right_of_way_cooldown) : 0.18;
        config.interactions.right_of_way_control_suppression =
            std::isfinite(config.interactions.right_of_way_control_suppression)
            ? std::max(0.0, config.interactions.right_of_way_control_suppression) : 0.18;
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
        const AgentHandle handle = agents.create(position, config.default_agent_profile);
        spatial.insert(static_cast<int>(handle.index), position);
        maximum_agent_radius = std::max(
            maximum_agent_radius, agents.get(handle)->profile.radius);
        return handle;
    }

    AgentHandle CrowdWorld::add_agent(const Vec2 &position, const CrowdAgentProfile &profile)
    {
        const AgentHandle handle = agents.create(position, profile);
        spatial.insert(static_cast<int>(handle.index), position);
        maximum_agent_radius = std::max(
            maximum_agent_radius, agents.get(handle)->profile.radius);
        return handle;
    }

    AgentHandle CrowdWorld::add_agent(const Vec2 &position, ProfileHandle profile_handle)
    {
        const CrowdAgentProfile *profile = profiles.get(profile_handle);
        if (profile == nullptr)
            return {};
        const AgentHandle handle = agents.create(position, *profile);
        agents.get(handle)->profile_handle = profile_handle;
        spatial.insert(static_cast<int>(handle.index), position);
        maximum_agent_radius = std::max(maximum_agent_radius, profile->radius);
        return handle;
    }

    bool CrowdWorld::remove_agent(AgentHandle handle)
    {
        if (agents.get(handle) == nullptr)
            return false;
        impulses.remove(handle);
        effect_volumes.remove_agent(handle);
        traffic.remove_agent(key(handle));
        interactions.remove_agent(handle);
        remove_agent_from_cohort(handle);
        spatial.remove(static_cast<int>(handle.index));
        const bool removed = agents.remove(handle);
        recompute_maximum_agent_radius();
        return removed;
    }

    bool CrowdWorld::set_agent_profile(AgentHandle agent_handle, ProfileHandle profile_handle)
    {
        CrowdAgentState *agent = agents.get(agent_handle);
        const CrowdAgentProfile *profile = profiles.get(profile_handle);
        if (agent == nullptr || profile == nullptr)
            return false;
        agent->profile_handle = profile_handle;
        agent->profile = *profile;
        recompute_maximum_agent_radius();
        return true;
    }

    bool CrowdWorld::set_agent_position(
        AgentHandle agent_handle, const Vec2 &position, bool clear_velocity)
    {
        CrowdAgentState *agent = agents.get(agent_handle);
        if (agent == nullptr || !std::isfinite(position.x) || !std::isfinite(position.y))
            return false;
        const Vec2 old_position = agent->position;
        agent->position = position;
        spatial.update(static_cast<int>(agent_handle.index), old_position, position);
        if (clear_velocity)
        {
            agent->velocity = {};
            impulses.remove(agent_handle);
        }
        return true;
    }

    bool CrowdWorld::set_agent_motion_limits(
        AgentHandle agent_handle, double maximum_speed,
        double acceleration, double deceleration)
    {
        CrowdAgentState *agent = agents.get(agent_handle);
        if (agent == nullptr)
            return false;
        CrowdAgentProfile requested = agent->profile;
        requested.maximum_speed = maximum_speed;
        requested.acceleration = acceleration;
        requested.deceleration = deceleration;
        agent->profile = CrowdProfileStore::sanitize(requested);
        return true;
    }

    bool CrowdWorld::set_agent_collision_offset(
        AgentHandle agent_handle, const Vec2 &offset)
    {
        CrowdAgentState *agent = agents.get(agent_handle);
        if (agent == nullptr || !std::isfinite(offset.x) || !std::isfinite(offset.y))
            return false;
        agent->profile.collision_offset = offset;
        return true;
    }

    bool CrowdWorld::set_agent_contact_profile(
        AgentHandle agent_handle, double push_strength, double resistance,
        double cooldown, double impulse_decay, double control_suppression)
    {
        CrowdAgentState *agent = agents.get(agent_handle);
        if (agent == nullptr)
            return false;
        CrowdAgentProfile requested = agent->profile;
        requested.contact_push_strength = push_strength;
        requested.contact_push_resistance = resistance;
        requested.contact_push_cooldown = cooldown;
        requested.contact_impulse_decay = impulse_decay;
        requested.contact_control_suppression = control_suppression;
        agent->profile = CrowdProfileStore::sanitize(requested);
        return true;
    }

    bool CrowdWorld::set_agent_traffic_state(
        AgentHandle agent_handle, std::int64_t group_token, int priority)
    {
        CrowdAgentState *agent = agents.get(agent_handle);
        if (agent == nullptr)
            return false;
        agent->traffic_group_token = std::max<std::int64_t>(0, group_token);
        agent->traffic_priority = agent->traffic_group_token == 0 ? 0 : std::max(0, priority);
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
        agent->directional_field_handle = {};
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
        agent->directional_field_handle = {};
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
        agent->directional_field_handle = {};
        agent->route_progress = RouteProgress::Following;
        return true;
    }

    bool CrowdWorld::follow_directional_field(
        AgentHandle handle, DirectionalMotionFieldHandle field)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr || directional_fields.get(field) == nullptr)
            return false;
        agent->directional_field_handle = field;
        agent->navigation_source = NavigationSource::DirectionalField;
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
        agent->directional_field_handle = {};
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

    std::size_t CrowdWorld::apply_impulses(
        const std::vector<AgentHandle> &handles,
        const std::vector<Vec2> &velocities,
        const ImpulseRequest &settings)
    {
        if (handles.size() != velocities.size())
            return 0;
        std::size_t applied = 0;
        for (std::size_t index = 0; index < handles.size(); ++index)
        {
            if (agents.get(handles[index]) == nullptr)
                continue;
            ImpulseRequest request = settings;
            request.velocity = velocities[index];
            impulses.apply(handles[index], request);
            ++applied;
        }
        return applied;
    }

    bool CrowdWorld::refresh_external_velocity(
        AgentHandle handle,
        ExternalVelocitySourceHandle source,
        const Vec2 &velocity,
        double response_seconds,
        double expiry_seconds)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr || !external_velocity_sources.contains(source))
            return false;
        agent->external_velocity.refresh_source(
            encode_external_velocity_source(source), velocity,
            response_seconds, expiry_seconds);
        return true;
    }

    bool CrowdWorld::release_external_velocity(
        AgentHandle handle, ExternalVelocitySourceHandle source)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr || !external_velocity_sources.contains(source))
            return false;
        agent->external_velocity.release_source(encode_external_velocity_source(source));
        return true;
    }

    bool CrowdWorld::remove_external_velocity_source(ExternalVelocitySourceHandle source)
    {
        if (!external_velocity_sources.remove(source))
            return false;
        const std::uint64_t encoded = encode_external_velocity_source(source);
        for (AgentHandle handle : agents.active_handles())
            agents.get(handle)->external_velocity.release_source(encoded);
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

    bool CrowdWorld::is_collision_shape_passable(
        const CrowdAgentState &agent, const Vec2 &position,
        const FlowField *flow) const
    {
        if (flow == nullptr)
            return true;
        const Vec2 center = position + agent.profile.collision_offset;
        const double radius = std::max(0.0, agent.profile.radius);
        const Vec2i center_cell = flow->world_to_cell(center);
        if (radius <= 0.0)
            return flow->is_cell_physics_passable(center_cell);

        const double cell_size = flow->tile_size();
        const double half_cell = cell_size * 0.5;
        const int scan_radius = std::max(
            1, static_cast<int>(std::ceil((radius + half_cell) / cell_size)));
        for (int y = -scan_radius; y <= scan_radius; ++y)
        {
            for (int x = -scan_radius; x <= scan_radius; ++x)
            {
                const Vec2i cell(center_cell.x + x, center_cell.y + y);
                if (flow->is_cell_physics_passable(cell))
                    continue;
                const Vec2 cell_center = flow->cell_to_world(cell);
                const double closest_x = std::clamp(
                    center.x, cell_center.x - half_cell, cell_center.x + half_cell);
                const double closest_y = std::clamp(
                    center.y, cell_center.y - half_cell, cell_center.y + half_cell);
                const Vec2 difference = center - Vec2(closest_x, closest_y);
                if (difference.length_squared() < radius * radius - 1e-8)
                    return false;
            }
        }
        return true;
    }

    Vec2 CrowdWorld::resolve_motion(
        const CrowdAgentState &agent,
        const Vec2 &candidate,
        const FlowField *flow) const
    {
        if (flow == nullptr)
            return candidate;

        const Vec2 full_step = candidate - agent.position;
        const double maximum_substep = std::max(1.0, flow->tile_size() * 0.25);
        const int substep_count = std::max(
            1, static_cast<int>(std::ceil(full_step.length() / maximum_substep)));
        const Vec2 substep = full_step / static_cast<double>(substep_count);
        Vec2 position = agent.position;
        for (int index = 0; index < substep_count; ++index)
        {
            const Vec2 desired = position + substep;
            if (is_collision_shape_passable(agent, desired, flow))
            {
                position = desired;
                continue;
            }

            double low = 0.0;
            double high = 1.0;
            for (int iteration = 0; iteration < 10; ++iteration)
            {
                const double middle = (low + high) * 0.5;
                if (is_collision_shape_passable(
                        agent, position + substep * middle, flow))
                    low = middle;
                else
                    high = middle;
            }
            position += substep * low;

            const Vec2 remaining = substep * (1.0 - low);
            const Vec2 x_only(position.x + remaining.x, position.y);
            if (std::abs(remaining.x) > 1e-8 &&
                is_collision_shape_passable(agent, x_only, flow))
            {
                position = x_only;
                continue;
            }
            const Vec2 y_only(position.x, position.y + remaining.y);
            if (std::abs(remaining.y) > 1e-8 &&
                is_collision_shape_passable(agent, y_only, flow))
            {
                position = y_only;
                continue;
            }
            break;
        }
        return position;
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

        const std::vector<CrowdInteractionImpulse> interaction_impulses =
            interactions.collect(delta, agents, spatial, config.interactions);
        for (const CrowdInteractionImpulse &submission : interaction_impulses)
            impulses.apply(submission.agent, submission.impulse);
        const std::vector<EffectImpulseSubmission> effect_impulses =
            effect_volumes.update(delta, agents);
        for (const EffectImpulseSubmission &submission : effect_impulses)
            impulses.apply(submission.agent, submission.impulse);
        impulses.update(delta);
        traffic.update(delta);
        for (AgentHandle handle : handles)
        {
            CrowdAgentState *agent = agents.get(handle);
            agent->external_velocity.update(delta);
            const FlowField *flow = flow_for(*agent);
            const DirectionalMotionField *directional_field = directional_field_for(*agent);
            const DirectionalMotionSample directional_sample = directional_field == nullptr
                ? DirectionalMotionSample() : directional_field->sample(agent->position);
            const Vec2 navigation = agent->navigation_source == NavigationSource::DirectionalField
                ? directional_sample.velocity.normalized()
                : SteeringSolver::navigation_direction(*agent, flow);
            const Vec2 separation = SteeringSolver::separation(
                *agent, agents, spatial, handles_by_index);
            const Vec2 obstacle_repulsion = static_obstacle_repulsion(*agent);
            Vec2 desired_direction = navigation + separation + obstacle_repulsion;
            if (!desired_direction.is_zero())
                desired_direction = desired_direction.normalized();

            double terrain_multiplier = 1.0;
            if (flow != nullptr)
                terrain_multiplier = terrain_speeds.multiplier_at(
                    flow->world_to_cell(agent->position), agent->profile.terrain_speed_channel);
            const double navigation_speed =
                agent->navigation_source == NavigationSource::DirectionalField && directional_sample.found
                ? directional_sample.velocity.length() : agent->profile.maximum_speed;
            const Vec2 desired_velocity = desired_direction *
                (navigation_speed * terrain_multiplier * impulses.navigation_control(handle));
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
            resolve_static_obstacle_overlaps(*agent);
        }
        spatial.clear();
        for (AgentHandle handle : handles)
        {
            const CrowdAgentState *agent = agents.get(handle);
            spatial.insert(static_cast<int>(handle.index), agent->position);
        }
    }
} // namespace ffcore
