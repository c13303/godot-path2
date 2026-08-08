#include "projectile_world_2d.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>

namespace godot
{
    void ProjectileWorld2D::_bind_methods()
    {
        ClassDB::bind_method(D_METHOD("set_automatic_step", "enabled"), &ProjectileWorld2D::set_automatic_step);
        ClassDB::bind_method(D_METHOD("is_automatic_step_enabled"), &ProjectileWorld2D::is_automatic_step_enabled);
        ClassDB::bind_method(D_METHOD("step", "delta"), &ProjectileWorld2D::step);
        ClassDB::bind_method(D_METHOD("set_paused", "paused"), &ProjectileWorld2D::set_paused);
        ClassDB::bind_method(D_METHOD("is_paused"), &ProjectileWorld2D::is_paused);
        ClassDB::bind_method(D_METHOD("set_crowd_world", "crowd"), &ProjectileWorld2D::set_crowd_world);
        ClassDB::bind_method(D_METHOD("create_projectile_type", "configuration"), &ProjectileWorld2D::create_projectile_type);
        ClassDB::bind_method(D_METHOD("update_projectile_type", "type_handle", "configuration"), &ProjectileWorld2D::update_projectile_type);
        ClassDB::bind_method(D_METHOD("remove_projectile_type", "type_handle"), &ProjectileWorld2D::remove_projectile_type);
        ClassDB::bind_method(D_METHOD("get_projectile_type_handles"), &ProjectileWorld2D::get_projectile_type_handles);
        ClassDB::bind_method(D_METHOD("spawn_projectile", "type_handle", "position", "direction", "inherited_velocity", "owner_agent_handle", "caller_token"), &ProjectileWorld2D::spawn_projectile, DEFVAL(Vector2()), DEFVAL(0), DEFVAL(0));
        ClassDB::bind_method(D_METHOD("set_static_collision_grid", "bounds", "cell_size", "world_origin", "cells", "masks"), &ProjectileWorld2D::set_static_collision_grid);
        ClassDB::bind_method(D_METHOD("clear_static_collision_grid"), &ProjectileWorld2D::clear_static_collision_grid);
        ClassDB::bind_method(D_METHOD("get_active_positions", "type_handle"), &ProjectileWorld2D::get_active_positions);
        ClassDB::bind_method(D_METHOD("get_active_projectile_states", "type_handle"), &ProjectileWorld2D::get_active_projectile_states);
        ClassDB::bind_method(D_METHOD("get_active_count", "type_handle"), &ProjectileWorld2D::get_active_count);
        ClassDB::bind_method(D_METHOD("get_type_count"), &ProjectileWorld2D::get_type_count);
        ClassDB::bind_method(D_METHOD("take_impacts"), &ProjectileWorld2D::take_impacts);
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "automatic_step"),
                     "set_automatic_step", "is_automatic_step_enabled");
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "paused"), "set_paused", "is_paused");
    }

    std::int64_t ProjectileWorld2D::encode_type_handle(ffcore::ProjectileTypeHandle handle)
    {
        return static_cast<std::int64_t>(
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index);
    }

    ffcore::ProjectileTypeHandle ProjectileWorld2D::decode_type_handle(std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    std::int64_t ProjectileWorld2D::encode_agent_handle(ffcore::AgentHandle handle)
    {
        return static_cast<std::int64_t>(
            (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index);
    }

    ffcore::AgentHandle ProjectileWorld2D::decode_agent_handle(std::int64_t encoded)
    {
        const std::uint64_t value = static_cast<std::uint64_t>(encoded);
        return {static_cast<std::uint32_t>(value), static_cast<std::uint32_t>(value >> 32)};
    }

    ffcore::ProjectileProfile ProjectileWorld2D::make_profile(const Dictionary &configuration)
    {
        ffcore::ProjectileProfile profile;
        if (configuration.has("speed"))
            profile.speed = configuration["speed"];
        if (configuration.has("lifetime"))
            profile.lifetime = configuration["lifetime"];
        if (configuration.has("radius"))
            profile.radius = configuration["radius"];
        if (configuration.has("static_collision_mask"))
            profile.static_collision_mask = static_cast<std::uint32_t>(
                static_cast<std::int64_t>(configuration["static_collision_mask"]));
        if (configuration.has("target_category_mask"))
            profile.target_category_mask = static_cast<std::uint32_t>(
                static_cast<std::int64_t>(configuration["target_category_mask"]));
        if (configuration.has("pool_size"))
            profile.pool_size = static_cast<std::size_t>(std::max(
                1, static_cast<int>(configuration["pool_size"])));
        return profile;
    }

    void ProjectileWorld2D::_physics_process(double delta)
    {
        if (automatic_step)
            world.update(delta);
    }

    void ProjectileWorld2D::set_crowd_world(CrowdWorld2D *crowd)
    {
        world.set_crowd_world(crowd == nullptr ? nullptr : &crowd->core_world());
    }

    std::int64_t ProjectileWorld2D::create_projectile_type(
        const Dictionary &configuration)
    {
        return encode_type_handle(world.create_type(make_profile(configuration)));
    }

    bool ProjectileWorld2D::update_projectile_type(
        std::int64_t type_handle, const Dictionary &configuration)
    {
        return world.update_type(
            decode_type_handle(type_handle), make_profile(configuration));
    }

    bool ProjectileWorld2D::remove_projectile_type(std::int64_t type_handle)
    {
        return world.remove_type(decode_type_handle(type_handle));
    }

    PackedInt64Array ProjectileWorld2D::get_projectile_type_handles() const
    {
        const std::vector<ffcore::ProjectileTypeHandle> handles = world.active_types();
        PackedInt64Array result;
        result.resize(static_cast<int>(handles.size()));
        for (int index = 0; index < static_cast<int>(handles.size()); ++index)
            result.set(index, encode_type_handle(handles[index]));
        return result;
    }

    std::int64_t ProjectileWorld2D::spawn_projectile(
        std::int64_t type_handle, Vector2 position, Vector2 direction,
        Vector2 inherited_velocity, std::int64_t owner_agent_handle,
        std::int64_t caller_token)
    {
        return static_cast<std::int64_t>(world.spawn(
            decode_type_handle(type_handle), {position.x, position.y},
            {direction.x, direction.y},
            {inherited_velocity.x, inherited_velocity.y},
            decode_agent_handle(owner_agent_handle), caller_token));
    }

    bool ProjectileWorld2D::set_static_collision_grid(
        Rect2i bounds, double cell_size, Vector2 world_origin,
        const PackedVector2Array &cells, const PackedInt64Array &masks)
    {
        if (bounds.size.x <= 0 || bounds.size.y <= 0 || cells.size() != masks.size())
            return false;
        ffcore::ProjectileStaticGrid grid;
        grid.cell_origin = {bounds.position.x, bounds.position.y};
        grid.world_origin = {world_origin.x, world_origin.y};
        grid.width = bounds.size.x;
        grid.height = bounds.size.y;
        grid.cell_size = cell_size;
        grid.masks.assign(static_cast<std::size_t>(grid.width * grid.height), 0);
        for (int index = 0; index < cells.size(); ++index)
        {
            const int x = static_cast<int>(cells[index].x) - grid.cell_origin.x;
            const int y = static_cast<int>(cells[index].y) - grid.cell_origin.y;
            if (x < 0 || y < 0 || x >= grid.width || y >= grid.height)
                return false;
            grid.masks[static_cast<std::size_t>(y * grid.width + x)] |=
                static_cast<std::uint32_t>(masks[index]);
        }
        return world.set_static_collision_grid(grid);
    }

    PackedVector2Array ProjectileWorld2D::get_active_positions(
        std::int64_t type_handle) const
    {
        const std::vector<ffcore::ProjectileState> states =
            world.active_projectiles(decode_type_handle(type_handle));
        PackedVector2Array result;
        result.resize(static_cast<int>(states.size()));
        for (int index = 0; index < static_cast<int>(states.size()); ++index)
            result.set(index, Vector2(states[index].position.x, states[index].position.y));
        return result;
    }

    Array ProjectileWorld2D::get_active_projectile_states(std::int64_t type_handle) const
    {
        Array result;
        const ffcore::ProjectileTypeHandle decoded = decode_type_handle(type_handle);
        const ffcore::ProjectileProfile *profile = world.get_type(decoded);
        if (profile == nullptr)
            return result;
        const double lifetime = std::max(0.000001, profile->lifetime);
        for (const ffcore::ProjectileState &state : world.active_projectiles(decoded))
        {
            Dictionary item;
            item["instance_id"] = static_cast<std::int64_t>(state.instance_id);
            item["position"] = Vector2(state.position.x, state.position.y);
            item["velocity"] = Vector2(state.velocity.x, state.velocity.y);
            item["age_progress"] = std::clamp(
                1.0 - state.lifetime_remaining / lifetime, 0.0, 1.0);
            item["caller_token"] = state.caller_token;
            result.push_back(item);
        }
        return result;
    }

    int ProjectileWorld2D::get_active_count(std::int64_t type_handle) const
    {
        return static_cast<int>(world.active_count(decode_type_handle(type_handle)));
    }

    int ProjectileWorld2D::get_type_count() const
    {
        return static_cast<int>(world.type_count());
    }

    Array ProjectileWorld2D::take_impacts()
    {
        Array result;
        for (const ffcore::ProjectileImpactEvent &event : world.take_impacts())
        {
            Dictionary item;
            item["kind"] = static_cast<int>(event.kind);
            item["projectile_instance_id"] =
                static_cast<std::int64_t>(event.projectile_instance_id);
            item["type_handle"] = encode_type_handle(event.type);
            item["owner_agent_handle"] = encode_agent_handle(event.owner);
            item["hit_agent_handle"] = encode_agent_handle(event.hit_agent);
            item["position"] = Vector2(event.position.x, event.position.y);
            item["direction"] = Vector2(event.direction.x, event.direction.y);
            item["collider_cell"] = Vector2i(event.collider_cell.x, event.collider_cell.y);
            item["collider_mask"] = static_cast<std::int64_t>(event.collider_mask);
            item["caller_token"] = event.caller_token;
            result.push_back(item);
        }
        return result;
    }
} // namespace godot
