#include "pathfinder.h"

#include <vector>

using namespace godot;

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
    std::vector<ffcore::Vec2i> converted;
    converted.reserve(cells.size());
    for (int i = 0; i < cells.size(); ++i)
    {
        const Vector2 cell = cells[i];
        converted.push_back({static_cast<int>(cell.x), static_cast<int>(cell.y)});
    }
    solver.set_walkable_cells(converted);
}

void PathfinderNative::set_blockers(const PackedVector2Array &cells)
{
    std::vector<ffcore::Vec2i> converted;
    converted.reserve(cells.size());
    for (int i = 0; i < cells.size(); ++i)
    {
        const Vector2 cell = cells[i];
        converted.push_back({static_cast<int>(cell.x), static_cast<int>(cell.y)});
    }
    solver.set_blocked_cells(converted);
}

PackedVector2Array PathfinderNative::find_path(const Vector2i &from_tile, const Vector2i &to_tile) const
{
    const std::vector<ffcore::Vec2i> path = solver.find_path(
        {from_tile.x, from_tile.y},
        {to_tile.x, to_tile.y});
    PackedVector2Array result;
    result.resize(static_cast<int>(path.size()));
    for (int i = 0; i < static_cast<int>(path.size()); ++i)
    {
        result.set(i, Vector2(static_cast<float>(path[i].x), static_cast<float>(path[i].y)));
    }
    return result;
}
