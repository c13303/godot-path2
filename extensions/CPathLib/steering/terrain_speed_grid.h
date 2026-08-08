#pragma once

#include "../core/types.h"
#include <unordered_map>
#include <vector>

namespace ffcore
{
    constexpr int DEFAULT_TERRAIN_SPEED_CHANNEL = 0;
    constexpr double TERRAIN_SPEED_NEUTRAL = 1.0;
    constexpr double TERRAIN_SPEED_MIN = 0.05;
    constexpr double TERRAIN_SPEED_MAX = 4.0;

    class TerrainSpeedGrid
    {
    public:
        bool valid_channel(int channel) const;
        double sanitize_multiplier(double multiplier) const;

        void set_cell(const Vec2i &cell, double multiplier, int channel = DEFAULT_TERRAIN_SPEED_CHANNEL);
        void set_cells(const std::vector<Vec2i> &cells, const std::vector<double> &multipliers, int channel = DEFAULT_TERRAIN_SPEED_CHANNEL);
        void clear_cell(const Vec2i &cell, int channel = DEFAULT_TERRAIN_SPEED_CHANNEL);
        void clear_cells(const std::vector<Vec2i> &cells, int channel = DEFAULT_TERRAIN_SPEED_CHANNEL);
        void replace_channel(const std::vector<Vec2i> &cells, const std::vector<double> &multipliers, int channel = DEFAULT_TERRAIN_SPEED_CHANNEL);
        void clear_channel(int channel = DEFAULT_TERRAIN_SPEED_CHANNEL);
        void clear_all();
        double multiplier_at(const Vec2i &cell, int channel = DEFAULT_TERRAIN_SPEED_CHANNEL) const;

    private:
        struct Vec2iKeyHash
        {
            size_t operator()(const Vec2i &v) const noexcept
            {
                return (size_t(v.x) * 73856093u) ^ (size_t(v.y) * 19349663u);
            }
        };

        struct CellSpeeds
        {
            std::unordered_map<int, double> by_channel;
        };

        std::unordered_map<Vec2i, CellSpeeds, Vec2iKeyHash> cells_by_position;
    };
}
