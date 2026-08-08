#pragma once

#include "a_star_solver.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace godot
{
    // Generic tile-grid A* pathfinder. No gameplay concepts (no "plant", no "room").
    // Caller provides the universe of walkable tiles + optional blockers, then queries paths.
    class PathfinderNative : public Node
    {
        GDCLASS(PathfinderNative, Node);

    private:
        ffcore::AStarSolver solver;

    protected:
        static void _bind_methods();

    public:
        PathfinderNative() = default;
        ~PathfinderNative() override = default;

        void set_walkable_tiles(const PackedVector2Array &cells);
        void set_blockers(const PackedVector2Array &cells);
        PackedVector2Array find_path(const Vector2i &from_tile, const Vector2i &to_tile) const;
        int walkable_count() const { return static_cast<int>(solver.walkable_count()); }
        int blocker_count() const { return static_cast<int>(solver.blocker_count()); }
    };
} // namespace godot
