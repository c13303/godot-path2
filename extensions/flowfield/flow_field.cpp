#include "flow_field.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void FlowField::_bind_methods() {}

void FlowField::_ready() {
    UtilityFunctions::print("FlowField system initialized (C++)");
}
