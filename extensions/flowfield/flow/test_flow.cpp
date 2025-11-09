#include "flow_field.h"
#include <iostream>
using namespace ffcore;

int main() {
    FlowField f(3, 3, 10.0);
    f.set_dir(1, 1, Vec2(0, 1));
    Vec2 wpos(15, 15);
    Vec2 d = f.sample_dir_world(wpos);
    std::cout << "dir=" << d.x << "," << d.y << std::endl;
    return 0;
}
