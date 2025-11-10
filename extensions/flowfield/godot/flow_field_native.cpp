#include "flow_field_native.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <queue>
#include <vector>
#include <unordered_set>
#include <unordered_map>


using namespace godot;

void FlowFieldNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_floor_layer", "node"), &FlowFieldNative::set_floor_layer);
    ClassDB::bind_method(D_METHOD("get_floor_layer"), &FlowFieldNative::get_floor_layer);
    ClassDB::bind_method(D_METHOD("set_wall_layer", "node"), &FlowFieldNative::set_wall_layer);
    ClassDB::bind_method(D_METHOD("get_wall_layer"), &FlowFieldNative::get_wall_layer);
    ClassDB::bind_method(D_METHOD("rebuild_async", "goal"), &FlowFieldNative::rebuild_async);
}

void FlowFieldNative::set_floor_layer(Object *node)
{
    floor_layer = Object::cast_to<TileMapLayer>(node);
    if (floor_layer)
        UtilityFunctions::print("FlowFieldNative: floor_layer assigned (valid pointer).");
    else
        UtilityFunctions::print("FlowFieldNative: set_floor_layer called but cast failed.");
}

void FlowFieldNative::set_wall_layer(Object *node)
{
    wall_layer = Object::cast_to<TileMapLayer>(node);
    if (wall_layer)
        UtilityFunctions::print("FlowFieldNative: wall_layer assigned (valid pointer).");
    else
        UtilityFunctions::print("FlowFieldNative: set_wall_layer called but cast failed.");
}

Object *FlowFieldNative::get_floor_layer() const
{
    return floor_layer;
}

Object *FlowFieldNative::get_wall_layer() const
{
    return wall_layer;
}

