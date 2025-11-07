#include "flow_field.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <climits>
#include <chrono>

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
    ClassDB::bind_method(D_METHOD("store_floor_native"), &FlowField::store_floor_native);
    ClassDB::bind_method(D_METHOD("store_wall_native"), &FlowField::store_wall_native);

    ClassDB::bind_method(D_METHOD("sample_dir_cell", "cell"), &FlowField::sample_dir_cell);
    ClassDB::bind_method(D_METHOD("sample_dir_world", "world_pos"), &FlowField::sample_dir_world);
    ClassDB::bind_method(D_METHOD("sample_dir_world_bilinear", "world_pos"), &FlowField::sample_dir_world_bilinear);
}

FlowField::FlowField()
{
    set_process(true);
}

FlowField::~FlowField() {}

void FlowField::_ready() {}

void FlowField::_process(double)
{
    std::lock_guard<std::mutex> lock(_log_mutex);

    int flushed = 0;
    while (!_log_queue.empty() && flushed < 8)
    {
        UtilityFunctions::print(_log_queue.front());
        _log_queue.pop();
        flushed++;
    }

    if (_needs_redraw)
    {
        _needs_redraw = false;
        queue_redraw();
    }

    if (_has_pending && !_computing)
    {
        _has_pending = false;
        _start_thread(_pending_goal);
    }
}

void FlowField::_draw()
{
    if (!debug_draw || _dirs_front.is_empty())
        return;

    Vector2 cell_size = Vector2(tile_size);
    int skip = Math::max(1, debug_stride);
    int count = 0;

    for (int i = 0; i < _walkable.size(); i++)
    {
        if (i % skip != 0)
            continue;

        Vector2i cell = _walkable[i];
        if (!_walkable_set.has(cell))
            continue;
        if (!in_bounds(cell, _used_rect_front))
            continue;

        Vector2 dir = sample_dir_cell(cell);
        if (dir == Vector2())
            continue;

        Vector2 world_center = cell_to_world(cell);
        Vector2 local_center = to_local(world_center);
        Vector2 p1 = local_center + dir * cell_size * debug_scale;

        draw_line(local_center, p1, debug_color_dir, 1.0);
        if (debug_stride >= 4)
            draw_circle(local_center, 1.0, debug_color_cell);

        count++;
    }
}

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

    if (_floor_cells.empty())
    {
        UtilityFunctions::print("FlowField: no native floor data, call store_floor_native() first");
        return;
    }

    // S'assurer qu'on a au moins un wall_set valide (peut être vide)
    int wall_count = (int)_wall_cells.size();
    /* UtilityFunctions::print("FlowField: building snapshot from native data (walls:", wall_count, ")"); */

    for (const godot::Vector2i &c : _floor_cells)
    {
        if (_wall_set.find(c) == _wall_set.end())
        {
            _walkable.append(c);
            _walkable_set[c] = true;
        }
    }

    /* UtilityFunctions::print("FlowField: walkable snapshot built, cells:", _walkable.size()); */
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
    /* UtilityFunctions::print("DEBUG CPP world_to_cell call, world_pos=", world_pos); */

    if (!floor_layer)
        return Vector2i();

    Vector2 local = floor_layer->get_global_transform().affine_inverse().xform(world_pos);
    Vector2i cell = floor_layer->local_to_map(local);

    /* UtilityFunctions::print("DEBUG CPP result cell=", cell); */
    return cell;
}

