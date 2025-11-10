#include "flow_field_native.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <queue>
#include <unordered_map>
#include <unordered_set>
#include <limits>
#include <cmath>

using namespace godot;

struct Vector2iHash {
    size_t operator()(const Vector2i &v) const noexcept {
        return (size_t(v.x) * 73856093u) ^ (size_t(v.y) * 19349663u);
    }
};

struct FFNode {
    Vector2i cell;
    int cost;
    bool operator<(const FFNode &o) const { return cost > o.cost; }
};

void FlowFieldNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_floor_layer", "node"), &FlowFieldNative::set_floor_layer);
    ClassDB::bind_method(D_METHOD("get_floor_layer"), &FlowFieldNative::get_floor_layer);
    ClassDB::bind_method(D_METHOD("set_wall_layer", "node"), &FlowFieldNative::set_wall_layer);
    ClassDB::bind_method(D_METHOD("get_wall_layer"), &FlowFieldNative::get_wall_layer);
    ClassDB::bind_method(D_METHOD("rebuild_async", "goal"), &FlowFieldNative::rebuild_async);
    ClassDB::bind_method(D_METHOD("sample_dir_world", "world_pos"), &FlowFieldNative::sample_dir_world);
    ClassDB::bind_method(D_METHOD("get_goal_world"), &FlowFieldNative::get_goal_world);
}

void FlowFieldNative::set_floor_layer(Object *node) { floor_layer = Object::cast_to<TileMapLayer>(node); }
void FlowFieldNative::set_wall_layer(Object *node) { wall_layer = Object::cast_to<TileMapLayer>(node); }
Object *FlowFieldNative::get_floor_layer() const { return floor_layer; }
Object *FlowFieldNative::get_wall_layer() const { return wall_layer; }

