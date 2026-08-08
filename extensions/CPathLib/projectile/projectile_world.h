#pragma once

#include "../core/types.h"
#include "../crowd/agent_world.h"

#include <cstdint>
#include <limits>
#include <vector>

namespace ffcore
{
    class CrowdWorld;

    struct ProjectileTypeHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;
        bool is_valid() const { return index != 0; }
        bool operator==(const ProjectileTypeHandle &other) const
        { return index == other.index && generation == other.generation; }
    };

    struct ProjectileProfile
    {
        double speed = 400.0;
        double lifetime = 0.8;
        double radius = 8.0;
        std::uint32_t static_collision_mask = 1;
        std::uint32_t target_category_mask = std::numeric_limits<std::uint32_t>::max();
        std::size_t pool_size = 128;
    };

    struct ProjectileState
    {
        std::uint64_t instance_id = 0;
        ProjectileTypeHandle type;
        Vec2 position;
        Vec2 velocity;
        double lifetime_remaining = 0.0;
        AgentHandle owner;
        std::int64_t caller_token = 0;
        std::uint64_t spawn_sequence = 0;
        bool active = false;
    };

    enum class ProjectileImpactKind
    {
        StaticCollider,
        LifetimeExpired,
        Agent
    };

    struct ProjectileImpactEvent
    {
        ProjectileImpactKind kind = ProjectileImpactKind::LifetimeExpired;
        std::uint64_t projectile_instance_id = 0;
        ProjectileTypeHandle type;
        AgentHandle owner;
        AgentHandle hit_agent;
        Vec2 position;
        Vec2 direction;
        Vec2i collider_cell;
        std::uint32_t collider_mask = 0;
        std::int64_t caller_token = 0;
    };

    struct ProjectileStaticGrid
    {
        Vec2i cell_origin;
        Vec2 world_origin;
        int width = 0;
        int height = 0;
        double cell_size = 1.0;
        std::vector<std::uint32_t> masks;

        bool valid() const;
        Vec2i world_to_cell(const Vec2 &position) const;
        std::uint32_t mask_at(const Vec2i &cell) const;
    };

    class ProjectileWorld
    {
    private:
        struct TypeSlot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
            ProjectileProfile profile;
            std::vector<ProjectileState> pool;
        };

        std::vector<TypeSlot> types = std::vector<TypeSlot>(1);
        ProjectileStaticGrid static_grid;
        CrowdWorld *crowd = nullptr;
        std::vector<ProjectileImpactEvent> impacts;
        std::uint64_t next_instance_id = 1;
        std::uint64_t next_spawn_sequence = 1;
        bool paused = false;

        static ProjectileProfile sanitize(const ProjectileProfile &profile);
        ProjectileState *checkout(TypeSlot &slot, ProjectileTypeHandle type);
        bool raycast_static(const Vec2 &from, const Vec2 &to, std::uint32_t mask,
                            Vec2 &impact, Vec2i &cell, std::uint32_t &collider_mask) const;
        AgentHandle raycast_agents(const ProjectileState &projectile,
                                   const ProjectileProfile &profile,
                                   const Vec2 &from, const Vec2 &to,
                                   Vec2 &impact) const;

    public:
        void set_crowd_world(CrowdWorld *world) { crowd = world; }
        void set_paused(bool value) { paused = value; }
        bool is_paused() const { return paused; }
        bool set_static_collision_grid(const ProjectileStaticGrid &grid);
        void clear_static_collision_grid() { static_grid = {}; }

        ProjectileTypeHandle create_type(const ProjectileProfile &profile);
        bool update_type(ProjectileTypeHandle handle, const ProjectileProfile &profile);
        bool remove_type(ProjectileTypeHandle handle);
        const ProjectileProfile *get_type(ProjectileTypeHandle handle) const;
        std::vector<ProjectileTypeHandle> active_types() const;

        std::uint64_t spawn(ProjectileTypeHandle type, const Vec2 &position,
                            const Vec2 &direction, const Vec2 &inherited_velocity = {},
                            AgentHandle owner = {}, std::int64_t caller_token = 0);
        void update(double delta);
        std::vector<ProjectileImpactEvent> take_impacts();
        std::vector<ProjectileState> active_projectiles(ProjectileTypeHandle type) const;
        std::size_t active_count(ProjectileTypeHandle type) const;
        std::size_t type_count() const;
    };
} // namespace ffcore
