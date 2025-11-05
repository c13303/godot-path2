#include "flow_field.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <climits>

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
    ClassDB::bind_method(D_METHOD("build_walkable_snapshot"), &FlowField::build_walkable_snapshot);
    ClassDB::bind_method(D_METHOD("neighbors", "cell", "diag_ok"), &FlowField::neighbors);

    ClassDB::bind_method(D_METHOD("cell_to_world", "cell"), &FlowField::cell_to_world);
    ClassDB::bind_method(D_METHOD("world_to_cell", "world_pos"), &FlowField::world_to_cell);

    ClassDB::bind_method(D_METHOD("get_tile_size"), &FlowField::get_tile_size);
    ClassDB::bind_method(D_METHOD("capture_tile_size"), &FlowField::capture_tile_size);

    ClassDB::bind_method(D_METHOD("cost_step", "a", "b"), &FlowField::cost_step);
    ClassDB::bind_method(D_METHOD("cell_index", "c", "used"), &FlowField::cell_index);
    ClassDB::bind_method(D_METHOD("in_bounds", "c", "used"), &FlowField::in_bounds);

    ClassDB::bind_method(D_METHOD("make_dist_array", "rect"), &FlowField::make_dist_array);
    ClassDB::bind_method(D_METHOD("get_dist", "c", "used", "dist_arr"), &FlowField::get_dist);
    ClassDB::bind_method(D_METHOD("set_dist", "c", "v", "used", "dist_arr"), &FlowField::set_dist);
}

FlowField::FlowField()
{
    set_process(true);
}

FlowField::~FlowField() {}

void FlowField::_ready() {}
void FlowField::_exit_tree() { _join_thread_if_any(); }

void FlowField::_process(double)
{
    std::lock_guard<std::mutex> lock(_log_mutex);
    while (!_log_queue.empty())
        _log_queue.pop();

    if (_has_pending && !_computing)
    {
        _has_pending = false;
        _start_thread(_pending_goal);
    }
}

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

void FlowField::capture_tile_size() { _capture_tile_size(); }
void FlowField::build_walkable_snapshot() { _build_walkable_snapshot(); }
Vector2i FlowField::get_tile_size() const { return tile_size; }
Array FlowField::neighbors(Vector2i cell, bool diag_ok) { return _neighbors(cell, diag_ok); }

void FlowField::_capture_tile_size()
{
    if (floor_layer && floor_layer->get_tile_set().is_valid())
    {
        Ref<TileSet> ts_ref = floor_layer->get_tile_set();
        Vector2 ts = ts_ref->get_tile_size();
        tile_size = Vector2i((int)ts.x, (int)ts.y);
    }
}

