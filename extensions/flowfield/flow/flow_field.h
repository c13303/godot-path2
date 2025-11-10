#pragma once
#include <vector>
#include <cmath>
#include "../core/types.h"

namespace ffcore {

class FlowField {
public:
    FlowField() = default;
    FlowField(int width, int height, double tile_size);

    void resize(int width, int height);
    void set_tile_size(double size);

    Vec2  sample_dir_cell(int x, int y) const;
    Vec2  sample_dir_world(const Vec2 &world_pos) const;

    Vec2i world_to_cell(const Vec2 &world_pos) const;
    Vec2  cell_to_world(const Vec2i &cell) const;

    bool  is_ready() const { return ready; }
    double tile_size() const { return tile; }

    void clear();
    void set_dir(int x, int y, const Vec2 &dir);

    void compute(const Vec2i &goal_cell, const std::vector<Vec2i> &walkables, bool allow_diagonals);

    int  width() const { return w; }
    int  height() const { return h; }
    Vec2 dir(int x, int y) const {
        if (x < 0 || y < 0 || x >= w || y >= h) return Vec2();
        return dirs[y * w + x];
    }

    // origine en indices de cellule (ex: used.position)
    void set_cell_origin(const Vec2i &c) { cell_origin = c; }
    const Vec2i &get_cell_origin() const { return cell_origin; }

private:
    int w = 0;
    int h = 0;
    double tile = 1.0;
    bool ready = false;

    Vec2i cell_origin = Vec2i(0, 0);
    std::vector<Vec2> dirs;
};

} // namespace ffcore
