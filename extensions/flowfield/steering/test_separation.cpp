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

    int id1 = system.register_agent(Vec2(0,0), 5.0);
    int id2 = system.register_agent(Vec2(0.3,0.3), 5.0);

    for(int i=0;i<5;i++){
        system.update_all(0.1);
        const AgentData* a1 = system.get_agent(id1);
        const AgentData* a2 = system.get_agent(id2);
        std::cout << "Step " << i
                  << "  A1=(" << a1->position.x << "," << a1->position.y << ")"
                  << "  A2=(" << a2->position.x << "," << a2->position.y << ")\n";
    }
}
