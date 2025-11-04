#include "flow_field.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void FlowField::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_allow_diagonals", "allow"), &FlowField::set_allow_diagonals);
    ClassDB::bind_method(D_METHOD("get_allow_diagonals"), &FlowField::get_allow_diagonals);
    ClassDB::add_property(FlowField::get_class_static(), PropertyInfo(Variant::BOOL, "allow_diagonals"), "set_allow_diagonals", "get_allow_diagonals");
}

FlowField::FlowField()
{
}

FlowField::~FlowField()
{
}

void FlowField::_ready()
{
    UtilityFunctions::print("FlowField minimal OK!");
}