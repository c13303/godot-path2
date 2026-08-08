#include "a_star_solver.h"

#include <algorithm>
#include <cmath>
#include <queue>
#include <unordered_map>

namespace ffcore
{
    namespace
    {
        struct AStarNode
        {
            double f = 0.0;
            Vec2i cell;

            bool operator>(const AStarNode &other) const { return f > other.f; }
        };

        constexpr double SQRT2 = 1.41421356237;

        double octile_heuristic(const Vec2i &a, const Vec2i &b)
        {
            const int dx = std::abs(a.x - b.x);
            const int dy = std::abs(a.y - b.y);
            const int diagonal_steps = std::min(dx, dy);
            const int cardinal_steps = std::max(dx, dy);
            return (SQRT2 - 1.0) * static_cast<double>(diagonal_steps) +
                   static_cast<double>(cardinal_steps);
        }
    } // namespace

    std::size_t AStarCellHash::operator()(const Vec2i &cell) const noexcept
    {
        return (static_cast<std::size_t>(cell.x) * 73856093u) ^
               (static_cast<std::size_t>(cell.y) * 19349663u);
    }

    void AStarSolver::set_walkable_cells(const std::vector<Vec2i> &cells)
    {
        walkable.clear();
        walkable.reserve(cells.size());
        walkable.insert(cells.begin(), cells.end());
    }

    void AStarSolver::set_blocked_cells(const std::vector<Vec2i> &cells)
    {
        blockers.clear();
        blockers.reserve(cells.size());
        blockers.insert(cells.begin(), cells.end());
    }

    void AStarSolver::set_traversal_costs(
        const std::vector<Vec2i> &cells,
        const std::vector<double> &costs)
    {
        traversal_costs.clear();
        const std::size_t count = std::min(cells.size(), costs.size());
        for (std::size_t index = 0; index < count; ++index)
        {
            if (std::isfinite(costs[index]) && costs[index] > 0.0)
                traversal_costs[cells[index]] = costs[index];
        }
    }

    bool AStarSolver::is_open(const Vec2i &cell) const
    {
        return walkable.count(cell) != 0 && blockers.count(cell) == 0;
    }

    std::vector<Vec2i> AStarSolver::find_path(const Vec2i &from_cell, const Vec2i &to_cell) const
    {
        return find_path_detailed(from_cell, to_cell).cells;
    }

    AStarPathResult AStarSolver::find_path_detailed(
        const Vec2i &from_cell,
        const Vec2i &to_cell,
        const AStarQueryOptions &options) const
    {
        AStarPathResult result;
        if (!is_open(from_cell) || !is_open(to_cell))
            return result;

        if (from_cell == to_cell)
        {
            result.status = AStarPathStatus::Found;
            result.cells = {from_cell};
            return result;
        }

        const Vec2i directions[8] = {
            {1, 0}, {-1, 0}, {0, 1}, {0, -1},
            {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

        std::priority_queue<AStarNode, std::vector<AStarNode>, std::greater<AStarNode>> open;
        std::unordered_map<Vec2i, double, AStarCellHash> g_score;
        std::unordered_map<Vec2i, Vec2i, AStarCellHash> came_from;

        double minimum_multiplier = 1.0;
        for (const auto &entry : traversal_costs)
            minimum_multiplier = std::min(minimum_multiplier, entry.second);

        g_score[from_cell] = 0.0;
        open.push({octile_heuristic(from_cell, to_cell) * minimum_multiplier, from_cell});

        while (!open.empty())
        {
            const AStarNode current = open.top();
            open.pop();

            ++result.expanded_nodes;
            if (options.maximum_expansions != 0 &&
                result.expanded_nodes > options.maximum_expansions)
            {
                result.status = AStarPathStatus::LimitReached;
                return result;
            }

            if (current.cell == to_cell)
                break;

            const auto current_score = g_score.find(current.cell);
            if (current_score == g_score.end())
                continue;

            for (int direction_index = 0; direction_index < 8; ++direction_index)
            {
                const Vec2i direction = directions[direction_index];
                if (!options.allow_diagonals && direction_index >= 4)
                    continue;
                const auto edge = options.directional_edges.find(current.cell);
                if (edge != options.directional_edges.end() && edge->second != direction)
                    continue;
                const Vec2i neighbor = {
                    current.cell.x + direction.x,
                    current.cell.y + direction.y};
                if (!is_open(neighbor))
                    continue;

                const bool is_diagonal = std::abs(direction.x) + std::abs(direction.y) == 2;
                if (is_diagonal && !options.allow_corner_cutting)
                {
                    const Vec2i horizontal = {current.cell.x + direction.x, current.cell.y};
                    const Vec2i vertical = {current.cell.x, current.cell.y + direction.y};
                    if (!is_open(horizontal) || !is_open(vertical))
                        continue;
                }

                const auto multiplier = traversal_costs.find(neighbor);
                const double cell_multiplier = multiplier == traversal_costs.end() ? 1.0 : multiplier->second;
                const double step_cost = (direction_index < 4 ? 1.0 : SQRT2) * cell_multiplier;
                const double tentative_score = current_score->second + step_cost;
                const auto neighbor_score = g_score.find(neighbor);
                if (neighbor_score == g_score.end() || tentative_score < neighbor_score->second)
                {
                    g_score[neighbor] = tentative_score;
                    came_from[neighbor] = current.cell;
                    open.push({tentative_score + octile_heuristic(neighbor, to_cell) * minimum_multiplier, neighbor});
                }
            }
        }

        if (came_from.count(to_cell) == 0)
        {
            result.status = AStarPathStatus::Unreachable;
            return result;
        }

        std::vector<Vec2i> reversed_path;
        Vec2i cell = to_cell;
        reversed_path.push_back(cell);
        while (cell != from_cell)
        {
            const auto previous = came_from.find(cell);
            if (previous == came_from.end())
            {
                result.status = AStarPathStatus::Unreachable;
                return result;
            }
            cell = previous->second;
            reversed_path.push_back(cell);
        }

        result.cells = std::vector<Vec2i>(reversed_path.rbegin(), reversed_path.rend());
        result.total_cost = g_score.at(to_cell);
        result.status = AStarPathStatus::Found;
        return result;
    }
} // namespace ffcore
