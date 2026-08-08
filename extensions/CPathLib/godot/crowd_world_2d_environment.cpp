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
        result["radius"] = agent->profile.radius;
        result["maximum_speed"] = agent->profile.maximum_speed;
        result["acceleration"] = agent->profile.acceleration;
        result["deceleration"] = agent->profile.deceleration;
        result["separation_radius"] = agent->profile.separation_radius;
        result["separation_weight"] = agent->profile.separation_weight;
        result["arrival_radius"] = agent->profile.arrival_radius;
        result["terrain_speed_channel"] = agent->profile.terrain_speed_channel;
        result["category_mask"] = static_cast<std::int64_t>(agent->profile.category_mask);
        result["collision_offset"] = Vector2(
            agent->profile.collision_offset.x,
            agent->profile.collision_offset.y);
        result["contact_push_strength"] = agent->profile.contact_push_strength;
        result["contact_push_resistance"] = agent->profile.contact_push_resistance;
        result["contact_push_cooldown"] = agent->profile.contact_push_cooldown;
        result["contact_impulse_decay"] = agent->profile.contact_impulse_decay;
        result["contact_control_suppression"] =
            agent->profile.contact_control_suppression;
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

    PackedInt64Array CrowdWorld2D::query_agents_in_cone(
        Vector2 position, double radius, Vector2 direction, double angle_degrees,
        std::int64_t category_mask, std::int64_t ignored_agent_handle) const
    {
        const std::vector<ffcore::AgentHandle> handles = crowd.query_agents_in_cone(
            {position.x, position.y}, radius, {direction.x, direction.y}, angle_degrees,
            static_cast<std::uint32_t>(category_mask),
            decode_handle(ignored_agent_handle));
        PackedInt64Array result;
        result.resize(static_cast<int>(handles.size()));
        for (int index = 0; index < static_cast<int>(handles.size()); ++index)
            result.set(index, encode_handle(handles[index]));
        return result;
    }

    PackedInt64Array CrowdWorld2D::query_agents_in_aabb(
        Rect2 bounds, std::int64_t category_mask,
        std::int64_t ignored_agent_handle) const
    {
        const Vector2 center = bounds.get_center();
        const Vector2 half_size = bounds.size * 0.5;
        const std::vector<ffcore::AgentHandle> handles = crowd.query_agents_in_aabb(
            {center.x, center.y}, half_size.x, half_size.y,
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

    std::int64_t CrowdWorld2D::create_effect_volume(const Dictionary &configuration)
    {
        ffcore::EffectVolumeConfig config;
        if (configuration.has("position"))
        {
            const Vector2 value = configuration["position"];
            config.position = {value.x, value.y};
        }
        if (configuration.has("direction"))
        {
            const Vector2 value = configuration["direction"];
            config.direction = {value.x, value.y};
        }
        if (configuration.has("radius")) config.radius = configuration["radius"];
        if (configuration.has("angle_degrees")) config.angle_degrees = configuration["angle_degrees"];
        if (configuration.has("duration")) config.duration = configuration["duration"];
        if (configuration.has("tick_interval")) config.tick_interval = configuration["tick_interval"];
        if (configuration.has("category_mask"))
            config.category_mask = static_cast<std::uint32_t>(
                static_cast<std::int64_t>(configuration["category_mask"]));
        if (configuration.has("ignored_agent_handle"))
            config.ignored_agent = decode_handle(configuration["ignored_agent_handle"]);
        if (configuration.has("followed_agent_handle"))
            config.followed_agent = decode_handle(configuration["followed_agent_handle"]);
        if (configuration.has("follow_offset"))
        {
            const Vector2 value = configuration["follow_offset"];
            config.follow_offset = {value.x, value.y};
        }
        if (configuration.has("caller_token")) config.caller_token = configuration["caller_token"];
        if (configuration.has("apply_impulse_on_tick")) config.apply_impulse_on_tick = configuration["apply_impulse_on_tick"];
        if (configuration.has("radial_impulse") && bool(configuration["radial_impulse"]))
            config.impulse_direction = ffcore::EffectImpulseDirection::Radial;
        if (configuration.has("impulse_speed")) config.impulse_speed = configuration["impulse_speed"];
        if (configuration.has("impulse_falloff")) config.impulse_falloff = configuration["impulse_falloff"];
        if (configuration.has("impulse_delay")) config.impulse.delay = configuration["impulse_delay"];
        if (configuration.has("impulse_decay_per_second")) config.impulse.decay_per_second = configuration["impulse_decay_per_second"];
        if (configuration.has("control_suppression_seconds")) config.impulse.control_suppression_seconds = configuration["control_suppression_seconds"];
        if (configuration.has("preserve_navigation")) config.impulse.preserve_navigation = configuration["preserve_navigation"];
        if (configuration.has("impulse_priority")) config.impulse.priority = configuration["impulse_priority"];
        return encode_effect_volume_handle(crowd.create_effect_volume(config));
    }

    bool CrowdWorld2D::update_effect_volume(
        std::int64_t volume_handle, Vector2 position,
        Vector2 direction, Vector2 follow_offset)
    {
        return crowd.update_effect_volume(
            decode_effect_volume_handle(volume_handle),
            {position.x, position.y}, {direction.x, direction.y},
            {follow_offset.x, follow_offset.y});
    }

    bool CrowdWorld2D::remove_effect_volume(std::int64_t volume_handle)
    {
        return crowd.remove_effect_volume(decode_effect_volume_handle(volume_handle));
    }

    int CrowdWorld2D::get_effect_volume_count() const
    {
        return static_cast<int>(crowd.effect_volume_count());
    }

    Array CrowdWorld2D::take_effect_events()
    {
        Array result;
        for (const ffcore::EffectVolumeEvent &event : crowd.take_effect_events())
        {
            Dictionary item;
            item["kind"] = static_cast<int>(event.kind);
            item["volume_handle"] = encode_effect_volume_handle(event.volume);
            item["agent_handle"] = encode_handle(event.agent);
            item["position"] = Vector2(event.position.x, event.position.y);
            item["caller_token"] = event.caller_token;
            result.push_back(item);
        }
        return result;
    }
} // namespace godot
