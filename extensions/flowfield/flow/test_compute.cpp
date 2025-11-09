#include "flow_field.h"
#include <iostream>
using namespace ffcore;

int main() {
    FlowField f(5,5,1.0);
    std::vector<Vec2i> walk;
    for(int y=0;y<5;y++)
        for(int x=0;x<5;x++)
            walk.push_back(Vec2i(x,y));
    f.compute(Vec2i(2,2), walk, true);
    for(int y=0;y<5;y++){
        for(int x=0;x<5;x++){
            Vec2 d = f.sample_dir_cell(x,y);
            std::cout<<"("<<d.x<<","<<d.y<<") ";
        }
        std::cout<<"\n";
    }
}
