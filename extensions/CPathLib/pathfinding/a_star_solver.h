#pragma once

#include "../core/types.h"

#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace ffcore
{
    struct AStarCellHash
    {
        std::size_t operator()(const Vec2i &cell) const noexcept;
    };

    enum class AStarPathStatus
    {
        Found,
        Unreachable,
        InvalidInput,
        LimitReached
    };

    struct AStarQueryOptions
    {
        bool allow_diagonals = true;
        bool allow_corner_cutting = false;
        std::uint32_t maximum_expansions = 0;
        std::unordered_map<Vec2i, Vec2i, AStarCellHash> directional_edges;
    };

    struct AStarPathResult
    {
        AStarPathStatus status = AStarPathStatus::InvalidInput;
        std::vector<Vec2i> cells;
        double total_cost = 0.0;
        std::uint32_t expanded_nodes = 0;
    };

    // Godot-independent eight-direction grid solver.
    class AStarSolver
    {
    private:
        std::unordered_set<Vec2i, AStarCellHash> walkable;
        std::unordered_set<Vec2i, AStarCellHash> blockers;
        std::unordered_map<Vec2i, double, AStarCellHash> traversal_costs;

        bool is_open(const Vec2i &cell) const;

    public:
        void set_walkable_cells(const std::vector<Vec2i> &cells);
        void set_blocked_cells(const std::vector<Vec2i> &cells);
        void set_traversal_costs(const std::vector<Vec2i> &cells,
                                 const std::vector<double> &costs);

        std::vector<Vec2i> find_path(const Vec2i &from_cell, const Vec2i &to_cell) const;
        AStarPathResult find_path_detailed(const Vec2i &from_cell, const Vec2i &to_cell,
                                           const AStarQueryOptions &options = {}) const;

        std::size_t walkable_count() const { return walkable.size(); }
        std::size_t blocker_count() const { return blockers.size(); }
    };
} // namespace ffcore
