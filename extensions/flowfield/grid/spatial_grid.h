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

private:
    double cell_size;
    std::unordered_map<long long, std::vector<int>> cells;
    std::unordered_map<int, long long> id_cells;

    long long cell_key(int x, int y) const;
    Vec2i to_cell(const Vec2& pos) const;
    bool remove_from_cell(long long key, int id);
};

} // namespace ffcore
