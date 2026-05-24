#pragma once

#include <cstdint>
#include <vector>
#include "../core/types.h"

namespace ffcore
{
    class SpatialGrid;
    class SteeringSystem;

    struct ProjectileTypeConfig
    {
        double speed = 400.0;
        double lifetime = 0.8;
        double radius = 8.0;

        double aoe_radius = 16.0;
        double smash_force = 200.0;
        double smash_friction_loss = 0.5;
        double smash_falloff = 1.0;
        bool smash_detach_flow = false;
        double smash_control_suppression = 1.0;
        double smash_control_suppression_duration = 0.0;

        int pool_size = 128;
    };

    struct Projectile
    {
        Vec2 pos;
        Vec2 vel;
        double lifetime_remaining = 0.0;
        int owner_agent_id = -1;
        int affected_smash_classes = 0;
        std::uint16_t type_id = 0;
        std::uint8_t active = 0;
        std::uint64_t fire_seq = 0;
    };

    class ProjectileSystem
    {
    public:
        ProjectileSystem();

        void set_grid(SpatialGrid *g) { grid = g; }
        void set_steering(SteeringSystem *s) { steering = s; }

        int register_type(const ProjectileTypeConfig &cfg);

        bool fire(int type_id,
                  const Vec2 &pos,
                  const Vec2 &dir,
                  int owner_agent_id,
                  int affected_smash_classes);

        void update(double delta);

        std::size_t type_count() const { return types.size(); }
        std::size_t active_count(int type_id) const;

        const std::vector<Projectile> &pool_for(int type_id) const { return pools[type_id]; }

    private:
        struct TypePool
        {
            // pool data lives in ProjectileSystem::pools[type_id]
            std::vector<std::uint16_t> free_list;
        };

        std::vector<ProjectileTypeConfig> types;
        std::vector<std::vector<Projectile>> pools;
        std::vector<TypePool> meta;

        SpatialGrid *grid = nullptr;
        SteeringSystem *steering = nullptr;
        std::uint64_t next_fire_seq = 1;

        std::uint16_t checkout_slot(int type_id);
    };
}
