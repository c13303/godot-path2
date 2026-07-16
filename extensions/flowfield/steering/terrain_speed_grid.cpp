#include "terrain_speed_grid.h"
#include <algorithm>
#include <cmath>

using namespace ffcore;

bool TerrainSpeedGrid::valid_channel(int channel) const
{
    return channel >= 0;
}

double TerrainSpeedGrid::sanitize_multiplier(double multiplier) const
{
    if (!std::isfinite(multiplier) || multiplier <= 0.0)
        return TERRAIN_SPEED_NEUTRAL;
    return std::clamp(multiplier, TERRAIN_SPEED_MIN, TERRAIN_SPEED_MAX);
}

void TerrainSpeedGrid::set_cell(const Vec2i &cell, double multiplier, int channel)
{
    if (!valid_channel(channel))
        return;

    const double sanitized = sanitize_multiplier(multiplier);
    if (channel == DEFAULT_TERRAIN_SPEED_CHANNEL && std::abs(sanitized - TERRAIN_SPEED_NEUTRAL) <= 0.000001)
    {
        clear_cell(cell, channel);
        return;
    }

    cells_by_position[cell].by_channel[channel] = sanitized;
}

void TerrainSpeedGrid::set_cells(const std::vector<Vec2i> &cells, const std::vector<double> &multipliers, int channel)
{
    if (cells.size() != multipliers.size() || !valid_channel(channel))
        return;
    for (size_t i = 0; i < cells.size(); ++i)
        set_cell(cells[i], multipliers[i], channel);
}

void TerrainSpeedGrid::clear_cell(const Vec2i &cell, int channel)
{
    if (!valid_channel(channel))
        return;
    auto it = cells_by_position.find(cell);
    if (it == cells_by_position.end())
        return;
    it->second.by_channel.erase(channel);
    if (it->second.by_channel.empty())
        cells_by_position.erase(it);
}

void TerrainSpeedGrid::clear_cells(const std::vector<Vec2i> &cells, int channel)
{
    if (!valid_channel(channel))
        return;
    for (const Vec2i &cell : cells)
        clear_cell(cell, channel);
}

void TerrainSpeedGrid::replace_channel(const std::vector<Vec2i> &cells, const std::vector<double> &multipliers, int channel)
{
    if (cells.size() != multipliers.size() || !valid_channel(channel))
        return;
    clear_channel(channel);
    for (size_t i = 0; i < cells.size(); ++i)
        set_cell(cells[i], multipliers[i], channel);
}

void TerrainSpeedGrid::clear_channel(int channel)
{
    if (!valid_channel(channel))
        return;
    for (auto it = cells_by_position.begin(); it != cells_by_position.end();)
    {
        it->second.by_channel.erase(channel);
        if (it->second.by_channel.empty())
            it = cells_by_position.erase(it);
        else
            ++it;
    }
}

void TerrainSpeedGrid::clear_all()
{
    cells_by_position.clear();
}

double TerrainSpeedGrid::multiplier_at(const Vec2i &cell, int channel) const
{
    if (!valid_channel(channel))
        channel = DEFAULT_TERRAIN_SPEED_CHANNEL;

    auto cell_it = cells_by_position.find(cell);
    if (cell_it == cells_by_position.end())
        return TERRAIN_SPEED_NEUTRAL;

    auto channel_it = cell_it->second.by_channel.find(channel);
    if (channel_it != cell_it->second.by_channel.end())
        return channel_it->second;

    auto default_it = cell_it->second.by_channel.find(DEFAULT_TERRAIN_SPEED_CHANNEL);
    if (default_it != cell_it->second.by_channel.end())
        return default_it->second;

    return TERRAIN_SPEED_NEUTRAL;
}
