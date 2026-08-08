#pragma once

#include "../core/types.h"
#include "../grid/spatial_grid.h"

#include <cstdint>
#include <vector>

namespace ffcore
{
    struct StaticObstacleHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;
        bool is_valid() const { return index != 0; }
        bool operator==(const StaticObstacleHandle &other) const
        { return index == other.index && generation == other.generation; }
    };

    struct StaticObstacle
    {
        StaticObstacleHandle handle;
        Vec2 position;
        double radius = 0.001;
        double push_strength = 1.0;
    };

    class StaticObstacleStore
    {
    private:
        struct Slot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
            StaticObstacle obstacle;
        };

        std::vector<Slot> slots = std::vector<Slot>(1);
        SpatialGrid spatial;
        double maximum_radius = 0.0;

        void recompute_maximum_radius();

    public:
        explicit StaticObstacleStore(double spatial_cell_size = 32.0)
            : spatial(spatial_cell_size) {}

        StaticObstacleHandle create(const Vec2 &position, double radius, double push_strength);
        bool update(StaticObstacleHandle handle, const Vec2 &position,
                    double radius, double push_strength);
        bool remove(StaticObstacleHandle handle);
        void clear();
        const StaticObstacle *get(StaticObstacleHandle handle) const;
        std::vector<StaticObstacleHandle> query(const Vec2 &position, double radius) const;
        std::vector<StaticObstacleHandle> active_handles() const;
        double max_radius() const { return maximum_radius; }
        std::size_t size() const;
    };
} // namespace ffcore
