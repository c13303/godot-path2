#include "types.h"
#include <iostream>
using namespace ffcore;

int main() {
    Vec2 a(3, 4);
    Vec2 b(1, 2);
    Vec2 c = a + b;
    std::cout << c.x << "," << c.y << " len=" << c.length() << std::endl;
    return 0;
}
