#ifndef FLOW_FIELD_H
#define FLOW_FIELD_H

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>

#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <queue>
#include <mutex>
#include <thread>
#include <vector>
#include <unordered_set>

struct Vector2iHash
{
    size_t operator()(const godot::Vector2i &v) const noexcept
    {
        return (static_cast<uint64_t>(static_cast<uint32_t>(v.x)) << 32) ^ static_cast<uint32_t>(v.y);
    }
};

namespace godot
{
    class FlowField : public Node2D
    {
        GDCLASS(FlowField, Node2D);

    protected:
        static void _bind_methods();

    public:
        FlowField();
        ~FlowField();

        void _ready() override;
        void _exit_tree() override;
        void _process(double delta) override;
        void _draw() override;

        void set_floor_layer(TileMapLayer *p);
        TileMapLayer *get_floor_layer() const;

        void set_wall_layer(TileMapLayer *p);
        TileMapLayer *get_wall_layer() const;

        void set_allow_diagonals(bool allow);
        bool get_allow_diagonals() const;

        void set_debug_draw(bool v);
        bool get_debug_draw() const;

        void set_debug_scale(double v);
        double get_debug_scale() const;

        void set_debug_stride(int32_t v);
        int32_t get_debug_stride() const;

        void set_debug_color_dir(Color c);
        Color get_debug_color_dir() const;

        void set_debug_color_cell(Color c);
        Color get_debug_color_cell() const;

        Vector2i current_goal_cell() const;
        bool is_ready() const;
        int32_t flow_version() const;

        Vector2i world_to_cell(Vector2 world_pos) const;
        Vector2 cell_to_world(Vector2i cell) const;

        void rebuild_async(Vector2 goal_world);

        Vector2 sample_dir_cell(Vector2i cell) const;
        Vector2 sample_dir_world(Vector2 world_pos) const;
        Vector2 sample_dir_world_bilinear(Vector2 world_pos) const;

        void capture_tile_size();
        void build_walkable_snapshot();
        Array neighbors(Vector2i cell, bool diag_ok);
        Vector2i get_tile_size() const;

        int32_t cost_step(Vector2i a, Vector2i b) const;
        int32_t cell_index(Vector2i c, Rect2i used) const;
        bool in_bounds(Vector2i c, Rect2i used) const;

        Array make_dist_array(Rect2i rect) const;
        int32_t get_dist(Vector2i c, Rect2i used, const Array &dist_arr) const;
        Array set_dist(Vector2i c, int32_t v, Rect2i used, Array dist_arr);
        /*         void test_print_threads(); */

    private:
        void _capture_tile_size();
        void _build_walkable_snapshot();
        Array _neighbors(Vector2i cell, bool diag_ok) const;

        void _start_thread(Vector2i goal_cell);
        void _thread_compute(Dictionary payload);
        void _thread_done_arr(const Array &dirs_arr, Rect2i used);
        void _swap_buffers();
        void _heap_push(Array &heap, const Array &pair);
        Array _heap_pop(Array &heap);
        bool _is_near_wall(Vector2i c) const;
        Vector2i _find_nearest_walkable(Vector2i origin, const Array &walkable) const;
        void _join_thread_if_any();
        void _test_thread_func();
        void store_floor_native();
        void store_wall_native();

    private:
        TileMapLayer *floor_layer = nullptr;
        TileMapLayer *wall_layer = nullptr;

        bool allow_diagonals = false;

        Vector2i tile_size = Vector2i(32, 32);

        Array _walkable;
        Dictionary _walkable_set;

        Array _dirs_front;
        Array _dirs_back;

        Rect2i _used_rect_front;
        Rect2i _used_rect_back;

        Vector2i _goal_cell = Vector2i(0, 0);
        int32_t _version = 0;

        bool _computing = false;
        Vector2i _pending_goal = Vector2i(0, 0);
        bool _has_pending = false;

        Array _tmp_neighbors;

        bool debug_draw = true;
        double debug_scale = 0.4;
        int32_t debug_stride = 2;
        Color debug_color_dir = Color(0, 1, 0);
        Color debug_color_cell = Color(1, 1, 1);

        static const Vector2i ORTHO[4];
        static const Vector2i DIAG[4];

        mutable std::queue<String> _log_queue;
        mutable std::mutex _log_mutex;
        std::thread _std_thread;
        bool _needs_redraw = false;
        
        std::vector<godot::Vector2i> _floor_cells;
        std::unordered_set<godot::Vector2i, Vector2iHash> _floor_set;
        godot::Rect2i _used_rect_floor;

        std::vector<godot::Vector2i> _wall_cells;
        std::unordered_set<godot::Vector2i, Vector2iHash> _wall_set;
        godot::Rect2i _used_rect_wall;
    };
}

#endif
