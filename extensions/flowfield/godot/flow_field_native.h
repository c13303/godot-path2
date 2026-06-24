#ifndef FLOW_FIELD_NATIVE_H
#define FLOW_FIELD_NATIVE_H

#include "../core/types.h"
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>
#include <godot_cpp/variant/array.hpp>
#include "../flow/flow_field.h"
#include <cstdint>
#include <unordered_set>
#include <unordered_map>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

namespace godot
{

    struct Vector2iHash
    {
        size_t operator()(const Vector2i &v) const noexcept
        {
            return (size_t(v.x) * 73856093u) ^ (size_t(v.y) * 19349663u);
        }
    };

    class FlowFieldNative : public Node2D
    {
        GDCLASS(FlowFieldNative, Node2D);

    private:
        ffcore::FlowField field;
        ffcore::GroupID current_group_id = ffcore::INVALID_GROUP;

        Vector2 goal_world;

        TileMapLayer *floor_layer = nullptr;
        TileMapLayer *wall_layer = nullptr;
        TileMapLayer *blocking_layer = nullptr;

        struct AsyncFlowSnapshot
        {
            Rect2i used;
            Vector2i goal_cell;
            double tile_size = 1.0;
            std::vector<Vector2i> walls;
            std::vector<Vector2i> walkables;
            bool debug_disable_bottlenecks = false;
            int bottleneck_zone_radius_tiles = 0;
            double flow_field_wall_clearance = 0.0;
        };

        struct AsyncFlowRequest
        {
            int group_id = ffcore::INVALID_GROUP;
            uint64_t serial = 0;
            AsyncFlowSnapshot snapshot;
        };

        struct AsyncFlowResult
        {
            int group_id = ffcore::INVALID_GROUP;
            uint64_t serial = 0;
            bool ok = false;
            ffcore::FlowField field;
        };

        std::thread worker_thread;
        mutable std::mutex async_mutex;
        std::condition_variable async_cv;
        std::deque<AsyncFlowRequest> pending_requests;
        std::deque<AsyncFlowResult> completed_results;
        std::unordered_map<int, uint64_t> latest_request_serial_by_group;
        std::unordered_map<int, uint64_t> latest_applied_serial_by_group;
        int active_worker_requests = 0;
        bool worker_stop = false;
        uint64_t next_request_serial = 1;

        bool debug_draw = false;
        double debug_scale = 1;
        int32_t debug_stride = 1;
        Color debug_color_dir = Color(0, 1, 0);
        Color debug_color_cell = Color(1, 1, 1);

        bool prepare_layers(Vector2 goal, Rect2i &used, Vector2i &goal_cell);
        void build_sets(std::unordered_set<Vector2i, Vector2iHash> &wall_set,
                        std::unordered_set<Vector2i, Vector2iHash> &walkable_set);
        void compute_costs(const std::unordered_set<Vector2i, Vector2iHash> &walkable_set,
                           const Vector2i &goal_cell,
                           std::unordered_map<Vector2i, double, Vector2iHash> &costs);
        void compute_directions(const Rect2i &used,
                                const std::unordered_set<Vector2i, Vector2iHash> &walkable_set,
                                const std::unordered_map<Vector2i, double, Vector2iHash> &costs,
                                const std::unordered_set<Vector2i, Vector2iHash> &wall_set);

        void finalize_field(const Rect2i &used, const Vector2i &goal_cell);
        void compute_distance_field(const Rect2i &used,
                                    const std::unordered_set<Vector2i, Vector2iHash> &wall_set);
        void compute_bottlenecks(const Rect2i &used,
                                 const std::unordered_set<Vector2i, Vector2iHash> &walkable_set,
                                 const std::unordered_map<Vector2i, double, Vector2iHash> &costs);

        std::vector<float> distance_field;
        int group_size_for_draw() const;
        bool build_async_snapshot(Vector2 goal, AsyncFlowSnapshot &snapshot);
        void start_worker();
        void stop_worker();
        void worker_loop();
        void process_async_results();
        AsyncFlowResult compute_async_request(const AsyncFlowRequest &request) const;
        void apply_async_result(const AsyncFlowResult &result);

    protected:
        static void _bind_methods();

    public:
        FlowFieldNative() = default;
        ~FlowFieldNative() override;

        void set_debug_draw(bool enabled);
        bool get_debug_draw() const { return debug_draw; }

        void _ready() override;
        void _process(double delta) override;
        void _exit_tree() override;
        void set_floor_layer(Object *node);
        Object *get_floor_layer() const;

        void set_wall_layer(Object *node);
        Object *get_wall_layer() const;

        void set_blocking_layer(Object *node);
        Object *get_blocking_layer() const;

        bool rebuild_async(Vector2 goal);
        void request_flow_to_group(int group_id, Vector2 goal);
        bool are_async_flows_idle() const;
        bool is_group_flow_request_ready(int group_id) const;
        void _draw() override;
        static double move_cost_for_dir(int dir_index);

        godot::Vector2 compute_flow_dir(Vector2 world_pos) const;

        ffcore::FlowField *get_field() { return &field; }
        Vector2 get_goal_world() const { return goal_world; }

        void assign_flow_to_group(int group_id, Vector2 goal);

        // Walkable cost-to-goal for a group's flow field at a world position.
        // Returns +INF if the group has no flow or the cell is unreachable.
        // Used to pick the nearest reachable escape exit per monster cheaply.
        double group_route_cost_at_world(int group_id, Vector2 world_pos) const;

        void adjust_wall_tangents(const Rect2i &used,
                                  const std::unordered_set<Vector2i, Vector2iHash> &wall_set,
                                  int radius = 1);

        void compute_distance_field_global();
    };

} // namespace godot

#endif
