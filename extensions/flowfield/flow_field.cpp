#include "flow_field.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

const Vector2i FlowField::ORTHO[4] = {Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)};
const Vector2i FlowField::DIAG[4] = {Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)};

void FlowField::_bind_methods()
{

    ClassDB::bind_method(D_METHOD("set_floor_layer", "node"), &FlowField::set_floor_layer);
    ClassDB::bind_method(D_METHOD("get_floor_layer"), &FlowField::get_floor_layer);
    ClassDB::add_property(get_class_static(), PropertyInfo(Variant::OBJECT, "floor_layer", PROPERTY_HINT_RESOURCE_TYPE, "TileMapLayer"), "set_floor_layer", "get_floor_layer");

    ClassDB::bind_method(D_METHOD("set_wall_layer", "node"), &FlowField::set_wall_layer);
    ClassDB::bind_method(D_METHOD("get_wall_layer"), &FlowField::get_wall_layer);
    ClassDB::add_property(get_class_static(), PropertyInfo(Variant::OBJECT, "wall_layer", PROPERTY_HINT_RESOURCE_TYPE, "TileMapLayer"), "set_wall_layer", "get_wall_layer");

    ClassDB::bind_method(D_METHOD("set_allow_diagonals", "allow"), &FlowField::set_allow_diagonals);
    ClassDB::bind_method(D_METHOD("get_allow_diagonals"), &FlowField::get_allow_diagonals);
    ClassDB::add_property(get_class_static(), PropertyInfo(Variant::BOOL, "allow_diagonals"), "set_allow_diagonals", "get_allow_diagonals");

    ClassDB::bind_method(D_METHOD("set_debug_draw", "v"), &FlowField::set_debug_draw);
    ClassDB::bind_method(D_METHOD("get_debug_draw"), &FlowField::get_debug_draw);
    ClassDB::add_property(get_class_static(), PropertyInfo(Variant::BOOL, "debug_draw"), "set_debug_draw", "get_debug_draw");

    ClassDB::bind_method(D_METHOD("set_debug_scale", "v"), &FlowField::set_debug_scale);
    ClassDB::bind_method(D_METHOD("get_debug_scale"), &FlowField::get_debug_scale);
    ClassDB::add_property(get_class_static(), PropertyInfo(Variant::FLOAT, "debug_scale"), "set_debug_scale", "get_debug_scale");

    ClassDB::bind_method(D_METHOD("set_debug_stride", "v"), &FlowField::set_debug_stride);
    ClassDB::bind_method(D_METHOD("get_debug_stride"), &FlowField::get_debug_stride);
    ClassDB::add_property(get_class_static(), PropertyInfo(Variant::INT, "debug_stride"), "set_debug_stride", "get_debug_stride");

    ClassDB::bind_method(D_METHOD("set_debug_color_dir", "c"), &FlowField::set_debug_color_dir);
    ClassDB::bind_method(D_METHOD("get_debug_color_dir"), &FlowField::get_debug_color_dir);
    ClassDB::add_property(get_class_static(), PropertyInfo(Variant::COLOR, "debug_color_dir"), "set_debug_color_dir", "get_debug_color_dir");

    ClassDB::bind_method(D_METHOD("set_debug_color_cell", "c"), &FlowField::set_debug_color_cell);
    ClassDB::bind_method(D_METHOD("get_debug_color_cell"), &FlowField::get_debug_color_cell);
    ClassDB::add_property(get_class_static(), PropertyInfo(Variant::COLOR, "debug_color_cell"), "set_debug_color_cell", "get_debug_color_cell");

    ClassDB::bind_method(D_METHOD("current_goal_cell"), &FlowField::current_goal_cell);
    ClassDB::bind_method(D_METHOD("is_ready"), &FlowField::is_ready);
    ClassDB::bind_method(D_METHOD("flow_version"), &FlowField::flow_version);

    ClassDB::bind_method(D_METHOD("rebuild_async", "goal_world"), &FlowField::rebuild_async);

    ClassDB::bind_method(D_METHOD("sample_dir_cell", "cell"), &FlowField::sample_dir_cell);
    ClassDB::bind_method(D_METHOD("sample_dir_world", "world_pos"), &FlowField::sample_dir_world);
    ClassDB::bind_method(D_METHOD("sample_dir_world_bilinear", "world_pos"), &FlowField::sample_dir_world_bilinear);

    ClassDB::bind_method(D_METHOD("build_walkable_snapshot"), &FlowField::build_walkable_snapshot);
    ClassDB::bind_method(D_METHOD("neighbors", "cell", "diag_ok"), &FlowField::neighbors);
    ClassDB::bind_method(D_METHOD("cell_to_world", "cell"), &FlowField::cell_to_world);
    ClassDB::bind_method(D_METHOD("world_to_cell", "world_pos"), &FlowField::world_to_cell);
    ClassDB::bind_method(D_METHOD("get_tile_size"), &FlowField::get_tile_size);
    ClassDB::bind_method(D_METHOD("capture_tile_size"), &FlowField::capture_tile_size);
}