void FlowFieldNative::rebuild_async(Vector2 goal_world) {
    if (!floor_layer || !wall_layer)
        return;

    Rect2i used = floor_layer->get_used_rect();
    if (used.size.x <= 0 || used.size.y <= 0)
        return;

    field.resize(used.size.x, used.size.y);
    field.set_tile_size(floor_layer->get_tile_set()->get_tile_size().x);
    field.set_cell_origin(ffcore::Vec2i(used.position.x, used.position.y));

    std::unordered_set<Vector2i, Vector2iHash> wall_set;
    std::unordered_set<Vector2i, Vector2iHash> walkable_set;

    Array walls = wall_layer->get_used_cells();
    for (int i = 0; i < walls.size(); i++)
        wall_set.insert((Vector2i)walls[i]);

    Array floors = floor_layer->get_used_cells();
    for (int i = 0; i < floors.size(); i++) {
        Vector2i c = floors[i];
        if (!wall_set.count(c))
            walkable_set.insert(c);
    }

    Vector2 local = floor_layer->to_local(goal_world);
    Vector2i goal_cell = floor_layer->local_to_map(local);
    Vector2 goal_center = floor_layer->to_global(floor_layer->map_to_local(goal_cell));
    goal_world = goal_center;

    if (!walkable_set.count(goal_cell))
        return;

    const Vector2i ORTHO[4] = {{1,0},{-1,0},{0,1},{0,-1}};
    const Vector2i DIAG[4] = {{1,1},{-1,1},{1,-1},{-1,-1}};

    std::unordered_map<Vector2i,int,Vector2iHash> dist;
    for (auto &c : walkable_set)
        dist[c] = INT_MAX;

    std::priority_queue<FFNode> open;
    dist[goal_cell] = 0;
    open.push({goal_cell,0});

    while (!open.empty()) {
        FFNode cur = open.top(); open.pop();
        int dcur = dist[cur.cell];
        if (dcur < cur.cost) continue;

        for (int i = 0; i < 4; i++) {
            Vector2i n = cur.cell + ORTHO[i];
            if (!walkable_set.count(n)) continue;
            int nd = dcur + 100;
            if (nd < dist[n]) {
                dist[n] = nd;
                open.push({n,nd});
            }
        }

        for (int i = 0; i < 4; i++) {
            Vector2i n = cur.cell + DIAG[i];
            Vector2i side1(cur.cell.x + DIAG[i].x, cur.cell.y);
            Vector2i side2(cur.cell.x, cur.cell.y + DIAG[i].y);
            if (!walkable_set.count(n) || !walkable_set.count(side1) || !walkable_set.count(side2))
                continue;
            int nd = dcur + 141;
            if (nd < dist[n]) {
                dist[n] = nd;
                open.push({n,nd});
            }
        }
    }

    for (int y = 0; y < field.height(); y++) {
        for (int x = 0; x < field.width(); x++) {
            Vector2i c = used.position + Vector2i(x,y);
            if (!walkable_set.count(c)) {
                field.set_dir(x,y,{0,0});
                continue;
            }
            int dc = dist[c];
            if (dc == INT_MAX) {
                field.set_dir(x,y,{0,0});
                continue;
            }

            int best_d = dc;
            Vector2i best = c;

            for (int i = 0; i < 4; i++) {
                Vector2i n = c + ORTHO[i];
                if (!walkable_set.count(n)) continue;
                int dn = dist[n];
                if (dn < best_d) { best_d = dn; best = n; }
            }
            for (int i = 0; i < 4; i++) {
                Vector2i n = c + DIAG[i];
                Vector2i s1(c.x+DIAG[i].x,c.y);
                Vector2i s2(c.x,c.y+DIAG[i].y);
                if (!walkable_set.count(n) || !walkable_set.count(s1) || !walkable_set.count(s2))
                    continue;
                int dn = dist[n];
                if (dn < best_d) { best_d = dn; best = n; }
            }

            ffcore::Vec2 dir;
            if (best != c && best_d < dc) {
                dir = ffcore::Vec2(best.x - c.x, best.y - c.y);
                double len = std::sqrt(dir.x * dir.x + dir.y * dir.y);
                if (len > 1e-6) dir = dir / len;
            } else dir = ffcore::Vec2(0,0);

            field.set_dir(x,y,dir);
        }
    }

    // Neutralisation sur goal cell
    ffcore::Vec2i rel_goal(goal_cell.x - used.position.x, goal_cell.y - used.position.y);
    if (rel_goal.x >= 0 && rel_goal.y >= 0 &&
        rel_goal.x < field.width() && rel_goal.y < field.height())
        field.set_dir(rel_goal.x, rel_goal.y, ffcore::Vec2(0,0));

    field.set_goal_cell(rel_goal);
    queue_redraw();
}

Vector2 FlowFieldNative::sample_dir_world(Vector2 world_pos) const {
    if (!floor_layer || field.width() == 0)
        return Vector2();

    Vector2 local = floor_layer->to_local(world_pos);
    Vector2i cell = floor_layer->local_to_map(local);
    Rect2i used = floor_layer->get_used_rect();
    Vector2i rel = cell - used.position;

    if (rel.x < 0 || rel.y < 0 || rel.x >= field.width() || rel.y >= field.height())
        return Vector2();

    ffcore::Vec2 d = field.dir(rel.x, rel.y);
    return Vector2(d.x, d.y);
}

void FlowFieldNative::_draw() {
    if (!debug_draw || !floor_layer)
        return;

    Vector2 cell_size = floor_layer->get_tile_set()->get_tile_size();
    int skip = Math::max(1, debug_stride);
    int count = 0;
    Rect2i used = floor_layer->get_used_rect();

    for (int y = 0; y < field.height(); y += skip) {
        for (int x = 0; x < field.width(); x += skip) {
            ffcore::Vec2 dir_v = field.dir(x,y);
            if (dir_v.x == 0 && dir_v.y == 0) continue;
            Vector2i cell = used.position + Vector2i(x,y);
            Vector2 local_center = floor_layer->map_to_local(cell);
            Vector2 world_center = floor_layer->to_global(local_center);
            Vector2 draw_center = to_local(world_center);
            Vector2 dir(dir_v.x,dir_v.y);
            float len = cell_size.x * debug_scale * 0.5f;
            draw_line(draw_center, draw_center + dir * len, debug_color_dir, 1.0);
            count++;
        }
    }
    UtilityFunctions::print("FlowFieldNative: debug draw vectors =", count);
}
