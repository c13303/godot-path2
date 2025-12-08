#include "spatial_grid.h"
#include <cmath>

using namespace ffcore;

SpatialGrid::SpatialGrid(double cs) : cell_size(cs) {}

void SpatialGrid::clear() {
    cells.clear();
    id_cells.clear();
}

long long SpatialGrid::cell_key(int x, int y) const {
    return (static_cast<long long>(x) << 32) ^ static_cast<unsigned int>(y);
}

Vec2i SpatialGrid::to_cell(const Vec2& pos) const {
    return Vec2i((int)std::floor(pos.x / cell_size),
                 (int)std::floor(pos.y / cell_size));
}

void SpatialGrid::insert(int id, const Vec2& pos) {
    Vec2i c = to_cell(pos);
    long long key = cell_key(c.x, c.y);
    cells[key].push_back(id);
    id_cells[id] = key;
}

void SpatialGrid::update(int id, const Vec2& old_pos, const Vec2& new_pos) {
    Vec2i old_c = to_cell(old_pos);
    Vec2i new_c = to_cell(new_pos);
    if (old_c.x == new_c.x && old_c.y == new_c.y) return;
    long long old_key = cell_key(old_c.x, old_c.y);
    long long new_key = cell_key(new_c.x, new_c.y);
    remove_from_cell(old_key, id);
    cells[new_key].push_back(id);
    id_cells[id] = new_key;
}

void SpatialGrid::remove(int id) {
    auto it_cell = id_cells.find(id);
    if (it_cell == id_cells.end())
        return;
    long long key = it_cell->second;
    remove_from_cell(key, id);
    id_cells.erase(it_cell);
}

std::vector<int> SpatialGrid::query_neighbors(const Vec2& pos, double radius) const {
    std::vector<int> result;
    int r = (int)std::ceil(radius / cell_size);
    Vec2i c = to_cell(pos);

    for (int dy = -r; dy <= r; ++dy) {
        for (int dx = -r; dx <= r; ++dx) {
            long long key = cell_key(c.x + dx, c.y + dy);
            auto it = cells.find(key);
            if (it == cells.end()) continue;
            for (int id : it->second)
                result.push_back(id);
        }
    }

    
    return result;
}

bool SpatialGrid::remove_from_cell(long long key, int id) {
    auto it = cells.find(key);
    if (it == cells.end())
        return false;
    auto &list = it->second;
    auto it_id = std::find(list.begin(), list.end(), id);
    if (it_id == list.end())
        return false;
    list.erase(it_id);
    if (list.empty())
        cells.erase(it);
    return true;
}
