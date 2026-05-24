#ifndef FLOW_FIELD_NATIVE_H
#define FLOW_FIELD_NATIVE_H

#include "../core/types.h"
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>
#include <godot_cpp/variant/array.hpp>
#include "../flow/flow_field.h"
#include <unordered_set>
#include <unordered_map>

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
                                 const std::unordered_set<Vector2i, Vector2iHash> &walkable_set);

        std::vector<float> distance_field;
        int group_size_for_draw() const;

    protected:
        static void _bind_methods();

    public:
        FlowFieldNative() = default;
        ~FlowFieldNative() override = default;

        void set_debug_draw(bool enabled);
        bool get_debug_draw() const { return debug_draw; }

        void _ready() override;
        void set_floor_layer(Object *node);
        Object *get_floor_layer() const;

        void set_wall_layer(Object *node);
        Object *get_wall_layer() const;

        bool rebuild_async(Vector2 goal);
        void _draw() override;
        static double move_cost_for_dir(int dir_index);

        godot::Vector2 compute_flow_dir(Vector2 world_pos) const;

        ffcore::FlowField *get_field() { return &field; }
        Vector2 get_goal_world() const { return goal_world; }

        void assign_flow_to_group(int group_id, Vector2 goal);

        void adjust_wall_tangents(const Rect2i &used,
                                  const std::unordered_set<Vector2i, Vector2iHash> &wall_set,
                                  int radius = 1);

        void compute_distance_field_global();
    };

} // namespace godot

#endif
