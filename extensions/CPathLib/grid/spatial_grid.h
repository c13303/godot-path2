#pragma once
#include <unordered_map>
#include <vector>
#include <cmath>
#include <algorithm>
#include "../core/types.h"

namespace ffcore {

struct AgentRef {
    int id = -1;
    Vec2 pos;
};

class SpatialGrid {
public:
    SpatialGrid(double cell_size = 32.0);
    void clear();

    void insert(int id, const Vec2& pos);
    void update(int id, const Vec2& old_pos, const Vec2& new_pos);
    void remove(int id);

    std::vector<int> query_neighbors(const Vec2& pos, double radius) const;

    // Phase-1 diagnostics (cheap, O(cells)). Used to catch a spatial-grid ID leak:
    // total_id_count() far exceeding the live agent count means stale/duplicate ids
    // have accumulated; max_cell_occupancy() flags a single hot cell whose oversized
    // list is what makes query_neighbors() (and thus a frame) suddenly explode.
    size_t total_id_count() const;
    size_t max_cell_occupancy() const;
    size_t cell_count() const { return cells.size(); }

private:
    double cell_size;
    std::unordered_map<long long, std::vector<int>> cells;
    std::unordered_map<int, long long> id_cells;

    long long cell_key(int x, int y) const;
    Vec2i to_cell(const Vec2& pos) const;
    bool remove_from_cell(long long key, int id);
    void remove_from_all_cells(int id);
};

} // namespace ffcore
