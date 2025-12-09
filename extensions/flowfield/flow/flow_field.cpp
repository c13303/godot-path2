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

void FlowField::compute_t2_tiles(int group_size, const FormationFootprint &footprint)
{
    t2_tiles.clear();
    computed_t2_radius = 0.0;
    if (!ready || !has_goal())
        return;

    const int fw = std::max(1, footprint.w);
    const int fh = std::max(1, footprint.h);
    double angle = footprint.angle;
    double cos_a = std::cos(angle);
    double sin_a = std::sin(angle);

    Vec2 goal_center = cell_to_world(goal_cell);
    double tile = std::max(1.0, this->tile_size());

    std::vector<Vec2i> slots;
    slots.reserve(fw * fh);
    std::unordered_set<int64_t> seen;
    auto encode = [](const Vec2i &c) -> int64_t
    { return (int64_t(c.x) << 32) ^ (uint32_t)c.y; };

    for (int jy = 0; jy < fh; ++jy)
        for (int ix = 0; ix < fw; ++ix)
        {
            double lx = (ix - fw * 0.5 + 0.5) * tile;
            double ly = (jy - fh * 0.5 + 0.5) * tile;
            double rx = cos_a * lx - sin_a * ly;
            double ry = sin_a * lx + cos_a * ly;
            Vec2 world_pos = goal_center + Vec2(rx, ry);
            Vec2i rel = world_to_cell(world_pos);
            if (!is_cell_navigable(rel))
                continue;
            Vec2i map_cell(rel.x + cell_origin.x, rel.y + cell_origin.y);
            int64_t key = encode(map_cell);
            if (seen.insert(key).second)
                slots.push_back(map_cell);
        }

    if (slots.empty())
        return;

    std::sort(slots.begin(), slots.end(), [](const Vec2i &a, const Vec2i &b)
              {
                  if (a.y == b.y)
                      return a.x < b.x;
                  return a.y < b.y;
              });

    int target = std::min<int>(std::max(1, group_size), slots.size());
    slots.resize(target);

    double max_d2 = 0.0;
    for (const auto &c : slots)
    {
        t2_tiles.push_back(c);
        Vec2i rel(c.x - cell_origin.x, c.y - cell_origin.y);
        double d2 = (cell_to_world(rel) - goal_center).length_squared();
        if (d2 > max_d2)
            max_d2 = d2;
    }

    const auto &cfg = globalconfig();
    computed_t2_radius = std::sqrt(max_d2) + std::max(0.0, cfg.target_T2_param_margin);
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
}
