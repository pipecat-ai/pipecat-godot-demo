//
// Copyright (c) 2026, Daily
//
// SPDX-License-Identifier: BSD-2-Clause
//

#include "pipecat_client.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_pipecat(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(PipecatFunctionCall);
    GDREGISTER_CLASS(PipecatClient);
}

static void uninitialize_pipecat(ModuleInitializationLevel) {}

extern "C" {

GDExtensionBool GDE_EXPORT pipecat_library_init(
        GDExtensionInterfaceGetProcAddress get_proc_address,
        GDExtensionClassLibraryPtr library,
        GDExtensionInitialization* initialization
) {
    GDExtensionBinding::InitObject init(
            get_proc_address, library, initialization
    );
    init.register_initializer(initialize_pipecat);
    init.register_terminator(uninitialize_pipecat);
    init.set_minimum_library_initialization_level(
            MODULE_INITIALIZATION_LEVEL_SCENE
    );
    return init.init();
}
}
