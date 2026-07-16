#pragma once
#include <cstdint>
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

    struct BottleneckInfo
    {
        Vec2i cell;
        int axis = 0; // 1 = horizontal, 2 = vertical
        double route_cost = 0.0;
        std::vector<Vec2i> zone_cells;
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
        void enable_explicit_navigability();
        void set_cell_navigable(const Vec2i &cell, bool navigable);
        Vec2i find_nearest_navigable(Vec2i start) const;
        bool is_cell_physics_passable(const Vec2i &cell) const;
        void enable_explicit_physics_passability();
        void set_cell_physics_passable(const Vec2i &cell, bool passable);
        Vec2i find_nearest_physics_passable(Vec2i start) const;
        void clear_bottlenecks();
        int add_bottleneck(const Vec2i &cell, int axis, double route_cost = 0.0);
        void add_bottleneck_zone_cell(int bottleneck_index, const Vec2i &cell);
        int bottleneck_core_at_cell(const Vec2i &cell) const;
        int bottleneck_zone_at_cell(const Vec2i &cell) const;
        int next_bottleneck_at_cell(const Vec2i &cell) const;
        double route_cost_at_cell(const Vec2i &cell) const;
        const BottleneckInfo *bottleneck_at(int index) const;
        const std::vector<BottleneckInfo> &get_bottlenecks() const { return bottlenecks; }
        double get_ff_target_radius() const { return ff_target_radius; }
        void set_ff_target_radius(double radius) { ff_target_radius = radius; }
        int arrived_count = 0;
        bool first_is_arrived = false;
        void copy_from(const FlowField &src);
        bool has_distance_field() const;
        float distance_at_cell(const Vec2i &cell) const;
        Vec2 distance_gradient_at_cell(const Vec2i &cell) const;
        void set_distance_field(const std::vector<float> &df);
        void set_route_cost_field(const std::vector<double> &costs);

        int refcount = 0; /// nbre d'agent dedans pour delete a la fin
        FlowFieldID id = INVALID_FLOWFIELD;

    private:
        int w = 0;
        int h = 0;
        double tile = 1.0;
        bool ready = false;

        Vec2i cell_origin = Vec2i(0, 0);
        std::vector<Vec2> dirs;
        // Distance-only fields have no flow directions, so direction == zero cannot
        // be used to distinguish floors from walls. Goal-based fields keep the
        // legacy direction-derived behavior unless this mask is explicitly enabled.
        bool explicit_navigability = false;
        std::vector<std::uint8_t> navigable_cells;
        bool explicit_physics_passability = false;
        std::vector<std::uint8_t> physics_passable_cells;
        std::vector<float> distance_field;
        std::vector<double> route_cost_field;
        std::vector<BottleneckInfo> bottlenecks;
        std::vector<int> bottleneck_core_by_cell;
        std::vector<int> bottleneck_zone_by_cell;
        std::vector<int> next_bottleneck_by_cell;

        Vec2i goal_cell = Vec2i(-1, -1);
        double ff_target_radius = 0.0;
    };

} // namespace ffcore
