#include "spatial_grid.h"
#include <iostream>
using namespace ffcore;

int main() {
    SpatialGrid grid(10.0);
    grid.insert(1, Vec2(5,5));
    grid.insert(2, Vec2(14,5));
    grid.insert(3, Vec2(50,50));

    auto n1 = grid.query_neighbors(Vec2(5,5), 15.0);
    std::cout << "Neighbors near (5,5): ";
    for(int id : n1) std::cout << id << " ";
    std::cout << std::endl;

    grid.update(2, Vec2(14,5), Vec2(50,50));
    auto n2 = grid.query_neighbors(Vec2(5,5), 15.0);
    std::cout << "After moving 2: ";
    for(int id : n2) std::cout << id << " ";
    std::cout << std::endl;

    return 0;
}
