#include "spatial_grid.h"
#include <cstdint>
#include <cmath>

using namespace ffcore;

SpatialGrid::SpatialGrid(double cs) : cell_size(cs) {}

void SpatialGrid::clear() {
    cells.clear();
    id_cells.clear();
}

long long SpatialGrid::cell_key(int x, int y) const {
    const std::uint64_t packed =
        (static_cast<std::uint64_t>(static_cast<std::uint32_t>(x)) << 32) |
        static_cast<std::uint32_t>(y);
    return static_cast<long long>(packed);
}

Vec2i SpatialGrid::to_cell(const Vec2& pos) const {
    return Vec2i((int)std::floor(pos.x / cell_size),
                 (int)std::floor(pos.y / cell_size));
}

void SpatialGrid::insert(int id, const Vec2& pos) {
    Vec2i c = to_cell(pos);
    long long key = cell_key(c.x, c.y);
    auto existing = id_cells.find(id);
    if (existing != id_cells.end())
        remove_from_cell(existing->second, id);
    remove_from_all_cells(id);
    cells[key].push_back(id);
    id_cells[id] = key;
}

void SpatialGrid::update(int id, const Vec2& old_pos, const Vec2& new_pos) {
    Vec2i new_c = to_cell(new_pos);
    long long new_key = cell_key(new_c.x, new_c.y);
    auto it_cell = id_cells.find(id);
    if (it_cell == id_cells.end()) {
        cells[new_key].push_back(id);
        id_cells[id] = new_key;
        return;
    }

    // Remove from the authoritative stored cell. old_pos is only used as a
    // cleanup hint for stale entries left by older/non-authoritative updates.
    long long stored_key = it_cell->second;
    Vec2i old_c = to_cell(old_pos);
    long long old_key = cell_key(old_c.x, old_c.y);
    if (stored_key == new_key) {
        if (old_key != stored_key)
            remove_from_cell(old_key, id);
        return;
    }

    remove_from_cell(stored_key, id);
    if (old_key != stored_key)
        remove_from_cell(old_key, id);
    cells[new_key].push_back(id);
    id_cells[id] = new_key;
}

void SpatialGrid::remove(int id) {
    auto it_cell = id_cells.find(id);
    if (it_cell == id_cells.end()) {
        remove_from_all_cells(id);
        return;
    }
    long long key = it_cell->second;
    remove_from_cell(key, id);
    remove_from_all_cells(id);
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

size_t SpatialGrid::total_id_count() const {
    size_t total = 0;
    for (const auto &kv : cells)
        total += kv.second.size();
    return total;
}

size_t SpatialGrid::max_cell_occupancy() const {
    size_t worst = 0;
    for (const auto &kv : cells)
        worst = std::max(worst, kv.second.size());
    return worst;
}

bool SpatialGrid::remove_from_cell(long long key, int id) {
    auto it = cells.find(key);
    if (it == cells.end())
        return false;
    auto &list = it->second;
    auto old_size = list.size();
    list.erase(std::remove(list.begin(), list.end(), id), list.end());
    if (list.size() == old_size)
        return false;
    if (list.empty())
        cells.erase(it);
    return true;
}

void SpatialGrid::remove_from_all_cells(int id) {
    for (auto it = cells.begin(); it != cells.end();) {
        auto &list = it->second;
        list.erase(std::remove(list.begin(), list.end(), id), list.end());
        if (list.empty())
            it = cells.erase(it);
        else
            ++it;
    }
}
