#include "register_types.h"
#include "flow_field.h"
#include "steering_system_native.h"
#include "spatial_grid_native.h"


#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_flowfield_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
        return;

    // Enregistrement des classes natives
    ClassDB::register_class<FlowField>();
    ClassDB::register_class<SteeringSystemNative>();
    ClassDB::register_class<SpatialGridNative>();

}

void uninitialize_flowfield_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
        return;
}

extern "C" {
GDExtensionBool GDE_EXPORT flowfield_library_init(
    GDExtensionInterfaceGetProcAddress p_get_proc_address,
    GDExtensionClassLibraryPtr p_library,
    GDExtensionInitialization *r_initialization
) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_flowfield_module);
    init_obj.register_terminator(uninitialize_flowfield_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}
}
