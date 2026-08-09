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
        config.bottleneck_wait_speed_ratio = std::isfinite(config.bottleneck_wait_speed_ratio)
            ? std::clamp(config.bottleneck_wait_speed_ratio, 0.0, 1.0) : 0.05;
        config.flow_goal_stop_delay = std::isfinite(config.flow_goal_stop_delay)
            ? std::max(0.0, config.flow_goal_stop_delay) : 1.0;
        config.flow_goal_group_delay = std::isfinite(config.flow_goal_group_delay)
            ? std::max(0.0, config.flow_goal_group_delay) : 0.005;
        config.flow_goal_slow_speed_ratio = std::isfinite(config.flow_goal_slow_speed_ratio)
            ? std::clamp(config.flow_goal_slow_speed_ratio, 0.0, 1.0) : 0.6;
        config.zero_flow_retry_seconds = std::isfinite(config.zero_flow_retry_seconds)
            ? std::max(0.0, config.zero_flow_retry_seconds) : 0.6;
        config.zero_flow_recovery_speed_ratio =
            std::isfinite(config.zero_flow_recovery_speed_ratio)
            ? std::clamp(config.zero_flow_recovery_speed_ratio, 0.0, 1.0) : 0.25;
        config.blocked_motion_retry_seconds = std::isfinite(config.blocked_motion_retry_seconds)
            ? std::max(0.0, config.blocked_motion_retry_seconds) : 0.6;
        config.navigation_weight = std::isfinite(config.navigation_weight)
            ? std::max(0.0, config.navigation_weight) : 1.0;
        config.separation_maximum_neighbors = std::max(0, config.separation_maximum_neighbors);
        config.separation_priority_bias = std::isfinite(config.separation_priority_bias)
            ? std::clamp(config.separation_priority_bias, 0.0, 1.0) : 0.0;
        config.bottleneck_backward_push_ratio =
            std::isfinite(config.bottleneck_backward_push_ratio)
            ? std::clamp(config.bottleneck_backward_push_ratio, 0.0, 1.0) : 0.15;
        config.bottleneck_lateral_push_ratio =
            std::isfinite(config.bottleneck_lateral_push_ratio)
            ? std::max(0.0, config.bottleneck_lateral_push_ratio) : 1.25;
        impulses.set_response_config(config.impulse_response);
        config.impulse_response = impulses.get_response_config();
    }

    Vec2 CrowdWorld::steer_direction(
        const Vec2 &navigation, const Vec2 &avoidance, bool in_bottleneck) const
    {
        if (navigation.is_zero())
            return avoidance;
        if (!in_bottleneck)
            return avoidance + navigation * config.navigation_weight;
        // Split avoidance into "along the route" and "across it", then bound each.
        // A queueing agent may be nudged aside or slowed, but crowd pressure must not
        // push it back out of the chokepoint it is waiting to pass.
        const double weight = config.navigation_weight;
        const double along_route = avoidance.dot(navigation);
        const double forward = std::clamp(
            along_route, -weight * config.bottleneck_backward_push_ratio, weight);
        Vec2 lateral = avoidance - navigation * along_route;
        const double maximum_lateral = weight * config.bottleneck_lateral_push_ratio;
        const double lateral_length = lateral.length();
        if (lateral_length > maximum_lateral && lateral_length > 1e-6)
            lateral = lateral * (maximum_lateral / lateral_length);
        return navigation * (weight + forward) + lateral;
    }

    Vec2 CrowdWorld::blend_impulse_with_navigation(const Vec2 &impulse, const Vec2 &navigation)
    {
        if (impulse.is_zero())
            return navigation;
        // Impulse and navigation share one speed budget rather than stacking. A knockback
        // therefore overrides movement while it is strong and fades back into it as it
        // decays, instead of adding a residual drift the agent can never walk off.
        const Vec2 combined = impulse + navigation;
        const double combined_speed = combined.length();
        const double budget = std::max(impulse.length(), navigation.length());
        if (combined_speed <= budget || combined_speed <= 1e-6)
            return combined;
        return combined * (budget / combined_speed);
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
        recompute_maximum_agent_radius();
        return handle;
    }

    AgentHandle CrowdWorld::add_agent(const Vec2 &position, const CrowdAgentProfile &profile)
    {
        const AgentHandle handle = agents.create(position, profile);
        spatial.insert(static_cast<int>(handle.index), position);
        recompute_maximum_agent_radius();
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
        recompute_maximum_agent_radius();
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
        double cooldown, double impulse_decay, double control_suppression,
        bool feedback_enabled)
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
        requested.contact_feedback_enabled = feedback_enabled;
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
        reset_navigation_transients(*agent);
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
        reset_navigation_transients(*agent);
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
        reset_navigation_transients(*agent);
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
        reset_navigation_transients(*agent);
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
        reset_navigation_transients(*agent);
        return true;
    }

    bool CrowdWorld::set_paused(AgentHandle handle, bool paused)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->paused = paused;
        if (paused)
            agent->velocity = {};
        return true;
    }

    bool CrowdWorld::set_pause_allows_impulses(AgentHandle handle, bool enabled)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->allow_impulses_while_paused = enabled;
        return true;
    }

    bool CrowdWorld::set_navigation_suspended(AgentHandle handle, bool suspended)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->navigation_suspended = suspended;
        if (suspended)
            agent->velocity = {};
        return true;
    }

    bool CrowdWorld::set_forces_enabled(AgentHandle handle, bool enabled)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->forces_enabled = enabled;
        if (!enabled)
            clear_agent_forces(handle);
        return true;
    }

    bool CrowdWorld::set_continue_at_flow_goal(AgentHandle handle, bool enabled)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        agent->continue_at_flow_goal = enabled;
        agent->flow_goal_timer = 0.0;
        if (enabled && agent->route_progress == RouteProgress::Arrived)
            agent->route_progress = RouteProgress::Following;
        return true;
    }

    void CrowdWorld::clear_agent_forces(AgentHandle handle)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return;
        impulses.remove(handle);
        agent->external_velocity.clear();
    }

    void CrowdWorld::apply_impulse(AgentHandle handle, const ImpulseRequest &request)
    {
        CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr || !agent->forces_enabled)
            return;
        ImpulseRequest adjusted = request;
        if (adjusted.apply_agent_resistance)
            adjusted.velocity = adjusted.velocity /
                std::max(0.001, agent->profile.impulse_resistance);
        impulses.apply(handle, adjusted);
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
            CrowdAgentState *agent = agents.get(handles[index]);
            if (agent == nullptr || !agent->forces_enabled)
                continue;
            ImpulseRequest request = settings;
            request.velocity = velocities[index];
            if (request.apply_agent_resistance)
                request.velocity = request.velocity /
                    std::max(0.001, agent->profile.impulse_resistance);
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
        if (agent == nullptr || !agent->forces_enabled ||
            !external_velocity_sources.contains(source))
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

    bool CrowdWorld::agent_has_flow(AgentHandle handle) const
    {
        const CrowdAgentState *agent = agents.get(handle);
        return agent != nullptr && flow_for(*agent) != nullptr;
    }

    bool CrowdWorld::agent_flow_ready(AgentHandle handle) const
    {
        const CrowdAgentState *agent = agents.get(handle);
        if (agent == nullptr)
            return false;
        const FlowField *flow = flow_for(*agent);
        return flow != nullptr && flow->is_ready();
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

    bool CrowdWorld::collision_contact_normal(
        const CrowdAgentState &agent, const Vec2 &position,
        const FlowField *flow, Vec2 &normal) const
    {
        if (flow == nullptr || agent.profile.radius <= 0.0)
            return false;

        const Vec2 center = position + agent.profile.collision_offset;
        const double radius = agent.profile.radius;
        const double cell_size = flow->tile_size();
        const double half_cell = cell_size * 0.5;
        const Vec2i center_cell = flow->world_to_cell(center);
        const int scan_radius = std::max(
            1, static_cast<int>(std::ceil((radius + half_cell) / cell_size)));
        Vec2 normal_sum;
        double total_weight = 0.0;
        for (int y = -scan_radius; y <= scan_radius; ++y)
        {
            for (int x = -scan_radius; x <= scan_radius; ++x)
            {
                const Vec2i cell(center_cell.x + x, center_cell.y + y);
                if (flow->is_cell_physics_passable(cell))
                    continue;
                const Vec2 cell_center = flow->cell_to_world(cell);
                const Vec2 closest = closest_point_on_aabb(
                    center, cell_center, half_cell, half_cell);
                const Vec2 away = center - closest;
                const double distance = away.length();
                if (distance >= radius - 1e-6)
                    continue;
                Vec2 contact_normal = distance > 1e-6
                    ? away / distance : (center - cell_center).normalized();
                if (contact_normal.is_zero())
                    continue;
                const double penetration = std::max(1e-6, radius - distance);
                normal_sum += contact_normal * penetration;
                total_weight += penetration;
            }
        }
        if (total_weight <= 0.0 || normal_sum.is_zero())
            return false;
        normal = normal_sum.normalized();
        return !normal.is_zero();
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
            const Vec2 before_slide = position;
            Vec2 remaining = substep;
            bool moved_or_slid = false;
            for (int slide_iteration = 0; slide_iteration < 3; ++slide_iteration)
            {
                if (remaining.length_squared() < 1e-8)
                    break;
                const Vec2 desired = position + remaining;
                if (is_collision_shape_passable(agent, desired, flow))
                {
                    position = desired;
                    moved_or_slid = true;
                    remaining = {};
                    break;
                }

                double low = 0.0;
                double high = 1.0;
                for (int sweep_iteration = 0; sweep_iteration < 8; ++sweep_iteration)
                {
                    const double middle = (low + high) * 0.5;
                    if (is_collision_shape_passable(
                            agent, position + remaining * middle, flow))
                        low = middle;
                    else
                        high = middle;
                }
                if (low > 0.0)
                {
                    position += remaining * low;
                    moved_or_slid = true;
                }

                Vec2 wall_normal;
                const Vec2 blocked_position = position + remaining * (high - low);
                if (!collision_contact_normal(
                        agent, blocked_position, flow, wall_normal))
                    break;
                const Vec2 unused_step = remaining * (1.0 - low);
                const double into_wall = unused_step.dot(wall_normal);
                if (into_wall >= -1e-6)
                    break;
                remaining = unused_step - wall_normal * into_wall;
            }

            if (moved_or_slid)
                continue;

            position = before_slide;
            const Vec2 x_only(position.x + substep.x, position.y);
            if (std::abs(substep.x) > 1e-8 &&
                is_collision_shape_passable(agent, x_only, flow))
            {
                position = x_only;
                continue;
            }
            const Vec2 y_only(position.x, position.y + substep.y);
            if (std::abs(substep.y) > 1e-8 &&
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

        std::unordered_map<std::uint64_t, std::unordered_map<int, int>>
            bottleneck_core_occupancy;
        if (config.automatic_bottleneck_gating)
        {
            for (AgentHandle handle : handles)
            {
                const CrowdAgentState *agent = agents.get(handle);
                const FlowField *flow = flow_for(*agent);
                if (flow == nullptr || agent->navigation_source != NavigationSource::FlowField)
                    continue;
                const Vec2i cell = flow->world_to_cell(
                    agent->position + agent->profile.collision_offset);
                const int core = flow->bottleneck_core_at_cell(cell);
                if (core >= 0)
                    ++bottleneck_core_occupancy[key(agent->flow_handle)][core];
            }
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
            if (agent->forces_enabled)
                agent->external_velocity.update(delta);
            const FlowField *flow = flow_for(*agent);
            const DirectionalMotionField *directional_field = directional_field_for(*agent);
            const DirectionalMotionSample directional_sample = directional_field == nullptr
                ? DirectionalMotionSample() : directional_field->sample(agent->position);
            Vec2 navigation = agent->navigation_source == NavigationSource::DirectionalField
                ? directional_sample.velocity.normalized()
                : SteeringSolver::navigation_direction(*agent, flow);
            bool hard_freeze = agent->navigation_suspended;
            bool autonomous_stop = false;
            bool in_bottleneck = false;
            double navigation_speed_scale = 1.0;

            if (agent->blocked_motion_seconds < 0.0)
            {
                agent->blocked_motion_seconds = std::min(
                    0.0, agent->blocked_motion_seconds + delta);
                hard_freeze = true;
            }

            if (flow != nullptr && agent->navigation_source == NavigationSource::FlowField)
            {
                const Vec2 sample_position = agent->position + agent->profile.collision_offset;
                const Vec2i cell = flow->world_to_cell(sample_position);
                const Vec2 goal_offset = flow->goal_center_world() - sample_position;
                const double goal_distance = goal_offset.length();
                const CohortHandle cohort = cohorts.find_cohort(handle);
                const std::size_t cohort_size = cohort.is_valid()
                    ? cohorts.get(cohort)->members.size() : 1;
                constexpr double pi = 3.14159265358979323846;
                const double spread_cells = std::ceil(std::sqrt(
                    static_cast<double>(cohort_size > 0 ? cohort_size - 1 : 0) / pi));
                const double goal_radius = (spread_cells + 1.0) * flow->tile_size();

                if (agent->route_progress == RouteProgress::Arrived &&
                    !agent->continue_at_flow_goal)
                {
                    navigation = {};
                    autonomous_stop = true;
                }
                else if (!agent->continue_at_flow_goal && cohort_size <= 2 &&
                         goal_distance <= flow->tile_size() * 0.5)
                {
                    agent->route_progress = RouteProgress::Arrived;
                    agent->velocity = {};
                    navigation = {};
                    autonomous_stop = true;
                }
                else if (!agent->continue_at_flow_goal && goal_distance <= goal_radius)
                {
                    navigation_speed_scale = config.flow_goal_slow_speed_ratio;
                    if (agent->flow_goal_timer <= 0.0)
                        agent->flow_goal_timer = config.flow_goal_stop_delay +
                            static_cast<double>(cohort_size) * config.flow_goal_group_delay;
                    agent->flow_goal_timer -= delta;
                    if (agent->flow_goal_timer <= 0.0)
                    {
                        agent->route_progress = RouteProgress::Arrived;
                        agent->velocity = {};
                        navigation = {};
                        autonomous_stop = true;
                    }
                }

                const double lost_goal_margin = std::max(flow->tile_size() * 0.5, goal_radius);
                if (navigation.is_zero() && goal_distance > lost_goal_margin &&
                    agent->route_progress != RouteProgress::Arrived)
                {
                    const bool force_owned_motion = is_impulse_active(handle) ||
                        !agent->external_velocity.current_velocity().is_zero();
                    if (force_owned_motion)
                    {
                        agent->zero_flow_retry_started = false;
                        agent->zero_flow_retry_remaining = 0.0;
                    }
                    else if (!agent->zero_flow_retry_started)
                    {
                        agent->zero_flow_retry_started = true;
                        agent->zero_flow_retry_remaining = config.zero_flow_retry_seconds;
                    }
                    if (!force_owned_motion && agent->zero_flow_retry_remaining > 0.0)
                    {
                        agent->zero_flow_retry_remaining = std::max(
                            0.0, agent->zero_flow_retry_remaining - delta);
                        hard_freeze = true;
                    }
                    else if (!force_owned_motion)
                    {
                        const Vec2i nearest = flow->find_nearest_navigable(cell);
                        navigation = (flow->cell_to_world(nearest) - sample_position).normalized();
                        navigation_speed_scale *= config.zero_flow_recovery_speed_ratio;
                    }
                }
                else if (!navigation.is_zero() || goal_distance <= lost_goal_margin)
                {
                    agent->zero_flow_retry_started = false;
                    agent->zero_flow_retry_remaining = 0.0;
                }

                agent->bottleneck_waiting = false;
                if (config.automatic_bottleneck_gating)
                {
                    const int core = flow->bottleneck_core_at_cell(cell);
                    const int zone = flow->bottleneck_zone_at_cell(cell);
                    in_bottleneck = core >= 0 || zone >= 0;
                    if (core >= 0)
                        agent->completed_bottleneck = core;
                    else if (agent->completed_bottleneck >= 0 &&
                             zone != agent->completed_bottleneck)
                        agent->completed_bottleneck = -1;

                    const int next = flow->next_bottleneck_at_cell(cell);
                    if (next >= 0 && next != agent->completed_bottleneck)
                    {
                        const BottleneckInfo *info = flow->bottleneck_at(next);
                        if (info != nullptr && flow->route_cost_at_cell(cell) >= info->route_cost)
                        {
                            const Vec2 toward_core =
                                (flow->cell_to_world(info->cell) - sample_position).normalized();
                            if (!toward_core.is_zero())
                                navigation = toward_core;
                        }
                    }

                    const auto field_occupancy =
                        bottleneck_core_occupancy.find(key(agent->flow_handle));
                    if (zone >= 0 && zone != agent->completed_bottleneck &&
                        field_occupancy != bottleneck_core_occupancy.end())
                    {
                        const auto occupied = field_occupancy->second.find(zone);
                        if (occupied != field_occupancy->second.end() && occupied->second > 0)
                        {
                            agent->bottleneck_waiting = true;
                            navigation_speed_scale *= config.bottleneck_wait_speed_ratio;
                        }
                    }
                }
            }

            if (hard_freeze || agent->paused)
                navigation = {};
            SeparationSettings separation_settings;
            separation_settings.maximum_neighbors = config.separation_maximum_neighbors;
            separation_settings.priority_bias = config.separation_priority_bias;
            separation_settings.maximum_agent_radius = maximum_agent_radius;
            const Vec2 separation = hard_freeze || agent->paused || autonomous_stop
                ? Vec2() : SteeringSolver::separation(
                    *agent, agents, spatial, handles_by_index, separation_settings);
            const Vec2 obstacle_repulsion = hard_freeze || agent->paused || autonomous_stop
                ? Vec2() : static_obstacle_repulsion(*agent);
            Vec2 desired_direction = steer_direction(
                navigation, separation + obstacle_repulsion, in_bottleneck);
            if (!desired_direction.is_zero())
                desired_direction = desired_direction.normalized();
            agent->desired_direction = desired_direction;

            double terrain_multiplier = 1.0;
            if (flow != nullptr)
            {
                const Vec2i relative_cell = flow->world_to_cell(
                    agent->position + agent->profile.collision_offset);
                const Vec2i &cell_origin = flow->get_cell_origin();
                const Vec2i absolute_cell(
                    relative_cell.x + cell_origin.x,
                    relative_cell.y + cell_origin.y);
                terrain_multiplier = terrain_speeds.multiplier_at(
                    absolute_cell,
                    agent->profile.terrain_speed_channel);
            }
            const double navigation_speed = (
                agent->navigation_source == NavigationSource::DirectionalField && directional_sample.found
                ? directional_sample.velocity.length() : agent->profile.maximum_speed) *
                navigation_speed_scale;
            const Vec2 desired_velocity = desired_direction *
                (navigation_speed * impulses.navigation_control(handle));
            impulses.cancel_if_navigation_opposes(handle, desired_velocity);
            const double rate = desired_velocity.length_squared() > agent->velocity.length_squared()
                ? agent->profile.acceleration : agent->profile.deceleration;
            agent->velocity = approach(agent->velocity, desired_velocity, rate * delta);

            // Freezing and pausing suppress the agent's *own* navigation. They must not
            // swallow force-owned motion: an agent waiting on a flow, or parked by the
            // consumer, is still a physical body and stays shovable. Only force
            // isolation (forces_enabled) or an explicit pause policy stops that.
            const bool navigation_owned_motion = !hard_freeze && !agent->paused;
            const bool force_owned_motion = agent->forces_enabled &&
                (!agent->paused || agent->allow_impulses_while_paused);
            Vec2 total_velocity;
            if (navigation_owned_motion)
                total_velocity = agent->velocity;
            if (force_owned_motion)
            {
                total_velocity = blend_impulse_with_navigation(
                    impulses.velocity(handle), total_velocity);
                if (navigation_owned_motion)
                    total_velocity += agent->external_velocity.current_velocity();
            }
            const Vec2 resolved = resolve_motion(
                *agent,
                agent->position + total_velocity * (delta * terrain_multiplier),
                flow);
            const bool blocked = agent->navigation_source == NavigationSource::FlowField &&
                (resolved - agent->position).length_squared() < 1e-12 &&
                !desired_velocity.is_zero() && impulses.velocity(handle).is_zero();
            if (blocked)
            {
                agent->blocked_motion_seconds += delta;
                if (config.blocked_motion_retry_seconds > 0.0 &&
                    agent->blocked_motion_seconds >= config.blocked_motion_retry_seconds)
                    agent->blocked_motion_seconds = -config.zero_flow_retry_seconds;
            }
            else if (agent->blocked_motion_seconds > 0.0)
                agent->blocked_motion_seconds = 0.0;
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
