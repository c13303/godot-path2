#include "crowd_world.h"

#include <algorithm>
#include <cmath>

namespace ffcore
{
    void CrowdWorld::reset_navigation_transients(CrowdAgentState &agent)
    {
        agent.flow_goal_timer = 0.0;
        agent.zero_flow_retry_remaining = 0.0;
        agent.zero_flow_retry_started = false;
        agent.blocked_motion_seconds = 0.0;
        agent.completed_bottleneck = -1;
        agent.bottleneck_waiting = false;
    }

    bool CrowdWorld::set_agent_avoidance_profile(
        AgentHandle agent_handle, double push_strength, double resistance)
    {
        CrowdAgentState *agent = agents.get(agent_handle);
        if (agent == nullptr)
            return false;
        CrowdAgentProfile requested = agent->profile;
        requested.avoidance_push_strength = push_strength;
        requested.avoidance_resistance = resistance;
        agent->profile = CrowdProfileStore::sanitize(requested);
        return true;
    }

    bool CrowdWorld::set_agent_impulse_resistance(
        AgentHandle agent_handle, double resistance)
    {
        CrowdAgentState *agent = agents.get(agent_handle);
        if (agent == nullptr)
            return false;
        CrowdAgentProfile requested = agent->profile;
        requested.impulse_resistance = resistance;
        agent->profile = CrowdProfileStore::sanitize(requested);
        return true;
    }

    bool CrowdWorld::set_agent_query_shape(
        AgentHandle agent_handle, const Vec2 &offset, const Vec2 &half_extents)
    {
        CrowdAgentState *agent = agents.get(agent_handle);
        if (agent == nullptr)
            return false;
        CrowdAgentProfile requested = agent->profile;
        requested.query_shape_offset = offset;
        requested.query_shape_half_extents = half_extents;
        agent->profile = CrowdProfileStore::sanitize(requested);
        recompute_maximum_agent_radius();
        return true;
    }

    std::vector<AgentHandle> CrowdWorld::query_agents(
        const Vec2 &position, double radius,
        std::uint32_t category_mask, AgentHandle ignored) const
    {
        std::vector<AgentHandle> result;
        if (!std::isfinite(radius) || radius < 0.0)
            return result;
        for (int index : spatial.query_neighbors(position, radius + maximum_query_shape_radius))
        {
            if (index <= 0)
                continue;
            const AgentHandle candidate_handle = {
                static_cast<std::uint32_t>(index),
                agents.generation_at(static_cast<std::uint32_t>(index))};
            const CrowdAgentState *candidate = agents.get(candidate_handle);
            if (candidate == nullptr || candidate_handle == ignored ||
                (candidate->profile.category_mask & category_mask) == 0)
                continue;
            const Vec2 half = candidate->profile.query_shape_half_extents;
            const bool uses_box = half.x > 0.0 || half.y > 0.0;
            const Vec2 center = candidate->position + candidate->profile.query_shape_offset;
            const bool overlaps = uses_box
                ? point_aabb_distance(position, center, half.x, half.y) <= radius
                : center.distance_to(position) <= radius + candidate->profile.radius;
            if (overlaps)
                result.push_back(candidate_handle);
        }
        std::sort(result.begin(), result.end(), [](AgentHandle left, AgentHandle right)
        {
            return left.index < right.index;
        });
        result.erase(std::unique(result.begin(), result.end()), result.end());
        return result;
    }

    void CrowdWorld::recompute_maximum_agent_radius()
    {
        maximum_agent_radius = 0.0;
        maximum_query_shape_radius = 0.0;
        for (AgentHandle handle : agents.active_handles())
        {
            const CrowdAgentProfile &profile = agents.get(handle)->profile;
            maximum_agent_radius = std::max(
                maximum_agent_radius, profile.radius);
            const double box_radius = profile.query_shape_offset.length() +
                std::sqrt(profile.query_shape_half_extents.x * profile.query_shape_half_extents.x +
                          profile.query_shape_half_extents.y * profile.query_shape_half_extents.y);
            maximum_query_shape_radius = std::max(
                maximum_query_shape_radius, std::max(profile.radius, box_radius));
        }
    }

