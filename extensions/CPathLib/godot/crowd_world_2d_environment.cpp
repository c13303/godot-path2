#include "crowd_world_2d.h"

#include <algorithm>
#include <cmath>

namespace godot
{
    namespace
    {
        ffcore::DirectionalMotionField make_directional_field(
            Vector2 world_origin, double cell_size, double speed,
            const PackedVector2Array &cells, const PackedVector2Array &directions,
            Vector2 sample_offset, double fallback_radius)
        {
            ffcore::DirectionalMotionField field;
            field.world_origin = {world_origin.x, world_origin.y};
            field.cell_size = cell_size;
            field.speed = speed;
            field.sample_offset = {sample_offset.x, sample_offset.y};
            field.fallback_radius = fallback_radius;
            const int count = std::min(cells.size(), directions.size());
            for (int index = 0; index < count; ++index)
            {
                const Vector2 direction = directions[index].normalized();
                if (!direction.is_zero_approx())
                {
                    field.directions[{
                        static_cast<int>(cells[index].x),
                        static_cast<int>(cells[index].y)}] = {direction.x, direction.y};
                }
            }
            return field;
        }

        std::vector<ffcore::Vec2i> convert_cells(const PackedVector2Array &cells)
        {
            std::vector<ffcore::Vec2i> converted;
            converted.reserve(cells.size());
            for (int index = 0; index < cells.size(); ++index)
                converted.push_back({static_cast<int>(cells[index].x),
                                     static_cast<int>(cells[index].y)});
            return converted;
        }
    }

    void CrowdWorld2D::configure_static_obstacle_avoidance(
        double strength, double query_padding)
    {
        ffcore::CrowdWorldConfig config = crowd.get_config();
        config.static_obstacle_repulsion_strength = strength;
        config.static_obstacle_query_padding = query_padding;
        crowd.set_config(config);
    }

    std::int64_t CrowdWorld2D::create_static_obstacle(
        Vector2 position, double radius, double push_strength)
    {
        return encode_obstacle_handle(crowd.create_static_obstacle(
            {position.x, position.y}, radius, push_strength));
    }

    bool CrowdWorld2D::update_static_obstacle(
        std::int64_t obstacle_handle, Vector2 position,
        double radius, double push_strength)
    {
        return crowd.update_static_obstacle(
            decode_obstacle_handle(obstacle_handle),
            {position.x, position.y}, radius, push_strength);
    }

    bool CrowdWorld2D::remove_static_obstacle(std::int64_t obstacle_handle)
    {
        return crowd.remove_static_obstacle(decode_obstacle_handle(obstacle_handle));
    }

    void CrowdWorld2D::clear_static_obstacles()
    {
        crowd.clear_static_obstacles();
    }

    int CrowdWorld2D::get_static_obstacle_count() const
    {
        return static_cast<int>(crowd.static_obstacle_count());
    }

    std::int64_t CrowdWorld2D::create_directional_motion_field(
        Vector2 world_origin, double cell_size, double speed,
        const PackedVector2Array &cells, const PackedVector2Array &directions,
        Vector2 sample_offset, double fallback_radius)
    {
        return encode_directional_field_handle(crowd.create_directional_field(
            make_directional_field(world_origin, cell_size, speed, cells, directions,
                                   sample_offset, fallback_radius)));
    }

    bool CrowdWorld2D::update_directional_motion_field(
        std::int64_t field_handle, Vector2 world_origin, double cell_size, double speed,
        const PackedVector2Array &cells, const PackedVector2Array &directions,
        Vector2 sample_offset, double fallback_radius)
    {
        return crowd.update_directional_field(
            decode_directional_field_handle(field_handle),
            make_directional_field(world_origin, cell_size, speed, cells, directions,
                                   sample_offset, fallback_radius));
    }

    bool CrowdWorld2D::remove_directional_motion_field(std::int64_t field_handle)
    {
        return crowd.remove_directional_field(decode_directional_field_handle(field_handle));
    }

    void CrowdWorld2D::clear_directional_motion_fields()
    {
        crowd.clear_directional_fields();
    }

