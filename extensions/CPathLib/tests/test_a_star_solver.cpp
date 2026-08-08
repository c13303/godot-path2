#include "../pathfinding/a_star_solver.h"

#include <cstdlib>
#include <iostream>
#include <vector>

namespace
{
    using ffcore::Vec2i;

    void require(bool condition, const char *message)
    {
        if (!condition)
        {
            std::cerr << "AStarSolver test failed: " << message << '\n';
            std::exit(EXIT_FAILURE);
        }
    }

    std::vector<Vec2i> rectangle(int width, int height)
    {
        std::vector<Vec2i> cells;
        for (int y = 0; y < height; ++y)
        {
            for (int x = 0; x < width; ++x)
                cells.push_back({x, y});
        }
        return cells;
    }

    void test_open_diagonal_path()
    {
        ffcore::AStarSolver solver;
        solver.set_walkable_cells(rectangle(3, 3));
        const std::vector<Vec2i> path = solver.find_path({0, 0}, {2, 2});
        require(path.size() == 3, "open diagonal path should contain three cells");
        require(path.front() == Vec2i(0, 0), "path should include its start cell");
        require(path[1] == Vec2i(1, 1), "open grid should use the diagonal");
        require(path.back() == Vec2i(2, 2), "path should include its goal cell");
    }

    void test_no_corner_cutting()
    {
        ffcore::AStarSolver solver;
        solver.set_walkable_cells({{0, 0}, {1, 1}});
        require(solver.find_path({0, 0}, {1, 1}).empty(),
                "diagonal movement must not cross two closed cardinal neighbors");
    }

    void test_blockers_and_replacement()
    {
        ffcore::AStarSolver solver;
        solver.set_walkable_cells(rectangle(3, 1));
        solver.set_blocked_cells({{1, 0}, {1, 0}});
        require(solver.blocker_count() == 1, "duplicate blockers should be deduplicated");
        require(solver.find_path({0, 0}, {2, 0}).empty(), "blocker should make corridor unreachable");
        solver.set_blocked_cells({});
        require(solver.find_path({0, 0}, {2, 0}).size() == 3,
                "replacing blockers should reopen the corridor");
    }

    void test_invalid_and_identical_endpoints()
    {
        ffcore::AStarSolver solver;
        solver.set_walkable_cells({{-2, 4}});
        require(solver.find_path({0, 0}, {-2, 4}).empty(),
                "non-walkable start should return an empty path");
        const std::vector<Vec2i> path = solver.find_path({-2, 4}, {-2, 4});
        require(path.size() == 1 && path[0] == Vec2i(-2, 4),
                "identical open endpoints should return one cell");
    }

    void test_weighted_and_bounded_queries()
    {
        ffcore::AStarSolver solver;
        solver.set_walkable_cells(rectangle(3, 2));
        solver.set_traversal_costs({{1, 0}}, {20.0});
        const ffcore::AStarPathResult weighted = solver.find_path_detailed({0, 0}, {2, 0});
        require(weighted.status == ffcore::AStarPathStatus::Found,
                "weighted path query should succeed");
        require(weighted.cells.size() >= 3 && weighted.cells[1] != Vec2i(1, 0),
                "weighted path should avoid an expensive cell");
        require(weighted.total_cost < 20.0,
                "weighted result should expose the selected route cost");

        ffcore::AStarQueryOptions cardinal_only;
        cardinal_only.allow_diagonals = false;
        const ffcore::AStarPathResult cardinal = solver.find_path_detailed(
            {0, 0}, {2, 1}, cardinal_only);
        require(cardinal.status == ffcore::AStarPathStatus::Found && cardinal.cells.size() >= 4,
                "cardinal-only option should disable diagonal steps");

        ffcore::AStarQueryOptions bounded;
        bounded.maximum_expansions = 1;
        require(solver.find_path_detailed({0, 0}, {2, 1}, bounded).status ==
                    ffcore::AStarPathStatus::LimitReached,
                "query expansion limit should return an explicit status");
    }
}

int main()
{
    test_open_diagonal_path();
    test_no_corner_cutting();
    test_blockers_and_replacement();
    test_invalid_and_identical_endpoints();
    test_weighted_and_bounded_queries();
    std::cout << "AStarSolver tests passed\n";
    return EXIT_SUCCESS;
}
