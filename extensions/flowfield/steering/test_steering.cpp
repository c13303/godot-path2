#include "steering_system.h"
#include <iostream>
using namespace ffcore;

int main() {
    FlowField field(5,5,1.0);
    std::vector<Vec2i> walk;
    for(int y=0;y<5;y++)
        for(int x=0;x<5;x++)
            walk.push_back(Vec2i(x,y));
    field.compute(Vec2i(2,2), walk, true);

    SpatialGrid grid(1.0);
    SteeringSystem system;
    system.set_flowfield(&field);
    system.set_grid(&grid);

    int id = system.register_agent(Vec2(0,0), 5.0);
    for(int i=0;i<5;i++){
        system.update_all(0.1);
        const AgentData* a = system.get_agent(id);
        std::cout << "Step " << i << ": pos=(" << a->position.x << "," << a->position.y << ")\n";
    }
}
