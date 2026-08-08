#include "crowd_world.h"

#include <algorithm>
#include <cmath>

namespace ffcore
{
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
