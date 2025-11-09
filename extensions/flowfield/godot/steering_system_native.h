#pragma once
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include "../steering/steering_system.h"

namespace godot {

class SteeringSystemNative : public Node2D {
    GDCLASS(SteeringSystemNative, Node2D);

protected:
    static void _bind_methods();

public:
    SteeringSystemNative();
    ~SteeringSystemNative();

    void _process(double delta) override;

    void register_agent(Node2D* node, double max_speed);
    void unregister_agent(Node2D* node);
    void set_flowfield(Object* obj);
    void set_grid(Object* obj);

private:
    ffcore::SteeringSystem system;
    std::unordered_map<Node2D*, int> agent_map;

    ffcore::FlowField* flowfield = nullptr;
    ffcore::SpatialGrid* grid = nullptr;
};

} // namespace godot
