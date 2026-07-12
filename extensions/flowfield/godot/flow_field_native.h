#ifndef FLOW_FIELD_NATIVE_H
#define FLOW_FIELD_NATIVE_H

#include "../core/types.h"
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/transform2d.hpp>
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
        // Authored map extent in tilemap cells, pushed from GDScript at level start
        // (see LevelLoader / mapBounds). When set (positive size) this replaces the
        // floor layer's used-rect as the field's size/origin. Zero-size means "unset",
        // and map_extent() falls back to floor_layer->get_used_rect() so levels without
        // an authored bounds keep the previous behavior. Walkability seeding is
        // unaffected — only the field's dimensions/origin come from here.
        Rect2i map_bounds_cells = Rect2i();
        TileMapLayer *navigation_blocking_layer = nullptr;
        TileMapLayer *blocking_layer = nullptr;
        std::unordered_set<Vector2i, Vector2iHash> extra_blocking_cells;
        // Fence cells are kept separate from extra_blocking_cells so they never enter
        // the default field's physical wall mask (player collision) nor monster flow
        // builds. They are baked as walls only into flow builds requested with
        // block_fences = true (client/merchant groups). Monsters ignore fences entirely
        // and are merely slowed by their per-cell speed multiplier.
        std::unordered_set<Vector2i, Vector2iHash> fence_blocking_cells;
        std::unordered_map<Vector2i, double, Vector2iHash> cell_speed_multipliers;

        struct CellSpeedModifier
        {
            Vector2i cell;
            double multiplier = 1.0;
        };

        struct AsyncFlowSnapshot
        {
            Rect2i used;
            Vector2i goal_cell;
            double tile_size = 1.0;
            std::vector<Vector2i> walls;
            // Walkable candidates BEFORE the navigation-coverage filter. The coverage
            // scan is per-floor-cell and far too heavy for the main thread (it caused
            // visible hitches on lazy flow rebuilds), so the worker filters these using
            // the raw coverage inputs below instead of the main thread pre-filtering.
            std::vector<Vector2i> walkables;
            bool debug_disable_bottlenecks = false;
            int bottleneck_zone_radius_tiles = 0;
            double flow_field_wall_clearance = 0.0;
            bool block_fences = false;
            std::vector<CellSpeedModifier> speed_modifiers;
            // Raw inputs for the worker-side coverage filter. A zero threshold or an
            // empty nav_coverage_cells list disables filtering.
            double coverage_threshold = 0.0;
            double coverage_radius = 0.0;
            double nav_tile_size = 1.0;
            Transform2D floor_to_world;
            Transform2D world_to_nav;
            std::vector<Vector2i> nav_coverage_cells;
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
        // Debug draw is per-agent now: nothing is drawn until GDScript picks a group to
        // inspect (by clicking an agent) via set_debug_draw_group. INVALID_GROUP = draw
        // nothing. When set, _draw renders that group's live flow field.
        ffcore::GroupID debug_draw_group = ffcore::INVALID_GROUP;
        double debug_scale = 1;
        int32_t debug_stride = 1;
        Color debug_color_dir = Color(0, 1, 0);
        Color debug_color_cell = Color(1, 1, 1);

        // Field size/origin source: the authored map bounds when set, else the floor
        // layer's used-rect. All extent reads (build + read-back) route through this so
        // the field dimensions and every relative<->absolute cell mapping stay consistent.
        Rect2i map_extent() const;
        bool prepare_layers(Vector2 goal, Rect2i &used, Vector2i &goal_cell);
        void build_sets(std::unordered_set<Vector2i, Vector2iHash> &physical_wall_set,
                        std::unordered_set<Vector2i, Vector2iHash> &walkable_set);
        void add_navigation_coverage_blockers(const Array &floor_cells,
                                              std::unordered_set<Vector2i, Vector2iHash> &navigation_blocked_set) const;
        bool cell_reaches_navigation_blocking_coverage(const Vector2i &cell,
                                                       double radius,
                                                       double threshold) const;
        void apply_physics_passability(ffcore::FlowField &target_field,
                                       const Rect2i &used,
                                       const std::unordered_set<Vector2i, Vector2iHash> &physical_wall_set) const;
        void apply_cell_speed_multipliers(ffcore::FlowField &target_field, const Rect2i &used) const;
        // Reconcile the shared steering terrain-speed map (the single source of truth agents
        // read) from this node's absolute-cell record. Order-independent seeding.
        void seed_terrain_speed_to_steering() const;
        void apply_cell_speed_modifiers(ffcore::FlowField &target_field,
                                        const Rect2i &used,
                                        const std::vector<CellSpeedModifier> &modifiers) const;
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
        bool build_async_snapshot(Vector2 goal, AsyncFlowSnapshot &snapshot, bool block_fences);
        static bool snapshot_cell_is_coverage_blocked(const AsyncFlowSnapshot &snapshot,
                                                      const std::unordered_set<Vector2i, Vector2iHash> &nav_cells,
                                                      const Vector2i &cell);
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
        // Select which group's flow field the debug overlay draws (0 = none). Driven from
        // GDScript by clicking an agent while Draw Flow Field is enabled.
        void set_debug_draw_group(int group_id);

        void _ready() override;
        void _process(double delta) override;
        void _exit_tree() override;
        void set_floor_layer(Object *node);
        Object *get_floor_layer() const;

        void set_wall_layer(Object *node);
        Object *get_wall_layer() const;

        void set_navigation_blocking_layer(Object *node);
        Object *get_navigation_blocking_layer() const;
        void set_water_layer(Object *node);
        Object *get_water_layer() const;

        void set_blocking_layer(Object *node);
        Object *get_blocking_layer() const;
        // Authored map extent (tilemap cells). Pushed once at level start before the
        // first compute; persists so later async rebuilds use the same extent.
        void set_map_bounds(Rect2i bounds_cells);
        void set_extra_blocking_cells(const PackedVector2Array &cells);
        void clear_extra_blocking_cells();
        // Fence cells act as walls only for flow builds requested with block_fences = true
        // (clients/merchants). They never affect the default field or monster flow builds.
        void set_fence_blocking_cells(const PackedVector2Array &cells);
        void clear_fence_blocking_cells();
        void set_cell_speed_multiplier(Vector2i map_cell, double multiplier);
        void clear_cell_speed_multipliers();

        bool rebuild_async(Vector2 goal);
        // Lazy flow fields: GDScript calls this the moment it enqueues a group's rebuild,
        // before it is submitted for computation, so agents waiting on that group show
        // "ff wait" and freeze. request_flow_to_group / assign_flow_to_group then move the
        // group to "computing", and applying the field clears it back to none.
        void mark_group_flow_queued(int group_id);
        void request_flow_to_group(int group_id, Vector2 goal, bool block_fences = false);
        bool are_async_flows_idle() const;
        bool is_group_flow_request_ready(int group_id) const;
        void _draw() override;
        static double move_cost_for_dir(int dir_index);

        godot::Vector2 compute_flow_dir(Vector2 world_pos) const;

        ffcore::FlowField *get_field() { return &field; }
        Vector2 get_goal_world() const { return goal_world; }

        void assign_flow_to_group(int group_id, Vector2 goal, bool block_fences = false);

        // Walkable cost-to-goal for a group's flow field at a world position.
        // Returns +INF if the group has no flow or the cell is unreachable.
        // Used to pick the nearest reachable escape exit per monster cheaply.
        double group_route_cost_at_world(int group_id, Vector2 world_pos) const;

        void adjust_wall_tangents(const Rect2i &used,
                                  const std::unordered_set<Vector2i, Vector2iHash> &wall_set,
                                  int radius = 1);

        void compute_distance_field_global();

        // Live-edit the physics passability of a single cell on the default collision
        // field, in place. `map_cell` is an absolute tilemap cell; `blocked` true marks
        // it as a wall, false as walkable. Intentionally does NOT recompute the flow
        // field, distance field, or bottlenecks — it only keeps the player's hard wall
        // collision in sync when a wall/building is built or removed mid-day. The heavy
        // fields stay valid for routing and are rebuilt wholesale when night begins.
        void set_cell_blocked(Vector2i map_cell, bool blocked);
    };

} // namespace godot

#endif
