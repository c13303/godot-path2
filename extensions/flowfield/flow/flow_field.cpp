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
    distance_field.assign(w * h, 0.0f);
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
    if (!ready)
    {
        godot::UtilityFunctions::print("compute_flow_dir: FlowField NOT READY");
        return Vec2();
    }

    Vec2i cell = world_to_cell(world_pos);

    // ✅ Vérifier que la cellule est valide
    if (cell.x < 0 || cell.x >= w || cell.y < 0 || cell.y >= h)
    {
        godot::UtilityFunctions::print(
            "compute_flow_dir: cell OUT OF BOUNDS (", cell.x, ",", cell.y, ")",
            " size=(", width, ",", height, ")");
        return Vec2();
    }

    Vec2 dir = sample_dir_cell(cell.x, cell.y);

    return dir;
}

Vec2i FlowField::world_to_cell(const Vec2 &world_pos) const
{
    int gx = static_cast<int>(std::floor(world_pos.x / tile));
    int gy = static_cast<int>(std::floor(world_pos.y / tile));
    return Vec2i(gx - cell_origin.x, gy - cell_origin.y);
}

Vec2 FlowField::cell_to_world(const Vec2i &cell) const
{
    int gx = cell_origin.x + cell.x;
    int gy = cell_origin.y + cell.y;
    return Vec2((gx + 0.5) * tile, (gy + 0.5) * tile);
}

void FlowField::clear()
{
    std::fill(dirs.begin(), dirs.end(), Vec2());
    std::fill(distance_field.begin(), distance_field.end(), 0.0f);
    t2_tiles.clear();
    computed_t2_radius = 0.0;
    ready = false;
    goal_cell = Vec2i(-1, -1);
}

void FlowField::set_dir(int x, int y, const Vec2 &dir)
{
    if (x < 0 || y < 0 || x >= w || y >= h)
        return;
    dirs[y * w + x] = dir;
    ready = true;
}

namespace
{
    struct FFNode
    {
        ffcore::Vec2i c;
        int32_t d;
        bool operator<(const FFNode &o) const { return d > o.d; }
    };

    inline int step_cost(const ffcore::Vec2i &a, const ffcore::Vec2i &b)
    {
        bool diag = (a.x != b.x) && (a.y != b.y);
        return diag ? 141 : 100;
    }
}

bool FlowField::is_cell_navigable(const Vec2i &cell) const
{
    if (cell.x < 0 || cell.y < 0 || cell.x >= w || cell.y >= h)
        return false;

    // Si la cellule est le but et que le champ est prêt, on la considère toujours navigable
    if (cell == goal_cell && ready)
        return true;

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

    // Définir une recherche locale en spirale (borne à 20 cellules de rayon)
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

void FlowField::set_t2_tiles(const std::vector<Vec2i> &tiles, double radius)
{
    t2_tiles = tiles;
    computed_t2_radius = radius;
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
    distance_field = src.distance_field;
}

bool FlowField::has_distance_field() const
{
    return w > 0 && h > 0 && distance_field.size() == static_cast<size_t>(w * h);
}

float FlowField::distance_at_cell(const Vec2i &cell) const
{
    if (!has_distance_field())
        return 0.0f;
    if (cell.x < 0 || cell.y < 0 || cell.x >= w || cell.y >= h)
        return 0.0f;
    return distance_field[cell.y * w + cell.x];
}

Vec2 FlowField::distance_gradient_at_cell(const Vec2i &cell) const
{
    if (!has_distance_field())
        return Vec2(0, 0);

    auto sample = [&](int cx, int cy) -> float
    {
        int sx = std::clamp(cx, 0, w - 1);
        int sy = std::clamp(cy, 0, h - 1);
        return distance_field[sy * w + sx];
    };

    int x = std::clamp(cell.x, 0, w - 1);
    int y = std::clamp(cell.y, 0, h - 1);

    float gx = sample(x + 1, y) - sample(x - 1, y);
    float gy = sample(x, y + 1) - sample(x, y - 1);

    return Vec2((double)gx, (double)gy);
}

void FlowField::set_distance_field(const std::vector<float> &df)
{
    if ((int)df.size() != w * h)
    {
        distance_field.assign(w * h, 0.0f);
        return;
    }
    distance_field = df;
}
