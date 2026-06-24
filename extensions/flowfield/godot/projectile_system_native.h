#ifndef PROJECTILE_SYSTEM_NATIVE_H
#define PROJECTILE_SYSTEM_NATIVE_H

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include "../projectile/projectile_system.h"

namespace godot
{
    class ProjectileSystemNative : public Node2D
    {
        GDCLASS(ProjectileSystemNative, Node2D);

    private:
        ffcore::ProjectileSystem system;

        Node2D *steering_node = nullptr;
        Node2D *grid_node = nullptr;
        bool paused = false;

    public:
        static void _bind_methods();

        ProjectileSystemNative();
        ~ProjectileSystemNative() override;

        void _ready() override;
        void _process(double delta) override;

        void set_steering(Object *obj);
        void set_grid(Object *obj);

        int register_type(const Dictionary &cfg);
        bool fire(int type_id, const Vector2 &pos, const Vector2 &dir, int owner_agent_id, int affected_smash_classes);

        PackedVector2Array get_active_positions(int type_id) const;
        int get_active_count(int type_id) const;
        int get_type_count() const;

        // Drain this frame's projectile impact events (AoE despawns). Each entry:
        // { pos, dir, radius, type_id, kind, collider_mask, collider_cell }.
        // kind: 0=wall, 1=expiry, 2=agent.
        Array get_impacts() const;

        // Compatibility wrapper: upload one TileMapLayer as channel bit 0.
        // `bounds_layer` supplies the tile size when available.
        void set_wall_layer(Object *wall_layer, Object *bounds_layer);
        void clear_walls();

        // Build one static-collider grid from generic TileMapLayer configs:
        // { layer:Object, channel:int, atlas_coords:Array[Vector2i] (optional) }.
        void set_static_collision_layers(const Array &configs, Object *bounds_layer);
        void clear_static_collisions();

        void set_paused(bool p) { paused = p; }
    };
}

#endif
