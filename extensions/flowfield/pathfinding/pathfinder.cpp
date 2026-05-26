#include "pathfinder.h"

#include <godot_cpp/variant/utility_functions.hpp>
#include <queue>
#include <unordered_map>
#include <cmath>
#include <cstdlib>
#include <algorithm>

using namespace godot;

namespace
{
    struct AStarNode
    {
        double f;
        Vector2i cell;
        bool operator>(const AStarNode &o) const { return f > o.f; }
    };

    constexpr double SQRT2 = 1.41421356237;

    inline double octile_heuristic(const Vector2i &a, const Vector2i &b)
    {
        int dx = std::abs(a.x - b.x);
        int dy = std::abs(a.y - b.y);
        int d_min = std::min(dx, dy);
        int d_max = std::max(dx, dy);
        return (SQRT2 - 1.0) * (double)d_min + (double)d_max;
    }
}

void PathfinderNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_walkable_tiles", "cells"), &PathfinderNative::set_walkable_tiles);
    ClassDB::bind_method(D_METHOD("set_blockers", "cells"), &PathfinderNative::set_blockers);
    ClassDB::bind_method(D_METHOD("find_path", "from_tile", "to_tile"), &PathfinderNative::find_path);
    ClassDB::bind_method(D_METHOD("walkable_count"), &PathfinderNative::walkable_count);
    ClassDB::bind_method(D_METHOD("blocker_count"), &PathfinderNative::blocker_count);
}

void PathfinderNative::set_walkable_tiles(const PackedVector2Array &cells)
{
    walkable.clear();
    walkable.reserve(cells.size());
    for (int i = 0; i < cells.size(); ++i)
    {
        Vector2 v = cells[i];
        walkable.insert(Vector2i((int)v.x, (int)v.y));
    }
}

void PathfinderNative::set_blockers(const PackedVector2Array &cells)
{
    blockers.clear();
    blockers.reserve(cells.size());
    for (int i = 0; i < cells.size(); ++i)
    {
        Vector2 v = cells[i];
        blockers.insert(Vector2i((int)v.x, (int)v.y));
    }
}

bool PathfinderNative::is_open(const Vector2i &cell) const
{
    if (!walkable.count(cell))
        return false;
    if (blockers.count(cell))
        return false;
    return true;
}

PackedVector2Array PathfinderNative::find_path(const Vector2i &from_tile, const Vector2i &to_tile) const
{
    PackedVector2Array out;
    if (!is_open(from_tile) || !is_open(to_tile))
        return out;

    if (from_tile == to_tile)
    {
        out.push_back(Vector2((float)from_tile.x, (float)from_tile.y));
        return out;
    }

    const Vector2i dirs8[8] = {
        {1, 0}, {-1, 0}, {0, 1}, {0, -1},
        {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

    std::priority_queue<AStarNode, std::vector<AStarNode>, std::greater<AStarNode>> open;
    std::unordered_map<Vector2i, double, PFVec2iHash> g_score;
    std::unordered_map<Vector2i, Vector2i, PFVec2iHash> came_from;

    g_score[from_tile] = 0.0;
    open.push({octile_heuristic(from_tile, to_tile), from_tile});

    while (!open.empty())
    {
        AStarNode cur = open.top();
        open.pop();

        if (cur.cell == to_tile)
            break;

        auto it_g = g_score.find(cur.cell);
        if (it_g == g_score.end())
            continue;
        double cur_g = it_g->second;

        for (int i = 0; i < 8; ++i)
        {
            const Vector2i d = dirs8[i];
            Vector2i nb = cur.cell + d;
            if (!is_open(nb))
                continue;

            // No diagonal corner-cutting through blockers / non-walkable.
            if ((std::abs(d.x) + std::abs(d.y)) == 2)
            {
                if (!is_open(cur.cell + Vector2i(d.x, 0)) ||
                    !is_open(cur.cell + Vector2i(0, d.y)))
                    continue;
            }

            double step = (i < 4) ? 1.0 : SQRT2;
            double tentative = cur_g + step;

            auto it_nb = g_score.find(nb);
            if (it_nb == g_score.end() || tentative < it_nb->second)
            {
                g_score[nb] = tentative;
                came_from[nb] = cur.cell;
                double f = tentative + octile_heuristic(nb, to_tile);
                open.push({f, nb});
            }
        }
    }

    if (!came_from.count(to_tile) && from_tile != to_tile)
        return out; // unreachable

    // Reconstruct path: from_tile -> ... -> to_tile.
    std::vector<Vector2i> reversed_path;
    Vector2i c = to_tile;
    reversed_path.push_back(c);
    while (c != from_tile)
    {
        auto it = came_from.find(c);
        if (it == came_from.end())
            return PackedVector2Array(); // shouldn't happen
        c = it->second;
        reversed_path.push_back(c);
    }

    out.resize((int)reversed_path.size());
    for (int i = 0; i < (int)reversed_path.size(); ++i)
    {
        const Vector2i &t = reversed_path[reversed_path.size() - 1 - i];
        out.set(i, Vector2((float)t.x, (float)t.y));
    }
    return out;
}
