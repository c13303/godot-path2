#include "flow_field.h"
#include <algorithm>
#include <cmath>
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

Vec2 FlowField::sample_dir_world(const Vec2 &world_pos) const
{
    if (!ready)
        return Vec2();
    Vec2i cell = world_to_cell(world_pos);
    return sample_dir_cell(cell.x, cell.y);
}

Vec2i FlowField::world_to_cell(const Vec2 &world_pos) const {
    int gx = static_cast<int>(std::floor(world_pos.x / tile));
    int gy = static_cast<int>(std::floor(world_pos.y / tile));
    return Vec2i(gx - cell_origin.x, gy - cell_origin.y);
}

Vec2 FlowField::cell_to_world(const Vec2i &cell) const {
    int gx = cell_origin.x + cell.x;
    int gy = cell_origin.y + cell.y;
    return Vec2((gx + 0.5) * tile, (gy + 0.5) * tile);
}

void FlowField::clear()
{
    std::fill(dirs.begin(), dirs.end(), Vec2());
    ready = false;
}

void FlowField::set_dir(int x, int y, const Vec2 &dir)
{
    if (x < 0 || y < 0 || x >= w || y >= h)
        return;
    dirs[y * w + x] = dir;
    ready = true;
}

#include <queue>
#include <unordered_set>

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

using namespace ffcore;

void FlowField::compute(const Vec2i &goal_cell, const std::vector<Vec2i> &walkables, bool allow_diagonals)
{
    if (w == 0 || h == 0 || walkables.empty())
        return;

    const Vec2i ORTHO[4] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
    const Vec2i DIAG[4] = {{1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

    std::unordered_set<int> walkable_set;
    walkable_set.reserve(walkables.size());
    auto index = [&](const Vec2i &c)
    { return c.y * w + c.x; };

    for (auto &c : walkables)
    {
        if (c.x >= 0 && c.y >= 0 && c.x < w && c.y < h)
            walkable_set.insert(index(c));
    }

    std::vector<int32_t> dist(w * h, INT_MAX);
    std::priority_queue<FFNode> open;

    if (walkable_set.count(index(goal_cell)))
    {
        dist[index(goal_cell)] = 0;
        open.push({goal_cell, 0});
    }
    else
        return;

    while (!open.empty())
    {
        FFNode cur = open.top();
        open.pop();
        int dcur = dist[index(cur.c)];
        if (dcur < cur.d)
            continue;

        for (auto &d : ORTHO)
        {
            Vec2i n(cur.c.x + d.x, cur.c.y + d.y);
            if (n.x < 0 || n.y < 0 || n.x >= w || n.y >= h)
                continue;
            int ni = index(n);
            if (!walkable_set.count(ni))
                continue;

            int nd = dcur + step_cost(cur.c, n);
            if (nd < dist[ni])
            {
                dist[ni] = nd;
                open.push({n, nd});
            }
        }

        if (allow_diagonals)
        {
            for (auto &d : DIAG)
            {
                Vec2i n(cur.c.x + d.x, cur.c.y + d.y);
                if (n.x < 0 || n.y < 0 || n.x >= w || n.y >= h)
                    continue;
                int ni = index(n);
                if (!walkable_set.count(ni))
                    continue;

                int nd = dcur + step_cost(cur.c, n);
                if (nd < dist[ni])
                {
                    dist[ni] = nd;
                    open.push({n, nd});
                }
            }
        }
    }

    for (int y = 0; y < h; ++y)
    {
        for (int x = 0; x < w; ++x)
        {
            Vec2i c(x, y);
            int ci = index(c);
            if (!walkable_set.count(ci))
            {
                dirs[ci] = Vec2();
                continue;
            }

            int best_d = dist[ci];
            Vec2i best = c;

            for (auto &d : ORTHO)
            {
                Vec2i n(c.x + d.x, c.y + d.y);
                if (n.x < 0 || n.y < 0 || n.x >= w || n.y >= h)
                    continue;
                int ni = index(n);
                if (!walkable_set.count(ni))
                    continue;
                if (dist[ni] < best_d)
                {
                    best_d = dist[ni];
                    best = n;
                }
            }

            if (allow_diagonals)
            {
                for (auto &d : DIAG)
                {
                    Vec2i n(c.x + d.x, c.y + d.y);
                    if (n.x < 0 || n.y < 0 || n.x >= w || n.y >= h)
                        continue;
                    int ni = index(n);
                    if (!walkable_set.count(ni))
                        continue;
                    if (dist[ni] < best_d)
                    {
                        best_d = dist[ni];
                        best = n;
                    }
                }
            }

            // cas non atteignable ou pas de voisin meilleur
            if (dist[ci] == INT_MAX || (best.x == c.x && best.y == c.y))
            {
                dirs[ci] = Vec2();
                continue;
            }

            Vec2 delta((double)(best.x - c.x), (double)(best.y - c.y));
            double len = delta.length();
            dirs[ci] = (len > 1e-6) ? (delta / len) : Vec2();
        }
    }

    ready = true;
}
