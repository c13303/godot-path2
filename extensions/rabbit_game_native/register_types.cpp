#include "register_types.h"

#include "agent_manager/agent_manager.h"
#include "godot/agent_manager_native.h"
#include "godot/flow_field_native.h"
#include "godot/global_config_native.h"
#include "godot/projectile_system_native.h"
#include "godot/spatial_grid_native.h"
#include "godot/steering_system_native.h"
#include "steering/steering_system.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_rabbit_game_native_module(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    ClassDB::register_class<FlowFieldNative>();
    ClassDB::register_class<SpatialGridNative>();
    ClassDB::register_class<SteeringSystemNative>();
    ClassDB::register_class<AgentManagerNative>();
    ClassDB::register_class<GlobalConfigNative>();
    ClassDB::register_class<ProjectileSystemNative>();
}

void uninitialize_rabbit_game_native_module(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {
GDExtensionBool GDE_EXPORT rabbit_game_native_library_init(
    GDExtensionInterfaceGetProcAddress get_proc_address,
    GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_rabbit_game_native_module);
    init.register_terminator(uninitialize_rabbit_game_native_module);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
}