    bool CrowdWorld2D::follow_directional_motion_field(
        std::int64_t agent_handle, std::int64_t field_handle)
    {
        return crowd.follow_directional_field(
            decode_handle(agent_handle), decode_directional_field_handle(field_handle));
    }

    void CrowdWorld2D::set_terrain_speed_cell(
        Vector2i cell, double multiplier, int channel)
    {
        crowd.terrain_speed_grid().set_cell({cell.x, cell.y}, multiplier, channel);
    }

    void CrowdWorld2D::set_terrain_speed_cells(
        const PackedVector2Array &cells,
        const PackedFloat64Array &multipliers,
        int channel)
    {
        std::vector<double> converted_multipliers;
        converted_multipliers.reserve(multipliers.size());
        for (int index = 0; index < multipliers.size(); ++index)
            converted_multipliers.push_back(multipliers[index]);
        crowd.terrain_speed_grid().set_cells(
            convert_cells(cells), converted_multipliers, channel);
    }

    void CrowdWorld2D::clear_terrain_speed_cell(Vector2i cell, int channel)
    {
        crowd.terrain_speed_grid().clear_cell({cell.x, cell.y}, channel);
    }

    void CrowdWorld2D::clear_terrain_speed_cells(
        const PackedVector2Array &cells, int channel)
    {
        crowd.terrain_speed_grid().clear_cells(convert_cells(cells), channel);
    }

    void CrowdWorld2D::clear_terrain_speed_channel(int channel)
    {
        crowd.terrain_speed_grid().clear_channel(channel);
    }

    Dictionary CrowdWorld2D::get_agent_diagnostics(std::int64_t agent_handle) const
    {
        Dictionary result;
        const ffcore::CrowdAgentState *agent = crowd.get_agent(decode_handle(agent_handle));
        if (agent == nullptr)
        {
            result["valid"] = false;
            return result;
        }
        result["valid"] = true;
        result["position"] = Vector2(agent->position.x, agent->position.y);
        result["velocity"] = Vector2(agent->velocity.x, agent->velocity.y);
        result["navigation_source"] = static_cast<int>(agent->navigation_source);
        result["route_progress"] = static_cast<int>(agent->route_progress);
        result["paused"] = agent->paused;
        result["category_mask"] = static_cast<std::int64_t>(agent->profile.category_mask);
        result["directional_field_handle"] = encode_directional_field_handle(
            agent->directional_field_handle);
        return result;
    }

    PackedInt64Array CrowdWorld2D::query_agents_in_circle(
        Vector2 position, double radius, std::int64_t category_mask,
        std::int64_t ignored_agent_handle) const
    {
        const std::vector<ffcore::AgentHandle> handles = crowd.query_agents(
            {position.x, position.y}, radius,
            static_cast<std::uint32_t>(category_mask),
            decode_handle(ignored_agent_handle));
        PackedInt64Array result;
        result.resize(static_cast<int>(handles.size()));
        for (int index = 0; index < static_cast<int>(handles.size()); ++index)
            result.set(index, encode_handle(handles[index]));
        return result;
    }

    PackedInt64Array CrowdWorld2D::get_agents_in_navigation_cell(
        NavigationWorld2D *navigation, Vector2i cell) const
    {
        PackedInt64Array result;
        if (navigation == nullptr)
            return result;
        const ffcore::GridDefinition &grid = navigation->grid_definition();
        if (!grid.is_valid())
            return result;
        for (ffcore::AgentHandle handle : crowd.active_agents())
        {
            const ffcore::CrowdAgentState *agent = crowd.get_agent(handle);
            const ffcore::Vec2 local = (agent->position - grid.world_origin) / grid.cell_size;
            const ffcore::Vec2i agent_cell = {
                grid.cell_origin.x + static_cast<int>(std::floor(local.x)),
                grid.cell_origin.y + static_cast<int>(std::floor(local.y))};
            if (agent_cell == ffcore::Vec2i(cell.x, cell.y))
                result.push_back(encode_handle(handle));
        }
        return result;
    }
} // namespace godot
