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

        // Projectiles are stopped by walls (visual altitude is NOT physical;
        // collision uses the ground position p.pos only).
        bool stopped_by_walls = true;

        // End-of-life AoE: fired when the projectile despawns *without* hitting
        // an agent (lifetime expiry, or wall impact). An agent hit still uses the
        // normal smash params above. When disabled, despawn is silent.
        bool end_of_life_aoe_enabled = false;
        double end_aoe_radius = 16.0;
        double end_aoe_force = 200.0;
        double end_aoe_friction_loss = 0.5;
        double end_aoe_falloff = 1.0;
        bool end_aoe_detach_flow = false;
        double end_aoe_control_suppression = 0.0;
        double end_aoe_control_suppression_duration = 0.0;

        int pool_size = 128;
    };

    // Static wall mask in cell space (1 = wall). World->cell uses origin + tile.
    struct WallGrid
    {
        int origin_x = 0;
        int origin_y = 0;
        int width = 0;
        int height = 0;
        double tile_size = 1.0;
        std::vector<std::uint8_t> mask; // size = width * height, 1 = wall

        bool ready() const { return width > 0 && height > 0 && tile_size > 0.0; }

        Vec2i world_to_cell(const Vec2 &p) const
        {
            return Vec2i(static_cast<int>(std::floor(p.x / tile_size)),
                         static_cast<int>(std::floor(p.y / tile_size)));
        }

        bool is_wall_cell(const Vec2i &c) const
        {
            int lx = c.x - origin_x;
            int ly = c.y - origin_y;
            if (lx < 0 || ly < 0 || lx >= width || ly >= height)
                return false; // outside the known map = not a wall
            return mask[static_cast<std::size_t>(ly) * width + lx] != 0;
        }
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

        // Upload/refresh the static wall mask. Call when walls change (build/destroy).
        void set_wall_grid(int origin_x, int origin_y, int width, int height,
                           double tile_size, const std::vector<std::uint8_t> &mask);
        void clear_wall_grid() { walls = WallGrid{}; }

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
        WallGrid walls;
        std::uint64_t next_fire_seq = 1;

        std::uint16_t checkout_slot(int type_id);

        // Raycast the projectile's ground path old->new across wall cells. Returns
        // true and writes the impact point if a wall is hit; false otherwise.
        bool raycast_walls(const Vec2 &from, const Vec2 &to, Vec2 &out_impact) const;

        // Apply the configured end-of-life AoE smash at the given point.
        void trigger_end_aoe(const ProjectileTypeConfig &cfg, const Projectile &p, const Vec2 &at);
    };
}