void FlowField::_build_walkable_snapshot()
{
    _walkable.clear();
    _walkable_set.clear();

    if (!floor_layer)
        return;

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
                for (int dy = -1; dy <= 1; dy++)
                    wall_set[Vector2i(w.x + dx, w.y + dy)] = true;
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

Vector2i FlowField::world_to_cell(Vector2 world_pos) const
{
    if (!floor_layer)
        return Vector2i();
    Vector2 layer_origin = floor_layer->get_global_position();
    Vector2 local = world_pos - layer_origin;
    int x = (int)Math::floor(local.x / (double)tile_size.x);
    int y = (int)Math::floor(local.y / (double)tile_size.y);
    return Vector2i(x, y);
}

Vector2 FlowField::cell_to_world(Vector2i cell) const
{
    if (!floor_layer)
        return Vector2();
    Vector2 layer_origin = floor_layer->get_global_position();
    return layer_origin + Vector2(cell.x * tile_size.x + tile_size.x * 0.5, cell.y * tile_size.y + tile_size.y * 0.5);
}

void FlowField::rebuild_async(Vector2 goal_world)
{
    if (!floor_layer)
        return;

    Vector2i goal_cell = world_to_cell(goal_world);
    if (!_walkable_set.has(goal_cell))
        goal_cell = _find_nearest_walkable(goal_cell, _walkable);

    if (_computing)
    {
        _pending_goal = goal_cell;
        _has_pending = true;
        return;
    }

    _start_thread(goal_cell);
}

void FlowField::_start_thread(Vector2i goal_cell)
{
    if (_thread)
        _join_thread_if_any();

    if (!floor_layer)
        return;

    Rect2i used;
    used.position = floor_layer->get_used_rect().position;
    used.size = floor_layer->get_used_rect().size;

    Dictionary payload;
    payload["goal_cell"] = goal_cell;
    payload["used_rect"] = used;
    payload["walkable"] = _walkable;

    _computing = true;
    _thread = memnew(Thread);
    Callable task = callable_mp(this, &FlowField::_thread_compute).bind(payload);
    _thread->start(task);
}

int32_t FlowField::cost_step(Vector2i a, Vector2i b) const
{
    bool diag = (a.x != b.x) && (a.y != b.y);
    return diag ? 141 : 100;
}

int32_t FlowField::cell_index(Vector2i c, Rect2i used) const
{
    return (c.y - used.position.y) * used.size.x + (c.x - used.position.x);
}

bool FlowField::in_bounds(Vector2i c, Rect2i used) const
{
    return c.x >= used.position.x && c.y >= used.position.y &&
           c.x < used.position.x + used.size.x &&
           c.y < used.position.y + used.size.y;
}

Array FlowField::make_dist_array(Rect2i rect) const
{
    Array arr;
    int64_t n = (int64_t)rect.size.x * (int64_t)rect.size.y;
    arr.resize(n);
    for (int64_t i = 0; i < n; i++)
        arr[i] = (int64_t)INT_MAX;
    return arr;
}

int32_t FlowField::get_dist(Vector2i c, Rect2i used, const Array &dist_arr) const
{
    if (!in_bounds(c, used))
        return INT_MAX;
    int64_t idx = (int64_t)cell_index(c, used);
    if (idx < 0 || idx >= dist_arr.size())
        return INT_MAX;
    return (int32_t)(int64_t)dist_arr[idx];
}

Array FlowField::set_dist(Vector2i c, int32_t v, Rect2i used, Array dist_arr)
{
    if (in_bounds(c, used))
    {
        int64_t idx = (int64_t)cell_index(c, used);
        if (idx >= 0 && idx < dist_arr.size())
            dist_arr[idx] = (int64_t)v;
    }
    return dist_arr;
}

void FlowField::_thread_compute(Dictionary payload)
{
    _computing = true;
    _version++;

    if (!payload.has("goal_cell") || !payload.has("used_rect") || !payload.has("walkable"))
    {
        _computing = false;
        return;
    }

    Vector2i goal_cell = payload["goal_cell"];
    Rect2i used = payload["used_rect"];
    Array walkable = payload["walkable"];

    Array dist_arr = make_dist_array(used);
    Array dirs_arr;
    dirs_arr.resize(dist_arr.size());

    int64_t idx_goal = cell_index(goal_cell, used);
    if (idx_goal >= 0 && idx_goal < dist_arr.size())
        dist_arr[idx_goal] = 0;

    Array queue;
    queue.append(goal_cell);
    int64_t count = 0;

    while (queue.size() > 0)
    {
        Vector2i c = queue.pop_front();
        int32_t d = get_dist(c, used, dist_arr);
        Array nbs = _neighbors(c, allow_diagonals);

        for (int i = 0; i < nbs.size(); i++)
        {
            Vector2i n = nbs[i];
            if (!in_bounds(n, used))
                continue;

            int32_t nd = d + cost_step(c, n);
            int32_t old = get_dist(n, used, dist_arr);
            if (nd < old)
            {
                dist_arr = set_dist(n, nd, used, dist_arr);
                queue.append(n);
            }
        }
        count++;
    }

    _thread_done_arr(dirs_arr, used);
    _computing = false;
}

void FlowField::_thread_done_arr(const Array &dirs_arr, Rect2i used)
{
    _dirs_back = dirs_arr;
    _used_rect_back = used;
    _swap_buffers();
    _computing = false;
}

void FlowField::_swap_buffers()
{
    _dirs_front = _dirs_back;
    _used_rect_front = _used_rect_back;
}

void FlowField::_heap_push(Array &, const Array &) {}
Array FlowField::_heap_pop(Array &heap) { return heap; }
bool FlowField::_is_near_wall(Vector2i) const { return false; }
Vector2i FlowField::_find_nearest_walkable(Vector2i origin, const Array &) const { return origin; }

void FlowField::_join_thread_if_any()
{
    if (_thread)
    {
        _thread->wait_to_finish();
        memdelete(_thread);
        _thread = nullptr;
    }
}

Vector2 FlowField::sample_dir_cell(Vector2i) const { return Vector2(); }
Vector2 FlowField::sample_dir_world(Vector2) const { return Vector2(); }
Vector2 FlowField::sample_dir_world_bilinear(Vector2) const { return Vector2(); }
