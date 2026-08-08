#include "area_builder.h"

#include <algorithm>
#include <deque>
#include <unordered_set>

namespace ffcore
{
    namespace
    {
        const Vec2i CARDINALS[] = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}};

        bool cell_less(const Vec2i &left, const Vec2i &right)
        {
            return left.y != right.y ? left.y < right.y : left.x < right.x;
        }

        AreaBuildResult finalize(const CellSet &cells)
        {
            AreaBuildResult result;
            result.interior_cells.assign(cells.begin(), cells.end());
            for (const Vec2i &cell : result.interior_cells)
            {
                bool boundary = false;
                for (const Vec2i &direction : CARDINALS)
                {
                    if (cells.find({cell.x + direction.x, cell.y + direction.y}) == cells.end())
                    {
                        boundary = true;
                        break;
                    }
                }
                if (boundary)
                    result.boundary_cells.push_back(cell);
            }
            std::sort(result.interior_cells.begin(), result.interior_cells.end(), cell_less);
            std::sort(result.boundary_cells.begin(), result.boundary_cells.end(), cell_less);
            return result;
        }
    }

    AreaBuildResult AreaBuilder::from_explicit_cells(const std::vector<Vec2i> &cells)
    {
        return finalize({cells.begin(), cells.end()});
    }

    AreaBuildResult AreaBuilder::from_seed(
        const Vec2i &seed,
        const CellSet &allowed_cells,
        std::size_t maximum_cells)
    {
        if (allowed_cells.find(seed) == allowed_cells.end())
            return {};

        CellSet visited;
        std::deque<Vec2i> pending;
        visited.insert(seed);
        pending.push_back(seed);
        while (!pending.empty() && (maximum_cells == 0 || visited.size() < maximum_cells))
        {
            const Vec2i current = pending.front();
            pending.pop_front();
            for (const Vec2i &direction : CARDINALS)
            {
                const Vec2i next{current.x + direction.x, current.y + direction.y};
                if (allowed_cells.find(next) == allowed_cells.end() || visited.find(next) != visited.end())
                    continue;
                visited.insert(next);
                pending.push_back(next);
                if (maximum_cells != 0 && visited.size() >= maximum_cells)
                    break;
            }
        }
        return finalize(visited);
    }
} // namespace ffcore