void FlowFieldNative::rebuild_async(Vector2 goal)
{
    Node *parent = get_parent();
    if (!parent) {
        UtilityFunctions::push_warning("FlowFieldNative: no parent node.");
        return;
    }

    Node *floor_node = parent->get_node_or_null("MonTilemap/floor");
    Node *wall_node  = parent->get_node_or_null("MonTilemap/wallz");
    if (!floor_node || !wall_node) {
        UtilityFunctions::push_warning("FlowFieldNative: floor or wall node not found.");
        return;
    }

    floor_layer = Object::cast_to<TileMapLayer>(floor_node);
    wall_layer  = Object::cast_to<TileMapLayer>(wall_node);
    if (!floor_layer || !wall_layer) {
        UtilityFunctions::push_warning("FlowFieldNative: invalid TileMapLayer cast.");
        return;
    }

    goal_world = goal;

    Rect2i used = floor_layer->get_used_rect();
    if (used.size.x <= 0 || used.size.y <= 0) {
        UtilityFunctions::push_warning("FlowFieldNative: floor_layer used_rect empty.");
        return;
    }

    // snapshot walkables = floor - walls (sans extrusion par défaut)
    std::unordered_set<Vector2i, Vector2iHash> wall_set;
    {
        Array walls = wall_layer->get_used_cells();
        for (int i = 0; i < walls.size(); i++) wall_set.insert((Vector2i)walls[i]);
    }

    walkable_set.clear();
    walkable_cells.clear();
    {
        Array floors = floor_layer->get_used_cells();
        walkable_cells.reserve(floors.size());
        for (int i = 0; i < floors.size(); i++) {
            Vector2i c = floors[i];
            if (wall_set.find(c) == wall_set.end()) {
                walkable_set.insert(c);
                walkable_cells.push_back(c);
            }
        }
    }
    used_rect = used;

    // init field
    field.resize(used.size.x, used.size.y);
    field.set_tile_size(floor_layer->get_tile_set()->get_tile_size().x);

    // goal cell sécurisé (snap au plus proche walkable)
    auto snap_to_walkable = [&](Vector2i gc) {
        if (walkable_set.find(gc) != walkable_set.end()) return gc;
        double best = 1e18; Vector2i best_c = gc;
        for (const Vector2i &c : walkable_cells) {
            double dx = double(c.x - gc.x), dy = double(c.y - gc.y);
            double d2 = dx*dx + dy*dy;
            if (d2 < best) { best = d2; best_c = c; }
        }
        return best_c;
    };

    Vector2i goal_cell = floor_layer->local_to_map(floor_layer->to_local(goal_world));
    goal_cell = snap_to_walkable(goal_cell);

    // Dijkstra (sans extrusion ; diagonales autorisées seulement si non corner-cut)
    const Vector2i ORTHO[4] = { {1,0},{-1,0},{0,1},{0,-1} };
    const Vector2i DIAG [4] = { {1,1},{-1,1},{1,-1},{-1,-1} };

    auto in_bounds = [&](Vector2i c){
        return c.x >= used.position.x && c.y >= used.position.y &&
               c.x < used.position.x + used.size.x &&
               c.y < used.position.y + used.size.y;
    };
    auto idx = [&](Vector2i c){
        return (c.y - used.position.y) * used.size.x + (c.x - used.position.x);
    };

    const int64_t N = (int64_t)used.size.x * (int64_t)used.size.y;
    std::vector<int> dist(N, INT_MAX);
    std::vector<ffcore::Vec2> dirs(N, ffcore::Vec2{0,0});

    struct QN { Vector2i c; int d; bool operator<(const QN&o) const { return d>o.d; } };
    std::priority_queue<QN> pq;

    auto set_dist = [&](Vector2i c, int v){ dist[(size_t)idx(c)] = v; };
    auto get_dist = [&](Vector2i c){ return dist[(size_t)idx(c)]; };

    set_dist(goal_cell, 0);
    pq.push({goal_cell, 0});

    while (!pq.empty()) {
        QN cur = pq.top(); pq.pop();
        if (cur.d != get_dist(cur.c)) continue;

        // 4-neigh
        for (int k=0;k<4;k++) {
            Vector2i n = cur.c + ORTHO[k];
            if (!in_bounds(n)) continue;
            if (walkable_set.find(n) == walkable_set.end()) continue;
            int nd = cur.d + 100;
            if (nd < get_dist(n)) { set_dist(n, nd); pq.push({n, nd}); }
        }
        // diag avec double-side check
        for (int k=0;k<4;k++) {
            Vector2i n = cur.c + DIAG[k];
            if (!in_bounds(n)) continue;
            if (walkable_set.find(n) == walkable_set.end()) continue;
            Vector2i s1(cur.c.x + DIAG[k].x, cur.c.y);
            Vector2i s2(cur.c.x, cur.c.y + DIAG[k].y);
            if (walkable_set.find(s1)==walkable_set.end() || walkable_set.find(s2)==walkable_set.end()) continue;
            int nd = cur.d + 141;
            if (nd < get_dist(n)) { set_dist(n, nd); pq.push({n, nd}); }
        }
    }

    // champ de directions
    for (const Vector2i &c : walkable_cells) {
        if (!in_bounds(c)) continue;
        int dc = get_dist(c);
        if (dc==INT_MAX) { dirs[(size_t)idx(c)] = {0,0}; continue; }

        int best = dc; Vector2i best_c = c;
        // 4-neigh
        for (int k=0;k<4;k++) {
            Vector2i n = c + ORTHO[k];
            if (!in_bounds(n)) continue;
            if (walkable_set.find(n) == walkable_set.end()) continue;
            int dn = get_dist(n);
            if (dn < best) { best = dn; best_c = n; }
        }
        // diag avec double-side check
        for (int k=0;k<4;k++) {
            Vector2i n = c + DIAG[k];
            if (!in_bounds(n)) continue;
            if (walkable_set.find(n) == walkable_set.end()) continue;
            Vector2i s1(c.x + DIAG[k].x, c.y);
            Vector2i s2(c.x, c.y + DIAG[k].y);
            if (walkable_set.find(s1)==walkable_set.end() || walkable_set.find(s2)==walkable_set.end()) continue;
            int dn = get_dist(n);
            if (dn < best) { best = dn; best_c = n; }
        }

        ffcore::Vec2 out{0,0};
        if (best_c != c && best < dc) {
            float dx = float(best_c.x - c.x);
            float dy = float(best_c.y - c.y);
            float l2 = dx*dx + dy*dy;
            if (l2 > 0.0f) { float inv = Math::sqrt(l2); out = ffcore::Vec2{dx/inv, dy/inv}; }
        }
        dirs[(size_t)idx(c)] = out;
    }

    // charger dans le buffer du champ
    for (int y=0; y<used.size.y; ++y)
        for (int x=0; x<used.size.x; ++x)
            field.set_dir(x, y, dirs[(size_t)((y)*used.size.x + x)]);

    queue_redraw();
}




void FlowFieldNative::_draw()
{
    if (!debug_draw || !floor_layer)
        return;

    set_z_index(999);

    Vector2 cell_size = floor_layer->get_tile_set()->get_tile_size();
    int skip = Math::max(1, debug_stride);
    int count = 0;

    for (int y = 0; y < field.height(); y += skip)
    {
        for (int x = 0; x < field.width(); x += skip)
        {
            ffcore::Vec2 dir_v = field.dir(x, y);
            if (dir_v.x == 0 && dir_v.y == 0)
                continue;

            Vector2i cell(x, y);

            // Position exacte du centre de cellule (identique au legacy)
            Vector2 local_center = floor_layer->map_to_local(cell);
            Vector2 world_center = floor_layer->to_global(local_center);
            Vector2 local_draw = to_local(world_center);

            Vector2 dir(dir_v.x, dir_v.y);
            Vector2 p1 = local_draw + dir * cell_size * debug_scale;

            draw_line(local_draw, p1, debug_color_dir, 1.0);
            if (debug_stride >= 4)
                draw_circle(local_draw, 1.0, debug_color_cell);

            count++;
        }
    }

    UtilityFunctions::print("FlowFieldNative: debug draw vectors =", count);
}