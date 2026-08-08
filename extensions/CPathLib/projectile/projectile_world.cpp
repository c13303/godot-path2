#include "projectile_world.h"

#include "../crowd/crowd_world.h"

#include <algorithm>
#include <cmath>

namespace ffcore
{
    bool ProjectileStaticGrid::valid() const
    {
        return width > 0 && height > 0 && std::isfinite(cell_size) && cell_size > 0.0 &&
            masks.size() == static_cast<std::size_t>(width * height);
    }

    Vec2i ProjectileStaticGrid::world_to_cell(const Vec2 &position) const
    {
        const Vec2 local = (position - world_origin) / cell_size;
        return {cell_origin.x + static_cast<int>(std::floor(local.x)),
                cell_origin.y + static_cast<int>(std::floor(local.y))};
    }

    std::uint32_t ProjectileStaticGrid::mask_at(const Vec2i &cell) const
    {
        const int x = cell.x - cell_origin.x;
        const int y = cell.y - cell_origin.y;
        if (x < 0 || y < 0 || x >= width || y >= height)
            return 0;
        return masks[static_cast<std::size_t>(y * width + x)];
    }

    ProjectileProfile ProjectileWorld::sanitize(const ProjectileProfile &requested)
    {
        ProjectileProfile profile = requested;
        profile.speed = std::isfinite(profile.speed) ? std::max(0.0, profile.speed) : 400.0;
        profile.lifetime = std::isfinite(profile.lifetime) ? std::max(0.0, profile.lifetime) : 0.8;
        profile.radius = std::isfinite(profile.radius) ? std::max(0.0, profile.radius) : 8.0;
        profile.pool_size = std::max<std::size_t>(1, profile.pool_size);
        return profile;
    }

    bool ProjectileWorld::set_static_collision_grid(const ProjectileStaticGrid &grid)
    {
        if (!grid.valid())
            return false;
        static_grid = grid;
        return true;
    }

    ProjectileTypeHandle ProjectileWorld::create_type(const ProjectileProfile &requested)
    {
        std::uint32_t index = 1;
        while (index < types.size() && types[index].occupied)
            ++index;
        if (index == types.size())
            types.push_back({});
        TypeSlot &slot = types[index];
        slot.occupied = true;
        slot.profile = sanitize(requested);
        slot.pool.assign(slot.profile.pool_size, {});
        return {index, slot.generation};
    }

    bool ProjectileWorld::update_type(
        ProjectileTypeHandle handle, const ProjectileProfile &requested)
    {
        if (get_type(handle) == nullptr)
            return false;
        TypeSlot &slot = types[handle.index];
        const ProjectileProfile profile = sanitize(requested);
        if (profile.pool_size != slot.pool.size())
        {
            for (const ProjectileState &state : slot.pool)
            {
                if (state.active)
                    return false;
            }
            slot.pool.assign(profile.pool_size, {});
        }
        slot.profile = profile;
        return true;
    }

    bool ProjectileWorld::remove_type(ProjectileTypeHandle handle)
    {
        if (get_type(handle) == nullptr)
            return false;
        TypeSlot &slot = types[handle.index];
        slot.occupied = false;
        slot.profile = {};
        slot.pool.clear();
        ++slot.generation;
        if (slot.generation == 0)
            slot.generation = 1;
        return true;
    }

