#ifndef PROJECTILE_SYSTEM_NATIVE_H
#define PROJECTILE_SYSTEM_NATIVE_H

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/dictionary.hpp>
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

        // Build + upload the static wall mask from the wall TileMapLayer.
        // `bounds_layer` (floor layer) supplies the used rect/origin; if null, the
        // wall layer's own used rect is used. Call when walls change.
        void set_wall_layer(Object *wall_layer, Object *bounds_layer);
        void clear_walls();

        void set_paused(bool p) { paused = p; }
    };
}

#endif