Vector2 FlowField::cell_to_world(Vector2i cell) const
{
    if (!floor_layer)
        return Vector2();
    Vector2 local_center = floor_layer->map_to_local(cell);
    return floor_layer->to_global(local_center);
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
    _join_thread_if_any();

    if (!floor_layer)
        return;

    // Correction : mémoriser le goal courant
    _goal_cell = goal_cell;

    Rect2i used = floor_layer->get_used_rect();

    Dictionary payload;
    payload["goal_cell"] = goal_cell;
    payload["used_rect"] = used;
    payload["walkable"] = _walkable;
    payload["walkable_set"] = _walkable_set;
    payload["allow_diagonals"] = allow_diagonals;

    {
        std::lock_guard<std::mutex> lock(_log_mutex);
        /* UtilityFunctions::print("DEBUG FF _start_thread: goal_cell set to", goal_cell); */
    }

    _computing = true;
    _std_thread = std::thread([this, payload]()
                              { _thread_compute(payload); });
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

void FlowField::_thread_done_arr(const Array &dirs_arr, Rect2i used)
{
    _dirs_back = dirs_arr;
    _used_rect_back = used;
    _swap_buffers();
    _computing = false;

    {
        std::lock_guard<std::mutex> lock(_log_mutex);
        /* _log_queue.push("FlowField: thread done"); */
    }

    _needs_redraw = debug_draw;
}

void FlowField::_swap_buffers()
{
    _dirs_front = _dirs_back;
    _used_rect_front = _used_rect_back;
}

void FlowField::_heap_push(Array &, const Array &) {}
Array FlowField::_heap_pop(Array &heap) { return heap; }
bool FlowField::_is_near_wall(Vector2i) const { return false; }

Vector2i FlowField::_find_nearest_walkable(Vector2i origin, const Array &walkable) const
{
    if (walkable.is_empty())
        return origin;
    Vector2i best = origin;
    double best_d2 = 1e18;
    for (int i = 0; i < walkable.size(); i++)
    {
        Vector2i c = walkable[i];
        double dx = double(c.x - origin.x);
        double dy = double(c.y - origin.y);
        double d2 = dx * dx + dy * dy;
        if (d2 < best_d2)
        {
            best_d2 = d2;
            best = c;
        }
    }
    return best;
}

void FlowField::_join_thread_if_any()
{
    if (_std_thread.joinable())
        _std_thread.join();
}

void FlowField::_thread_compute(Dictionary payload)
{
    using namespace std::chrono;
    auto t0 = high_resolution_clock::now();
    /* UtilityFunctions::print("THREAD STARTED!"); */

    _computing = true;
    _version++;

    // Validation payload
    if (!payload.has("goal_cell") || !payload.has("used_rect"))
    {
        std::lock_guard<std::mutex> lock(_log_mutex);
        _log_queue.push("FlowField: thread error invalid payload");
        _computing = false;
        return;
    }

    Vector2i goal_cell = payload["goal_cell"];
    Rect2i used = payload["used_rect"];

    // Récupération des données pré-construites
    Array walkable = payload["walkable"];
    Dictionary walkable_set = payload["walkable_set"];

    // Tableaux
    Array dist_arr = make_dist_array(used);
    Array dirs_arr;
    dirs_arr.resize(dist_arr.size());
    for (int64_t i = 0; i < dirs_arr.size(); i++)
        dirs_arr[i] = Vector2();

    // Goal valide
    if (!walkable_set.has(goal_cell))
        goal_cell = _find_nearest_walkable(goal_cell, walkable);

    // ✅ DÉCLARATION DE FFNode ICI
    struct FFNode
    {
        Vector2i c;
        int32_t d;
        bool operator<(const FFNode &o) const { return d > o.d; }
    };

    // ✅ DÉCLARATION DES VARIABLES
    dist_arr = set_dist(goal_cell, 0, used, dist_arr);
    std::priority_queue<FFNode> open;
    open.push(FFNode{goal_cell, 0});

    int64_t count = 0;

    // Buffer réutilisable pour voisins (optionnel mais recommandé)
    static thread_local std::vector<Vector2i> nbs_buffer;
    nbs_buffer.reserve(8);

    // ✅ BOUCLE DIJKSTRA
    while (!open.empty())
    {
        FFNode cur = open.top();
        open.pop();

        int32_t dcur = get_dist(cur.c, used, dist_arr);
        if (cur.d != dcur)
            continue;

        nbs_buffer.clear();

        // Ortho
        for (int k = 0; k < 4; k++)
        {
            Vector2i n = cur.c + ORTHO[k];
            if (walkable_set.has(n))
                nbs_buffer.push_back(n);
        }

        // Diag
        if (allow_diagonals)
        {
            for (int k = 0; k < 4; k++)
            {
                Vector2i n = cur.c + DIAG[k];
                if (!walkable_set.has(n))
                    continue;
                Vector2i side1(cur.c.x + DIAG[k].x, cur.c.y);
                Vector2i side2(cur.c.x, cur.c.y + DIAG[k].y);
                if (walkable_set.has(side1) && walkable_set.has(side2))
                    nbs_buffer.push_back(n);
            }
        }

        // Traiter voisins
        for (const Vector2i &n : nbs_buffer)
        {
            if (!in_bounds(n, used))
                continue;

            int32_t nd = dcur + cost_step(cur.c, n);
            int32_t old = get_dist(n, used, dist_arr);
            if (nd < old)
            {
                dist_arr = set_dist(n, nd, used, dist_arr);
                open.push(FFNode{n, nd});
            }
        }
        count++;
    }

    // Champ de directions (reste identique)
    for (int i = 0; i < walkable.size(); i++)
    {
        Vector2i c = walkable[i];
        if (!in_bounds(c, used))
            continue;

        int32_t dc = get_dist(c, used, dist_arr);
        if (dc == INT_MAX)
        {
            int64_t idx = (int64_t)cell_index(c, used);
            if (idx >= 0 && idx < dirs_arr.size())
                dirs_arr[idx] = Vector2();
            continue;
        }

        int32_t best_d = dc;
        Vector2i best = c;

        // Ortho
        for (int k = 0; k < 4; k++)
        {
            Vector2i n = c + ORTHO[k];
            if (!walkable_set.has(n))
                continue;
            int32_t dn = get_dist(n, used, dist_arr);
            if (dn < best_d)
            {
                best_d = dn;
                best = n;
            }
        }

        // Diag
        if (allow_diagonals)
        {
            for (int k = 0; k < 4; k++)
            {
                Vector2i n = c + DIAG[k];
                if (!walkable_set.has(n))
                    continue;
                Vector2i side1(c.x + DIAG[k].x, c.y);
                Vector2i side2(c.x, c.y + DIAG[k].y);
                if (!(walkable_set.has(side1) && walkable_set.has(side2)))
                    continue;
                int32_t dn = get_dist(n, used, dist_arr);
                if (dn < best_d)
                {
                    best_d = dn;
                    best = n;
                }
            }
        }

        Vector2 out = Vector2();
        if (best != c && best_d < dc)
        {
            Vector2 delta = Vector2((float)(best.x - c.x), (float)(best.y - c.y));
            float len2 = delta.x * delta.x + delta.y * delta.y;
            if (len2 > 0.0f)
                out = delta / Math::sqrt(len2);
        }

        int64_t idx = (int64_t)cell_index(c, used);
        if (idx >= 0 && idx < dirs_arr.size())
            dirs_arr[idx] = out;
    }

    {
        std::lock_guard<std::mutex> lock(_log_mutex);
        /* _log_queue.push("FlowField: compute done, cells=" + String::num_int64(count)); */
    }

    // --- Zone neutre autour du goal pour amortir le flux ---
    int radius_neutral = 0; // rayon en tuiles autour du goal
    for (int dx = -radius_neutral; dx <= radius_neutral; dx++)
    {
        for (int dy = -radius_neutral; dy <= radius_neutral; dy++)
        {
            Vector2i n = goal_cell + Vector2i(dx, dy);
            if (!in_bounds(n, used))
                continue;
            int64_t idx = (int64_t)cell_index(n, used);
            if (idx < 0 || idx >= dirs_arr.size())
                continue;
            dirs_arr[idx] = Vector2(); // direction nulle
        }
    }

    _thread_done_arr(dirs_arr, used);
    _computing = false;

    auto t1 = high_resolution_clock::now();
    double ms = duration_cast<milliseconds>(t1 - t0).count();
    if (ms > 15)
        UtilityFunctions::print("Alert build time (ms):", ms);
}

Vector2 FlowField::sample_dir_cell(Vector2i cell) const
{
    if (!in_bounds(cell, _used_rect_front))
        return Vector2();
    int64_t idx = (int64_t)cell_index(cell, _used_rect_front);
    if (idx < 0 || idx >= _dirs_front.size())
        return Vector2();
    Variant v = _dirs_front[idx];
    if (v.get_type() != Variant::VECTOR2)
        return Vector2();
    return (Vector2)v;
}

Vector2 FlowField::sample_dir_world(Vector2 world_pos) const
{
    if (_dirs_front.is_empty())
        return Vector2();
    Vector2i c = world_to_cell(world_pos);
    return sample_dir_cell(c);
}

Vector2 FlowField::sample_dir_world_bilinear(Vector2 world_pos) const
{
    if (_dirs_front.is_empty() || !floor_layer)
        return Vector2();

    Vector2 local = floor_layer->to_local(world_pos);
    float fx = local.x / (float)tile_size.x;
    float fy = local.y / (float)tile_size.y;

    int x0 = (int)Math::floor(fx), y0 = (int)Math::floor(fy);
    int x1 = x0 + 1, y1 = y0 + 1;

    Vector2 c00 = sample_dir_cell(Vector2i(x0, y0));
    Vector2 c10 = sample_dir_cell(Vector2i(x1, y0));
    Vector2 c01 = sample_dir_cell(Vector2i(x0, y1));
    Vector2 c11 = sample_dir_cell(Vector2i(x1, y1));

    float tx = fx - (float)x0;
    float ty = fy - (float)y0;

    Vector2 a = c00.lerp(c10, tx);
    Vector2 b = c01.lerp(c11, tx);
    Vector2 v = a.lerp(b, ty);

    float len2 = v.x * v.x + v.y * v.y;
    return (len2 > 1e-6f) ? (v / Math::sqrt(len2)) : Vector2();
}

void FlowField::_exit_tree()
{
    _join_thread_if_any();
}

void FlowField::store_floor_native()
{
    _floor_cells.clear();
    _floor_set.clear();

    if (!floor_layer)
    {
        UtilityFunctions::print("FlowField: floor_layer is NULL");
        return;
    }

    Array floors = floor_layer->get_used_cells();
    if (floors.is_empty())
    {
        UtilityFunctions::print("FlowField: floor_layer empty");
        return;
    }

    _floor_cells.reserve(floors.size());
    for (int i = 0; i < floors.size(); i++)
    {
        godot::Vector2i c = floors[i];
        _floor_cells.push_back(c);
        _floor_set.insert(c);
    }

    _used_rect_floor = floor_layer->get_used_rect();

    /* UtilityFunctions::print("FlowField: stored floor native, cells:", (int)_floor_cells.size()); */
}

void FlowField::store_wall_native()
{
    _wall_cells.clear();
    _wall_set.clear();

    if (!wall_layer)
    {
        UtilityFunctions::print("FlowField: wall_layer is NULL");
        return;
    }

    Array walls = wall_layer->get_used_cells();
    if (walls.is_empty())
    {
        UtilityFunctions::print("FlowField: wall_layer empty");
        return;
    }

    _wall_cells.reserve(walls.size());
    for (int i = 0; i < walls.size(); i++)
    {
        godot::Vector2i c = walls[i];
        _wall_cells.push_back(c);
        _wall_set.insert(c);
    }

    _used_rect_wall = wall_layer->get_used_rect();

    /*  UtilityFunctions::print("FlowField: stored wall native, cells:", (int)_wall_cells.size()); */
}