    const ProjectileProfile *ProjectileWorld::get_type(ProjectileTypeHandle handle) const
    {
        if (handle.index >= types.size())
            return nullptr;
        const TypeSlot &slot = types[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.profile : nullptr;
    }

    std::vector<ProjectileTypeHandle> ProjectileWorld::active_types() const
    {
        std::vector<ProjectileTypeHandle> handles;
        handles.reserve(type_count());
        for (std::size_t index = 1; index < types.size(); ++index)
        {
            if (types[index].occupied)
                handles.push_back({static_cast<std::uint32_t>(index), types[index].generation});
        }
        return handles;
    }

    ProjectileState *ProjectileWorld::checkout(TypeSlot &slot, ProjectileTypeHandle type)
    {
        ProjectileState *oldest = nullptr;
        for (ProjectileState &state : slot.pool)
        {
            if (!state.active)
                return &state;
            if (oldest == nullptr || state.spawn_sequence < oldest->spawn_sequence)
                oldest = &state;
        }
        if (oldest != nullptr)
            *oldest = {};
        (void)type;
        return oldest;
    }

    std::uint64_t ProjectileWorld::spawn(
        ProjectileTypeHandle type, const Vec2 &position, const Vec2 &direction,
        const Vec2 &inherited_velocity, AgentHandle owner, std::int64_t caller_token)
    {
        if (get_type(type) == nullptr || !std::isfinite(position.x) ||
            !std::isfinite(position.y) || !std::isfinite(direction.x) ||
            !std::isfinite(direction.y) || !std::isfinite(inherited_velocity.x) ||
            !std::isfinite(inherited_velocity.y))
            return 0;
        const Vec2 normalized = direction.normalized();
        if (normalized.is_zero())
            return 0;
        TypeSlot &slot = types[type.index];
        ProjectileState *state = checkout(slot, type);
        if (state == nullptr)
            return 0;
        state->instance_id = next_instance_id++;
        if (next_instance_id == 0)
            next_instance_id = 1;
        state->type = type;
        state->position = position;
        state->velocity = normalized * slot.profile.speed + inherited_velocity;
        state->lifetime_remaining = slot.profile.lifetime;
        state->owner = owner;
        state->caller_token = caller_token;
        state->spawn_sequence = next_spawn_sequence++;
        state->active = true;
        return state->instance_id;
    }

    bool ProjectileWorld::raycast_static(
        const Vec2 &from, const Vec2 &to, std::uint32_t mask,
        Vec2 &impact, Vec2i &hit_cell, std::uint32_t &collider_mask) const
    {
        if (!static_grid.valid() || mask == 0)
            return false;
        Vec2i cell = static_grid.world_to_cell(from);
        const std::uint32_t starting_mask = static_grid.mask_at(cell) & mask;
        if (starting_mask != 0)
        {
            impact = from;
            hit_cell = cell;
            collider_mask = starting_mask;
            return true;
        }

        const Vec2 delta = to - from;
        const Vec2i end_cell = static_grid.world_to_cell(to);
        const int step_x = delta.x > 0.0 ? 1 : (delta.x < 0.0 ? -1 : 0);
        const int step_y = delta.y > 0.0 ? 1 : (delta.y < 0.0 ? -1 : 0);
        const double infinity = std::numeric_limits<double>::infinity();
        const double delta_x = step_x == 0 ? infinity :
            std::abs(static_grid.cell_size / delta.x);
        const double delta_y = step_y == 0 ? infinity :
            std::abs(static_grid.cell_size / delta.y);
        const int local_x = cell.x - static_grid.cell_origin.x;
        const int local_y = cell.y - static_grid.cell_origin.y;
        const double boundary_x = static_grid.world_origin.x +
            (local_x + (step_x > 0 ? 1 : 0)) * static_grid.cell_size;
        const double boundary_y = static_grid.world_origin.y +
            (local_y + (step_y > 0 ? 1 : 0)) * static_grid.cell_size;
        double next_x = step_x == 0 ? infinity : (boundary_x - from.x) / delta.x;
        double next_y = step_y == 0 ? infinity : (boundary_y - from.y) / delta.y;
        int guard = std::abs(end_cell.x - cell.x) + std::abs(end_cell.y - cell.y) + 2;
        while (guard-- > 0 && cell != end_cell)
        {
            double fraction = 0.0;
            if (next_x < next_y)
            {
                fraction = next_x;
                next_x += delta_x;
                cell.x += step_x;
            }
            else
            {
                fraction = next_y;
                next_y += delta_y;
                cell.y += step_y;
            }
            if (fraction > 1.0)
                break;
            const std::uint32_t matched = static_grid.mask_at(cell) & mask;
            if (matched != 0)
            {
                impact = from + delta * fraction;
                hit_cell = cell;
                collider_mask = matched;
                return true;
            }
        }
        return false;
    }

    AgentHandle ProjectileWorld::raycast_agents(
        const ProjectileState &projectile, const ProjectileProfile &profile,
        const Vec2 &from, const Vec2 &to, Vec2 &impact) const
    {
        if (crowd == nullptr || profile.target_category_mask == 0)
            return {};
        const Vec2 delta = to - from;
        const double length = delta.length();
        const Vec2 center = from + delta * 0.5;
        const std::vector<AgentHandle> candidates = crowd->query_agents(
            center, length * 0.5 + profile.radius,
            profile.target_category_mask, projectile.owner);
        double best_fraction = std::numeric_limits<double>::infinity();
        AgentHandle best;
        for (AgentHandle handle : candidates)
        {
            const CrowdAgentState *agent = crowd->get_agent(handle);
            if (agent == nullptr)
                continue;
            const double radius = profile.radius + agent->profile.radius;
            const Vec2 offset = from - agent->position;
            const double a = delta.length_squared();
            const double b = 2.0 * offset.dot(delta);
            const double c = offset.length_squared() - radius * radius;
            double fraction = 0.0;
            if (c > 0.0)
            {
                if (a <= 1e-12)
                    continue;
                const double discriminant = b * b - 4.0 * a * c;
                if (discriminant < 0.0)
                    continue;
                fraction = (-b - std::sqrt(discriminant)) / (2.0 * a);
                if (fraction < 0.0 || fraction > 1.0)
                    continue;
            }
            if (fraction < best_fraction ||
                (fraction == best_fraction && (!best.is_valid() || handle.index < best.index)))
            {
                best_fraction = fraction;
                best = handle;
            }
        }
        if (best.is_valid())
            impact = from + delta * best_fraction;
        return best;
    }

    void ProjectileWorld::update(double delta)
    {
        if (paused || !std::isfinite(delta) || delta <= 0.0)
            return;
        for (std::size_t type_index = 1; type_index < types.size(); ++type_index)
        {
            TypeSlot &slot = types[type_index];
            if (!slot.occupied)
                continue;
            const ProjectileProfile &profile = slot.profile;
            for (ProjectileState &projectile : slot.pool)
            {
                if (!projectile.active)
                    continue;
                const Vec2 from = projectile.position;
                const Vec2 to = from + projectile.velocity * delta;
                Vec2 static_impact;
                Vec2i collider_cell;
                std::uint32_t collider_mask = 0;
                const bool hit_static = raycast_static(
                    from, to, profile.static_collision_mask,
                    static_impact, collider_cell, collider_mask);
                Vec2 agent_impact;
                const AgentHandle hit_agent = raycast_agents(
                    projectile, profile, from, to, agent_impact);

                const double static_distance = hit_static
                    ? from.distance_to(static_impact) : std::numeric_limits<double>::infinity();
                const double agent_distance = hit_agent.is_valid()
                    ? from.distance_to(agent_impact) : std::numeric_limits<double>::infinity();
                if (hit_static || hit_agent.is_valid())
                {
                    const bool agent_first = agent_distance < static_distance;
                    projectile.position = agent_first ? agent_impact : static_impact;
                    impacts.push_back({
                        agent_first ? ProjectileImpactKind::Agent
                                    : ProjectileImpactKind::StaticCollider,
                        projectile.instance_id, projectile.type, projectile.owner,
                        agent_first ? hit_agent : AgentHandle(), projectile.position,
                        projectile.velocity.normalized(),
                        agent_first ? Vec2i() : collider_cell,
                        agent_first ? 0u : collider_mask, projectile.caller_token});
                    projectile.active = false;
                    continue;
                }

                projectile.position = to;
                projectile.lifetime_remaining -= delta;
                if (projectile.lifetime_remaining <= 0.0)
                {
                    impacts.push_back({
                        ProjectileImpactKind::LifetimeExpired,
                        projectile.instance_id, projectile.type, projectile.owner, {},
                        projectile.position, projectile.velocity.normalized(), {}, 0,
                        projectile.caller_token});
                    projectile.active = false;
                }
            }
        }
    }

    std::vector<ProjectileImpactEvent> ProjectileWorld::take_impacts()
    {
        std::vector<ProjectileImpactEvent> result;
        result.swap(impacts);
        return result;
    }

    std::vector<ProjectileState> ProjectileWorld::active_projectiles(
        ProjectileTypeHandle type) const
    {
        std::vector<ProjectileState> result;
        if (get_type(type) == nullptr)
            return result;
        for (const ProjectileState &state : types[type.index].pool)
        {
            if (state.active)
                result.push_back(state);
        }
        std::sort(result.begin(), result.end(), [](const ProjectileState &left,
                                                   const ProjectileState &right)
        {
            return left.spawn_sequence < right.spawn_sequence;
        });
        return result;
    }

    std::size_t ProjectileWorld::active_count(ProjectileTypeHandle type) const
    {
        return active_projectiles(type).size();
    }

    std::size_t ProjectileWorld::type_count() const
    {
        return static_cast<std::size_t>(std::count_if(
            types.begin(), types.end(), [](const TypeSlot &slot) { return slot.occupied; }));
    }
} // namespace ffcore
