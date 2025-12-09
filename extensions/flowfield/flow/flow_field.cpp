#include "flow_field.h"
#include <algorithm>
#include <cmath>
#include <queue>
#include <unordered_set>
#include <sstream>
#include "../core/global_config.h"
#include <godot_cpp/variant/utility_functions.hpp>

using namespace ffcore;

FlowField::FlowField(int width, int height, double tile_size)
{
    resize(width, height);
    tile = tile_size;
}

void FlowField::resize(int width, int height)
{
    w = width;
    h = height;
    dirs.assign(w * h, Vec2());
    t2_tiles.clear();
    computed_t2_radius = 0.0;
    ready = (w > 0 && h > 0);
}

void FlowField::set_tile_size(double size)
{
    tile = size > 0.0 ? size : 1.0;
}

Vec2 FlowField::sample_dir_cell(int x, int y) const
{
    if (x < 0 || y < 0 || x >= w || y >= h)
        return Vec2();
    return dirs[y * w + x];
}

Vec2 FlowField::compute_flow_dir(const Vec2 &world_pos) const
{
    Vec2i cell = world_to_cell(world_pos);
    if (cell.x < 0 || cell.y < 0 || cell.x >= w || cell.y >= h)
        return Vec2();
    return dirs[cell.y * w + cell.x];
}

void FlowField::set_dir(int x, int y, const Vec2 &dir)
{
    if (x < 0 || y < 0 || x >= w || y >= h)
        return;
    dirs[y * w + x] = dir;
    ready = true;
}

void FlowField::clear()
{
    std::fill(dirs.begin(), dirs.end(), Vec2());
    t2_tiles.clear();
    computed_t2_radius = 0.0;
    ready = false;
}

Vec2i FlowField::world_to_cell(const Vec2 &world_pos) const
{
    return Vec2i((int)std::floor(world_pos.x / tile), (int)std::floor(world_pos.y / tile));
}

Vec2 FlowField::cell_to_world(const Vec2i &cell) const
{
    return Vec2((cell.x + 0.5) * tile, (cell.y + 0.5) * tile);
}

bool FlowField::is_cell_navigable(const Vec2i &cell) const
{
    if (cell.x < 0 || cell.y < 0 || cell.x >= w || cell.y >= h)
        return false;
    int idx = cell.y * w + cell.x;
    const Vec2 &d = dirs[idx];
    return !(std::abs(d.x) < 1e-6 && std::abs(d.y) < 1e-6);
}

Vec2i FlowField::find_nearest_navigable(Vec2i start) const
{
    if (is_cell_navigable(start))
        return start;

    Vec2i best = start;
    double best_d2 = 1e18;
    const int MAX_RADIUS = 20;
    for (int r = 1; r <= MAX_RADIUS; ++r)
    {
        for (int dx = -r; dx <= r; ++dx)
        {
            for (int dy = -r; dy <= r; ++dy)
            {
                Vec2i c = {start.x + dx, start.y + dy};
                if (!is_cell_navigable(c))
                    continue;
                double d2 = double(dx * dx + dy * dy);
                if (d2 < best_d2)
                {
                    best_d2 = d2;
                    best = c;
                }
            }
        }
        if (best_d2 < 1e18)
            break;
    }
    return best;
}

bool FlowField::is_cell_in_t2(const Vec2i &map_cell) const
{
    for (const auto &c : t2_tiles)
        if (c == map_cell)
            return true;
    return false;
}

void FlowField::copy_from(const FlowField &src)
{
    w = src.w;
    h = src.h;
    tile = src.tile;
    cell_origin = src.cell_origin;
    goal_cell = src.goal_cell;
    ready = src.ready;
    dirs = src.dirs;
    t2_tiles = src.t2_tiles;
    computed_t2_radius = src.computed_t2_radius;
    arrived_count = src.arrived_count;
    first_is_arrived = src.first_is_arrived;
    refcount = src.refcount;
    id = src.id;
}
