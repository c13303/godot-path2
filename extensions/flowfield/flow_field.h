#ifndef FLOW_FIELD_H
#define FLOW_FIELD_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/binder_common.hpp>

using namespace godot;

class FlowField : public Node {
    GDCLASS(FlowField, Node);

protected:
    static void _bind_methods();

public:
    void _ready() override;
};

#endif