    std::vector<AgentHandle> CrowdWorld::query_agents_in_cone(
        const Vec2 &position, double radius, const Vec2 &direction,
        double angle_degrees, std::uint32_t category_mask, AgentHandle ignored) const
    {
        std::vector<AgentHandle> result;
        const Vec2 facing = direction.normalized();
        if (facing.is_zero() || !std::isfinite(angle_degrees))
            return result;
        const double clamped_angle = std::clamp(angle_degrees, 0.0, 360.0);
        constexpr double pi = 3.14159265358979323846;
        const double half_angle = clamped_angle * 0.5 * pi / 180.0;
        for (AgentHandle handle : query_agents(position, radius, category_mask, ignored))
        {
            const CrowdAgentState *agent = agents.get(handle);
            const Vec2 half = agent->profile.query_shape_half_extents;
            const bool uses_box = half.x > 0.0 || half.y > 0.0;
            const Vec2 center = agent->position + agent->profile.query_shape_offset;
            const Vec2 nearest = uses_box
                ? closest_point_on_aabb(position, center, half.x, half.y) : center;
            const Vec2 offset = nearest - position;
            const double distance = offset.length();
            if (clamped_angle >= 360.0 || distance <= (uses_box ? 1e-8 : agent->profile.radius))
            {
                result.push_back(handle);
                continue;
            }

            // Agents are discs, so include a disc whose edge intersects the cone
            // even when its center lies just outside the angular boundary.
            const double angular_margin = uses_box ? 0.0 : std::asin(std::clamp(
                agent->profile.radius / distance, 0.0, 1.0));
            const double effective_half_angle = std::min(pi, half_angle + angular_margin);
            if (offset.normalized().dot(facing) >= std::cos(effective_half_angle))
                result.push_back(handle);
        }
        return result;
    }

    std::vector<AgentHandle> CrowdWorld::query_agents_in_aabb(
        const Vec2 &center, double half_width, double half_height,
        std::uint32_t category_mask, AgentHandle ignored) const
    {
        std::vector<AgentHandle> result;
        if (!std::isfinite(half_width) || !std::isfinite(half_height) ||
            half_width < 0.0 || half_height < 0.0)
            return result;
        const double query_radius = std::sqrt(
            half_width * half_width + half_height * half_height);
        for (AgentHandle handle : query_agents(center, query_radius, category_mask, ignored))
        {
            const CrowdAgentState *agent = agents.get(handle);
            const Vec2 query_half = agent->profile.query_shape_half_extents;
            const bool uses_box = query_half.x > 0.0 || query_half.y > 0.0;
            const Vec2 query_center = agent->position + agent->profile.query_shape_offset;
            const bool overlaps = uses_box
                ? std::abs(query_center.x - center.x) <= query_half.x + half_width &&
                  std::abs(query_center.y - center.y) <= query_half.y + half_height
                : circle_overlaps_aabb(query_center, agent->profile.radius,
                                       center, half_width, half_height);
            if (overlaps)
                result.push_back(handle);
        }
        return result;
    }

    DirectionalMotionFieldHandle CrowdWorld::create_directional_field(
        const DirectionalMotionField &field)
    {
        return directional_fields.create(field);
    }

    bool CrowdWorld::update_directional_field(
        DirectionalMotionFieldHandle handle, const DirectionalMotionField &field)
    {
        return directional_fields.update(handle, field);
    }

    bool CrowdWorld::remove_directional_field(DirectionalMotionFieldHandle handle)
    {
        if (!directional_fields.remove(handle))
            return false;
        for (AgentHandle agent_handle : agents.active_handles())
        {
            CrowdAgentState *agent = agents.get(agent_handle);
            if (agent->directional_field_handle == handle)
            {
                agent->directional_field_handle = {};
                agent->navigation_source = NavigationSource::None;
                agent->route_progress = RouteProgress::Failed;
            }
        }
        return true;
    }

