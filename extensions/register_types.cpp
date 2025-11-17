#include "register_types.h"
#include "flowfield/godot/flow_field_native.h"
#include "flowfield/godot/spatial_grid_native.h"
#include "flowfield/godot/steering_system_native.h"
#include "flowfield/godot/agent_manager_native.h"
#include "flowfield/godot/global_config_native.h"

#include "flowfield/agent_manager/agent_manager.h"
#include "flowfield/steering/steering_system.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_flowfield_module(ModuleInitializationLevel p_level)
{
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
        return;

    ClassDB::register_class<FlowFieldNative>();
    ClassDB::register_class<SpatialGridNative>();
    ClassDB::register_class<SteeringSystemNative>();
    ClassDB::register_class<AgentManagerNative>();
    ClassDB::register_class<GlobalConfigNative>();
}

void uninitialize_flowfield_module(ModuleInitializationLevel p_level)
{
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
        return;
}

extern "C"
{
    GDExtensionBool GDE_EXPORT flowfield_library_init(
        GDExtensionInterfaceGetProcAddress p_get_proc_address,
        GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization)
    {
        godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

        init_obj.register_initializer(initialize_flowfield_module);
        init_obj.register_terminator(uninitialize_flowfield_module);
        init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

        return init_obj.init();
    }
}
