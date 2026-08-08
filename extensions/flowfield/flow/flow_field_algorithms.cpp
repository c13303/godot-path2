#include "flow_field_algorithms.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>

namespace ffcore
{
    namespace
    {
        struct IntegrationNode
        {
            double cost = 0.0;
            Vec2i cell;

            bool operator>(const IntegrationNode &other) const { return cost > other.cost; }
        };

        constexpr double DIAGONAL_COST = 1.41421356237;
        constexpr float DISTANCE_DIAGONAL_COST = 1.4142f;
        constexpr float UNREACHED_DISTANCE = 1e9f;
    }

    std::size_t CellHash::operator()(const Vec2i &cell) const noexcept
    {
        return (static_cast<std::size_t>(cell.x) * 73856093u) ^
               (static_cast<std::size_t>(cell.y) * 19349663u);
    }

    bool FlowFieldAlgorithms::can_traverse(
        const Vec2i &from_cell,
        const Vec2i &to_cell,
        const CellSet &walkable_cells,
        const DirectionalTraversalConstraints *traversal_constraints)
    {
        if (walkable_cells.count(from_cell) == 0 || walkable_cells.count(to_cell) == 0)
            return false;

        const Vec2i delta(to_cell.x - from_cell.x, to_cell.y - from_cell.y);
        if (std::abs(delta.x) > 1 || std::abs(delta.y) > 1 || (delta.x == 0 && delta.y == 0))
            return false;

        if (traversal_constraints != nullptr)
        {
            const auto constraint = traversal_constraints->find(from_cell);
            if (constraint != traversal_constraints->end() && constraint->second != delta)
                return false;
        }

        if (std::abs(delta.x) + std::abs(delta.y) == 2)
        {
            if (walkable_cells.count({from_cell.x + delta.x, from_cell.y}) == 0 ||
                walkable_cells.count({from_cell.x, from_cell.y + delta.y}) == 0)
                return false;
        }
        return true;
    }