    void CrowdWorld::clear_directional_fields()
    {
        directional_fields.clear();
        for (AgentHandle agent_handle : agents.active_handles())
        {
            CrowdAgentState *agent = agents.get(agent_handle);
            if (agent->navigation_source == NavigationSource::DirectionalField)
            {
                agent->navigation_source = NavigationSource::None;
                agent->route_progress = RouteProgress::Failed;
            }
            agent->directional_field_handle = {};
        }
    }

    StaticObstacleHandle CrowdWorld::create_static_obstacle(
        const Vec2 &position, double radius, double push_strength)
    {
        return static_obstacles.create(position, radius, push_strength);
    }

    bool CrowdWorld::update_static_obstacle(
        StaticObstacleHandle handle, const Vec2 &position,
        double radius, double push_strength)
    {
        return static_obstacles.update(handle, position, radius, push_strength);
    }

    bool CrowdWorld::remove_static_obstacle(StaticObstacleHandle handle)
    {
        return static_obstacles.remove(handle);
    }

    const DirectionalMotionField *CrowdWorld::directional_field_for(
        const CrowdAgentState &agent) const
    {
        return directional_fields.get(agent.directional_field_handle);
    }

    Vec2 CrowdWorld::static_obstacle_repulsion(const CrowdAgentState &agent) const
    {
        const double query_radius = agent.profile.radius + static_obstacles.max_radius() +
            config.static_obstacle_query_padding;
        Vec2 force;
        for (StaticObstacleHandle handle : static_obstacles.query(agent.position, query_radius))
        {
            const StaticObstacle *obstacle = static_obstacles.get(handle);
            if (obstacle == nullptr)
                continue;
            const double combined_radius = agent.profile.radius + obstacle->radius;
            Vec2 difference = agent.position - obstacle->position;
            double distance = difference.length();
            if (combined_radius <= 0.0 || distance >= combined_radius)
                continue;
            if (distance < 0.001)
            {
                const double angle = static_cast<double>(agent.handle.index) * 2.399963229728653;
                difference = {std::cos(angle), std::sin(angle)};
                distance = 0.001;
            }
            const double penetration = std::clamp(
                1.0 - distance / combined_radius, 0.0, 1.0);
            force += difference.normalized() *
                (penetration * penetration * obstacle->push_strength);
        }
        return force.is_zero() ? Vec2() :
            force.normalized() * config.static_obstacle_repulsion_strength;
    }

    void CrowdWorld::resolve_static_obstacle_overlaps(CrowdAgentState &agent) const
    {
        const double query_radius = agent.profile.radius + static_obstacles.max_radius() +
            config.static_obstacle_query_padding;
        const std::vector<StaticObstacleHandle> nearby =
            static_obstacles.query(agent.position, query_radius);
        for (int pass = 0; pass < 2; ++pass)
        {
            bool moved = false;
            for (StaticObstacleHandle handle : nearby)
            {
                const StaticObstacle *obstacle = static_obstacles.get(handle);
                if (obstacle == nullptr)
                    continue;
                const double combined_radius = agent.profile.radius + obstacle->radius;
                Vec2 difference = agent.position - obstacle->position;
                const double distance = difference.length();
                if (combined_radius <= 0.0 || distance >= combined_radius)
                    continue;
                if (distance < 0.001)
                {
                    const double angle =
                        static_cast<double>(agent.handle.index) * 2.399963229728653;
                    difference = {std::cos(angle), std::sin(angle)};
                }
                const Vec2 normal = difference.normalized();
                agent.position += normal * (combined_radius - distance);
                const double inward_speed = agent.velocity.dot(normal);
                if (inward_speed < 0.0)
                    agent.velocity -= normal * inward_speed;
                moved = true;
            }
            if (!moved)
                break;
        }
    }
} // namespace ffcore
