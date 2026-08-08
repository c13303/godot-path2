#pragma once

#include "crowd_world_2d.h"
#include "../projectile/projectile_world.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

namespace godot
{
    class ProjectileWorld2D : public Node
    {
        GDCLASS(ProjectileWorld2D, Node);

    private:
        ffcore::ProjectileWorld world;
        bool automatic_step = true;

        static std::int64_t encode_type_handle(ffcore::ProjectileTypeHandle handle);
        static ffcore::ProjectileTypeHandle decode_type_handle(std::int64_t encoded);
        static std::int64_t encode_agent_handle(ffcore::AgentHandle handle);
        static ffcore::AgentHandle decode_agent_handle(std::int64_t encoded);
        static ffcore::ProjectileProfile make_profile(const Dictionary &configuration);

    protected:
        static void _bind_methods();

    public:
        void _physics_process(double delta) override;
        void set_automatic_step(bool enabled) { automatic_step = enabled; }
        bool is_automatic_step_enabled() const { return automatic_step; }
        void step(double delta) { world.update(delta); }
        void set_paused(bool paused) { world.set_paused(paused); }
        bool is_paused() const { return world.is_paused(); }
        void set_crowd_world(CrowdWorld2D *crowd);

        std::int64_t create_projectile_type(const Dictionary &configuration);
        bool update_projectile_type(std::int64_t type_handle,
                                    const Dictionary &configuration);
        bool remove_projectile_type(std::int64_t type_handle);
        PackedInt64Array get_projectile_type_handles() const;
        std::int64_t spawn_projectile(
            std::int64_t type_handle, Vector2 position, Vector2 direction,
            Vector2 inherited_velocity = Vector2(),
            std::int64_t owner_agent_handle = 0, std::int64_t caller_token = 0);
        bool set_static_collision_grid(
            Rect2i bounds, double cell_size, Vector2 world_origin,
            const PackedVector2Array &cells, const PackedInt64Array &masks);
        void clear_static_collision_grid() { world.clear_static_collision_grid(); }
        PackedVector2Array get_active_positions(std::int64_t type_handle) const;
        Array get_active_projectile_states(std::int64_t type_handle) const;
        int get_active_count(std::int64_t type_handle) const;
        int get_type_count() const;
        Array take_impacts();
    };
} // namespace godot
