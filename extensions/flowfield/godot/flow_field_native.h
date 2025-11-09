#ifndef FLOW_FIELD_NATIVE_H
#define FLOW_FIELD_NATIVE_H

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include "../flow/flow_field.h"

namespace godot {

class FlowFieldNative : public Node2D {
    GDCLASS(FlowFieldNative, Node2D);

public:
    ffcore::FlowField field;

    static void _bind_methods() {}
};

}

#endif