FlowField::FlowField() {}
FlowField::~FlowField() {}

void FlowField::_ready() {}
void FlowField::_exit_tree() { _join_thread_if_any(); }
void FlowField::_process(double) {}
void FlowField::_draw() {}

void FlowField::set_floor_layer(TileMapLayer *p) { floor_layer = p; }
TileMapLayer *FlowField::get_floor_layer() const { return floor_layer; }

void FlowField::set_wall_layer(TileMapLayer *p) { wall_layer = p; }
TileMapLayer *FlowField::get_wall_layer() const { return wall_layer; }

void FlowField::set_allow_diagonals(bool allow) { allow_diagonals = allow; }
bool FlowField::get_allow_diagonals() const { return allow_diagonals; }

void FlowField::set_debug_draw(bool v) { debug_draw = v; }
bool FlowField::get_debug_draw() const { return debug_draw; }

void FlowField::set_debug_scale(double v) { debug_scale = v; }
double FlowField::get_debug_scale() const { return debug_scale; }

void FlowField::set_debug_stride(int32_t v) { debug_stride = v; }
int32_t FlowField::get_debug_stride() const { return debug_stride; }

void FlowField::set_debug_color_dir(Color c) { debug_color_dir = c; }
Color FlowField::get_debug_color_dir() const { return debug_color_dir; }

void FlowField::set_debug_color_cell(Color c) { debug_color_cell = c; }
Color FlowField::get_debug_color_cell() const { return debug_color_cell; }

Vector2i FlowField::current_goal_cell() const { return _goal_cell; }
bool FlowField::is_ready() const { return !_computing && _dirs_front.size() > 0; }
int32_t FlowField::flow_version() const { return _version; }

void FlowField::capture_tile_size()
{
    _capture_tile_size();
}

void FlowField::build_walkable_snapshot()
{
    _build_walkable_snapshot();
}
Vector2i FlowField::get_tile_size() const
{
    return tile_size;
}

Array FlowField::neighbors(Vector2i cell, bool diag_ok)
{
    return _neighbors(cell, diag_ok);
}

void FlowField::_capture_tile_size()
{
    if (floor_layer && floor_layer->get_tile_set().is_valid())
    {
        Ref<TileSet> ts_ref = floor_layer->get_tile_set();
        Vector2 ts = ts_ref->get_tile_size();
        tile_size = Vector2i((int)ts.x, (int)ts.y);
        UtilityFunctions::print("Tile size captured:", tile_size);
    }
    else
    {
        UtilityFunctions::print("FlowField: no valid floor_layer or tile_set");
    }
}

