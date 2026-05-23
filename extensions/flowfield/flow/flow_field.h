#pragma once
#include <vector>
#include <cmath>
#include "../core/types.h"
#include <string>

namespace ffcore
{
    struct FormationFootprint
    {
        int w = 1;
        int h = 1;
        double angle = 0.0; // radians, principal axis of formation
    };

    class FlowField
    {
    public:
        FlowField() = default;
        FlowField(int width, int height, double tile_size);

        void resize(int width, int height);
        void set_tile_size(double size);

        Vec2 sample_dir_cell(int x, int y) const;
        Vec2 compute_flow_dir(const Vec2 &world_pos) const;

        Vec2i world_to_cell(const Vec2 &world_pos) const;
        Vec2 cell_to_world(const Vec2i &cell) const;

        bool is_ready() const { return ready; }
        double tile_size() const { return tile; }

        void clear();
        void set_dir(int x, int y, const Vec2 &dir);

        void compute(const Vec2i &goal_cell, const std::vector<Vec2i> &walkables, bool allow_diagonals);

        int width() const { return w; }
        int height() const { return h; }
        Vec2 dir(int x, int y) const
        {
            if (x < 0 || y < 0 || x >= w || y >= h)
                return Vec2();
            return dirs[y * w + x];
        }

        void set_cell_origin(const Vec2i &c) { cell_origin = c; }
        const Vec2i &get_cell_origin() const { return cell_origin; }

        void set_goal_cell(const Vec2i &c) { goal_cell = c; }
        Vec2i get_goal_cell() const { return goal_cell; }
        bool has_goal() const { return goal_cell.x >= 0 && goal_cell.y >= 0; }
        Vec2 goal_center_world() const { return cell_to_world(goal_cell); }

        bool is_cell_navigable(const Vec2i &cell) const;
        Vec2i find_nearest_navigable(Vec2i start) const;
        double get_ff_target_radius() const { return ff_target_radius; }
        void set_ff_target_radius(double radius) { ff_target_radius = radius; }
        int arrived_count = 0;
        bool first_is_arrived = false;
        void copy_from(const FlowField &src);
        bool has_distance_field() const;
        float distance_at_cell(const Vec2i &cell) const;
        Vec2 distance_gradient_at_cell(const Vec2i &cell) const;
        void set_distance_field(const std::vector<float> &df);

        int refcount = 0; /// nbre d'agent dedans pour delete a la fin
        FlowFieldID id = INVALID_FLOWFIELD;

    private:
        int w = 0;
        int h = 0;
        double tile = 1.0;
        bool ready = false;

        Vec2i cell_origin = Vec2i(0, 0);
        std::vector<Vec2> dirs;
        std::vector<float> distance_field;

        Vec2i goal_cell = Vec2i(-1, -1);
        double ff_target_radius = 0.0;
    };

} // namespace ffcore
