#include "../flow/flow_field_algorithms.h"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace
{
    using ffcore::Vec2i;

    void require(bool condition, const char *message)
    {
        if (!condition)
        {
            std::cerr << "FlowFieldAlgorithms test failed: " << message << '\n';
            std::exit(EXIT_FAILURE);
        }
    }

    bool approximately(double actual, double expected)
    {
        return std::abs(actual - expected) <= 1e-6;
    }

    ffcore::CellSet rectangle(int width, int height, Vec2i origin = Vec2i())
    {
        ffcore::CellSet cells;
        for (int y = 0; y < height; ++y)
        {
            for (int x = 0; x < width; ++x)
                cells.insert({origin.x + x, origin.y + y});
        }
        return cells;
    }

    void test_integration_costs()
    {
        const ffcore::CellSet walkable = rectangle(3, 3);
        const ffcore::IntegrationCosts costs =
            ffcore::FlowFieldAlgorithms::compute_integration_costs(walkable, {2, 2});
        require(approximately(costs.at({2, 2}), 0.0), "goal cost should be zero");
        require(approximately(costs.at({1, 1}), 1.41421356237), "diagonal cost changed");
        require(approximately(costs.at({0, 0}), 2.0 * 1.41421356237), "route integration changed");
    }

    void test_corner_cutting_and_directional_edges()
    {
        ffcore::CellSet diagonal_only = {{0, 0}, {1, 1}};
        const ffcore::IntegrationCosts blocked_diagonal =
            ffcore::FlowFieldAlgorithms::compute_integration_costs(diagonal_only, {1, 1});
        require(std::isinf(blocked_diagonal.at({0, 0})), "integration must forbid corner cutting");

        const ffcore::CellSet corridor = {{0, 0}, {1, 0}, {2, 0}};
        ffcore::DirectionalTraversalConstraints constraints;
        constraints[{1, 0}] = {-1, 0};
        const ffcore::IntegrationCosts directed =
            ffcore::FlowFieldAlgorithms::compute_integration_costs(corridor, {2, 0}, &constraints);
        require(std::isinf(directed.at({0, 0})), "directional source constraint should block the route");
        require(std::isinf(directed.at({1, 0})), "constrained source should not reach the goal");
    }

    void test_missing_goal()
    {
        const ffcore::CellSet walkable = {{0, 0}, {1, 0}};
        const ffcore::IntegrationCosts costs =
            ffcore::FlowFieldAlgorithms::compute_integration_costs(walkable, {2, 0});
        require(costs.size() == walkable.size(), "missing goal should preserve the walkable cost map");
        require(std::isinf(costs.at({0, 0})) && std::isinf(costs.at({1, 0})),
                "missing goal should leave every cell unreachable");
    }

    void test_distance_field_with_nonzero_origin()
    {
        ffcore::CellSet walls = {{11, 21}};
        const std::vector<float> distances =
            ffcore::FlowFieldAlgorithms::compute_wall_distance_field(3, 3, {10, 20}, walls);
        require(distances.size() == 9, "distance field dimensions changed");
        require(approximately(distances[4], 0.0), "wall distance should be zero");
        require(approximately(distances[3], 1.0), "cardinal wall distance should be one");
        require(approximately(distances[0], 1.4142), "legacy diagonal wall distance changed");
        require(approximately(distances[8], 1.4142), "reverse-pass diagonal wall distance changed");
    }
}

int main()
{
    test_integration_costs();
    test_corner_cutting_and_directional_edges();
    test_missing_goal();
    test_distance_field_with_nonzero_origin();
    std::cout << "FlowFieldAlgorithms tests passed\n";
    return EXIT_SUCCESS;
}
