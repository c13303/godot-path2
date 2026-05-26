#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <unordered_set>

namespace godot
{
    struct PFVec2iHash
    {
        size_t operator()(const Vector2i &v) const noexcept
        {
            return (size_t(v.x) * 73856093u) ^ (size_t(v.y) * 19349663u);
        }
    };

    // Generic tile-grid A* pathfinder. No gameplay concepts (no "plant", no "room").
    // Caller provides the universe of walkable tiles + optional blockers, then queries paths.
    class PathfinderNative : public Node
    {
        GDCLASS(PathfinderNative, Node);

    private:
        std::unordered_set<Vector2i, PFVec2iHash> walkable;
        std::unordered_set<Vector2i, PFVec2iHash> blockers;

        bool is_open(const Vector2i &cell) const;

    protected:
        static void _bind_methods();

    public:
        PathfinderNative() = default;
        ~PathfinderNative() override = default;

        void set_walkable_tiles(const PackedVector2Array &cells);
        void set_blockers(const PackedVector2Array &cells);
        PackedVector2Array find_path(const Vector2i &from_tile, const Vector2i &to_tile) const;
        int walkable_count() const { return (int)walkable.size(); }
        int blocker_count() const { return (int)blockers.size(); }
    };
} // namespace godot