    IntegrationCosts FlowFieldAlgorithms::compute_integration_costs(
        const CellSet &walkable_cells,
        const Vec2i &goal_cell,
        const DirectionalTraversalConstraints *traversal_constraints)
    {
        IntegrationCosts costs;
        costs.reserve(walkable_cells.size());
        for (const Vec2i &cell : walkable_cells)
            costs[cell] = std::numeric_limits<double>::infinity();

        if (walkable_cells.count(goal_cell) == 0)
            return costs;

        const Vec2i directions[8] = {
            {1, 0}, {-1, 0}, {0, 1}, {0, -1},
            {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

        std::priority_queue<IntegrationNode, std::vector<IntegrationNode>, std::greater<IntegrationNode>> open;
        costs[goal_cell] = 0.0;
        open.push({0.0, goal_cell});

        while (!open.empty())
        {
            const IntegrationNode current = open.top();
            open.pop();
            if (current.cost > costs[current.cell])
                continue;

            for (int direction_index = 0; direction_index < 8; ++direction_index)
            {
                const Vec2i direction = directions[direction_index];
                const Vec2i predecessor(
                    current.cell.x + direction.x,
                    current.cell.y + direction.y);
                if (!can_traverse(predecessor, current.cell, walkable_cells, traversal_constraints))
                    continue;

                const double step_cost = direction_index < 4 ? 1.0 : DIAGONAL_COST;
                const double new_cost = current.cost + step_cost;
                if (new_cost < costs[predecessor])
                {
                    costs[predecessor] = new_cost;
                    open.push({new_cost, predecessor});
                }
            }
        }
        return costs;
    }

    std::vector<float> FlowFieldAlgorithms::compute_wall_distance_field(
        int width,
        int height,
        const Vec2i &cell_origin,
        const CellSet &wall_cells)
    {
        if (width <= 0 || height <= 0)
            return {};

        std::vector<float> distances(static_cast<std::size_t>(width * height), 0.0f);
        for (int y = 0; y < height; ++y)
        {
            for (int x = 0; x < width; ++x)
            {
                const Vec2i cell(cell_origin.x + x, cell_origin.y + y);
                distances[y * width + x] = wall_cells.count(cell) != 0 ? 0.0f : UNREACHED_DISTANCE;
            }
        }

        for (int y = 0; y < height; ++y)
        {
            for (int x = 0; x < width; ++x)
            {
                float distance = distances[y * width + x];
                if (distance == 0.0f)
                    continue;
                if (x > 0)
                    distance = std::min(distance, distances[y * width + x - 1] + 1.0f);
                if (y > 0)
                    distance = std::min(distance, distances[(y - 1) * width + x] + 1.0f);
                if (x > 0 && y > 0)
                    distance = std::min(distance, distances[(y - 1) * width + x - 1] + DISTANCE_DIAGONAL_COST);
                distances[y * width + x] = distance;
            }
        }

        for (int y = height - 1; y >= 0; --y)
        {
            for (int x = width - 1; x >= 0; --x)
            {
                float distance = distances[y * width + x];
                if (x + 1 < width)
                    distance = std::min(distance, distances[y * width + x + 1] + 1.0f);
                if (y + 1 < height)
                    distance = std::min(distance, distances[(y + 1) * width + x] + 1.0f);
                if (x + 1 < width && y + 1 < height)
                    distance = std::min(distance, distances[(y + 1) * width + x + 1] + DISTANCE_DIAGONAL_COST);
                distances[y * width + x] = distance;
            }
        }
        return distances;
    }

    std::vector<Vec2> FlowFieldAlgorithms::generate_directions(
        int width,
        int height,
        const Vec2i &cell_origin,
        const CellSet &walkable_cells,
        const IntegrationCosts &integration_costs,
        const std::vector<float> &wall_distances,
        double wall_clearance_weight,
        const DirectionalTraversalConstraints *traversal_constraints)
    {
        if (width <= 0 || height <= 0 ||
            wall_distances.size() != static_cast<std::size_t>(width * height))
            return {};

        std::vector<Vec2> directions(static_cast<std::size_t>(width * height), Vec2());
        const Vec2i neighbor_directions[8] = {
            {1, 0}, {-1, 0}, {0, 1}, {0, -1},
            {1, 1}, {-1, 1}, {1, -1}, {-1, -1}};

        const auto cost_at = [&](const Vec2i &cell) -> double
        {
            const auto cost = integration_costs.find(cell);
            return cost == integration_costs.end() ? std::numeric_limits<double>::infinity() : cost->second;
        };

        for (int y = 0; y < height; ++y)
        {
            for (int x = 0; x < width; ++x)
            {
                const Vec2i cell(cell_origin.x + x, cell_origin.y + y);
                const double cell_cost = cost_at(cell);
                if (walkable_cells.count(cell) == 0 || !std::isfinite(cell_cost))
                    continue;

                Vec2i best_step;
                double best_cost = cell_cost;
                for (const Vec2i &direction : neighbor_directions)
                {
                    const Vec2i neighbor(cell.x + direction.x, cell.y + direction.y);
                    if (!can_traverse(cell, neighbor, walkable_cells, traversal_constraints))
                        continue;
                    const double neighbor_cost = cost_at(neighbor);
                    if (std::isfinite(neighbor_cost) && neighbor_cost < best_cost)
                    {
                        best_cost = neighbor_cost;
                        best_step = direction;
                    }
                }

                if (best_step == Vec2i())
                    continue;

                Vec2 preferred_direction(
                    static_cast<double>(best_step.x),
                    static_cast<double>(best_step.y));
                preferred_direction = preferred_direction.normalized();

                const float cell_distance = wall_distances[y * width + x];
                const auto distance_at = [&](int sample_x, int sample_y) -> float
                {
                    if (sample_x < 0 || sample_y < 0 || sample_x >= width || sample_y >= height)
                        return cell_distance;
                    return wall_distances[sample_y * width + sample_x];
                };

                Vec2 distance_gradient(
                    distance_at(x + 1, y) - distance_at(x - 1, y),
                    distance_at(x, y + 1) - distance_at(x, y - 1));
                if (distance_gradient.length() > 1e-6)
                    distance_gradient = distance_gradient.normalized();

                preferred_direction =
                    (preferred_direction + distance_gradient * wall_clearance_weight).normalized();

                constexpr double QUANTIZATION_DIVISIONS = 16.0;
                constexpr double PI = 3.141592653589793;
                const double angle_step = 2.0 * PI / QUANTIZATION_DIVISIONS;
                double angle = std::atan2(preferred_direction.y, preferred_direction.x);
                angle = std::round(angle / angle_step) * angle_step;
                preferred_direction.x = std::cos(angle);
                preferred_direction.y = std::sin(angle);

                Vec2i final_step;
                double final_cost = std::numeric_limits<double>::infinity();
                double best_score = -1.0;
                constexpr double COST_EPSILON = 1e-9;
                for (const Vec2i &direction : neighbor_directions)
                {
                    const Vec2i neighbor(cell.x + direction.x, cell.y + direction.y);
                    if (!can_traverse(cell, neighbor, walkable_cells, traversal_constraints))
                        continue;
                    const double neighbor_cost = cost_at(neighbor);
                    if (!std::isfinite(neighbor_cost) || neighbor_cost > cell_cost)
                        continue;

                    const double inverse_length =
                        std::abs(direction.x) + std::abs(direction.y) == 2 ? 0.70710678118 : 1.0;
                    const double score =
                        (preferred_direction.x * static_cast<double>(direction.x) +
                         preferred_direction.y * static_cast<double>(direction.y)) *
                        inverse_length;
                    if (neighbor_cost + COST_EPSILON < final_cost)
                    {
                        final_cost = neighbor_cost;
                        best_score = score;
                        final_step = direction;
                    }
                    else if (std::abs(neighbor_cost - final_cost) <= COST_EPSILON && score > best_score)
                    {
                        best_score = score;
                        final_step = direction;
                    }
                }

                if (final_step == Vec2i())
                    final_step = best_step;
                directions[y * width + x] = Vec2(
                    static_cast<double>(final_step.x),
                    static_cast<double>(final_step.y)).normalized();
            }
        }
        return directions;
    }
} // namespace ffcore
