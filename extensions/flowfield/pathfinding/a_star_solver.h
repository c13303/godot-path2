#pragma once

#include "../core/types.h"

#include <cstddef>
#include <unordered_set>
#include <vector>

namespace ffcore
{
    struct AStarCellHash
    {
        std::size_t operator()(const Vec2i &cell) const noexcept;
    };

    // Godot-independent eight-direction grid solver. This first extracted API
    // deliberately preserves PathfinderNative's existing behavior.
    class AStarSolver
    {
    private:
        std::unordered_set<Vec2i, AStarCellHash> walkable;
        std::unordered_set<Vec2i, AStarCellHash> blockers;

        bool is_open(const Vec2i &cell) const;

    public:
        void set_walkable_cells(const std::vector<Vec2i> &cells);
        void set_blocked_cells(const std::vector<Vec2i> &cells);

        std::vector<Vec2i> find_path(const Vec2i &from_cell, const Vec2i &to_cell) const;

        std::size_t walkable_count() const { return walkable.size(); }
        std::size_t blocker_count() const { return blockers.size(); }
    };
} // namespace ffcore
