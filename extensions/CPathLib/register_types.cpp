#include "register_types.h"

#include "godot/crowd_world_2d.h"
#include "godot/navigation_route_2d.h"
#include "godot/navigation_world_2d.h"
#include "godot/projectile_world_2d.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_cpathlib_module(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    ClassDB::register_class<NavigationRoute2D>();
    ClassDB::register_class<NavigationWorld2D>();
    ClassDB::register_class<CrowdWorld2D>();
    ClassDB::register_class<ProjectileWorld2D>();
}

void uninitialize_cpathlib_module(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {
GDExtensionBool GDE_EXPORT cpathlib_library_init(
    GDExtensionInterfaceGetProcAddress get_proc_address,
    GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_cpathlib_module);
    init.register_terminator(uninitialize_cpathlib_module);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
}
