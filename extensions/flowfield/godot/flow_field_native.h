#ifndef FLOW_FIELD_NATIVE_H
#define FLOW_FIELD_NATIVE_H

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>
#include "../flow/flow_field.h"

namespace godot {

class FlowFieldNative : public Node2D {
    GDCLASS(FlowFieldNative, Node2D);

private:
    ffcore::FlowField field;
    Vector2 goal_world;
    TileMapLayer *floor_layer = nullptr;
    TileMapLayer *wall_layer = nullptr;

    bool   debug_draw = true;
    double debug_scale = 1;
    int32_t debug_stride = 2;
    Color debug_color_dir = Color(0, 1, 0);
    Color debug_color_cell = Color(1, 1, 1);

protected:
    static void _bind_methods();

public:
    FlowFieldNative() = default;
    ~FlowFieldNative() override = default;

    void set_floor_layer(Object *node);
    Object *get_floor_layer() const;

    void set_wall_layer(Object *node);
    Object *get_wall_layer() const;

    void rebuild_async(Vector2 goal);
    void _draw() override;
    static double move_cost_for_dir(int dir_index);

    godot::Vector2 sample_dir_world(Vector2 world_pos) const;

    ffcore::FlowField *get_field() { return &field; }
};

} // namespace godot

#endif