void FlowField::_build_walkable_snapshot()
{
    _walkable.clear();
    _walkable_set.clear();

    if (!floor_layer)
    {
        UtilityFunctions::print("FlowField: no floor_layer, aborting snapshot");
        return;
    }

    Array floors = floor_layer->get_used_cells();
    Dictionary wall_set;

    if (wall_layer)
    {
        Array walls = wall_layer->get_used_cells();
        for (int i = 0; i < walls.size(); i++)
        {
            Vector2i w = walls[i];
            wall_set[w] = true;
            for (int dx = -1; dx <= 1; dx++)
            {
                for (int dy = -1; dy <= 1; dy++)
                {
                    Vector2i n(w.x + dx, w.y + dy);
                    wall_set[n] = true;
                }
            }
        }
    }

    for (int i = 0; i < floors.size(); i++)
    {
        Vector2i c = floors[i];
        if (!wall_set.has(c))
        {
            _walkable.append(c);
            _walkable_set[c] = true;
        }
    }

    UtilityFunctions::print("FlowField: walkable cells =", (int64_t)_walkable.size());
}

Array FlowField::_neighbors(Vector2i cell, bool diag_ok) const
{
    Array result;
    for (const Vector2i &d : ORTHO)
    {
        Vector2i n = cell + d;
        if (_walkable_set.has(n))
            result.append(n);
    }
    if (diag_ok)
    {
        for (const Vector2i &d : DIAG)
        {
            Vector2i n2 = cell + d;
            if (!_walkable_set.has(n2))
                continue;
            Vector2i side1(cell.x + d.x, cell.y);
            Vector2i side2(cell.x, cell.y + d.y);
            if (_walkable_set.has(side1) && _walkable_set.has(side2))
                result.append(n2);
        }
    }
    return result;
}





Vector2i FlowField::world_to_cell(Vector2) const { return Vector2i(); }
Vector2 FlowField::cell_to_world(Vector2i cell) const {
    if (!floor_layer) {
        UtilityFunctions::print("floor_layer null");
        return Vector2();
    }

    Vector2 layer_origin = floor_layer->get_global_position();
    UtilityFunctions::print("layer origin:", layer_origin);
    UtilityFunctions::print("tile_size:", tile_size);
    UtilityFunctions::print("cell:", cell);

    Vector2 world_pos = layer_origin + Vector2(
        cell.x * tile_size.x + tile_size.x * 0.5,
        cell.y * tile_size.y + tile_size.y * 0.5
    );

    UtilityFunctions::print("world_pos:", world_pos);
    return world_pos;
}


void FlowField::rebuild_async(Vector2) {}
void FlowField::_start_thread(Vector2i) {}
int32_t FlowField::_cost_step(Vector2i, Vector2i) const { return 0; }
Array FlowField::_make_dist_array(Rect2i) const { return Array(); }
int32_t FlowField::_cell_index(Vector2i, Rect2i) const { return 0; }
bool FlowField::_in_bounds(Vector2i, Rect2i) const { return false; }
int32_t FlowField::_get_dist(Vector2i, Rect2i, const Array &) const { return 0; }
void FlowField::_set_dist(Vector2i, int32_t, Rect2i, Array &) {}
void FlowField::_thread_compute(Dictionary) {}
void FlowField::_thread_done_arr(const Array &, Rect2i) {}
void FlowField::_swap_buffers() {}

void FlowField::_heap_push(Array &, const Array &) {}
Array FlowField::_heap_pop(Array &heap) { return heap; }
bool FlowField::_is_near_wall(Vector2i) const { return false; }
Vector2i FlowField::_find_nearest_walkable(Vector2i origin, const Array &) const { return origin; }
void FlowField::_join_thread_if_any() {}
Vector2 FlowField::sample_dir_cell(Vector2i) const { return Vector2(); }
Vector2 FlowField::sample_dir_world(Vector2) const { return Vector2(); }
Vector2 FlowField::sample_dir_world_bilinear(Vector2) const { return Vector2(); }
