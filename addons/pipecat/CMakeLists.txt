#
# Copyright (c) 2026, Daily
#
# SPDX-License-Identifier: BSD-2-Clause
#
# Builds the Pipecat GDExtension into bin/, with godot-cpp and the Pipecat C++
# client and its WebSocket transport, which it downloads. From the project's
# directory:
#
#   cmake -S addons/pipecat -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build build
#
# To build with your own copy of the Pipecat C++ client, add
# -DFETCHCONTENT_SOURCE_DIR_PIPECAT=/path/to/pipecat-client-cxx.

cmake_minimum_required(VERSION 3.17)
project(pipecat_godot LANGUAGES CXX)

include(FetchContent)

# The Godot version it needs, at least.
set(GODOTCPP_API_VERSION 4.7 CACHE STRING "")
# The Pipecat client throws exceptions, so they're on.
set(GODOTCPP_DISABLE_EXCEPTIONS OFF CACHE BOOL "")
FetchContent_Declare(godot-cpp
  GIT_REPOSITORY https://github.com/godotengine/godot-cpp.git
  GIT_TAG 10.0.0-stable
  GIT_SHALLOW TRUE
)

set(PIPECAT_BUILD_WEBSOCKET ON CACHE BOOL "")
set(PIPECAT_INSTALL OFF CACHE BOOL "")
FetchContent_Declare(pipecat
  GIT_REPOSITORY https://github.com/pipecat-ai/pipecat-client-cxx.git
  GIT_TAG v1.2.0
  GIT_SHALLOW TRUE
)

# Everything goes into a shared library.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
FetchContent_MakeAvailable(godot-cpp pipecat)

add_library(pipecat_godot SHARED
  src/pipecat_client.cpp
  src/register_types.cpp
)
target_compile_features(pipecat_godot PRIVATE cxx_std_17)
target_link_libraries(pipecat_godot PRIVATE
  godot::cpp
  pipecat::pipecat
  pipecat::websocket
)

# E.g. libpipecat.linux.template_debug.x86_64.so, as pipecat.gdextension
# expects.
get_target_property(GODOTCPP_SUFFIX godot::cpp GODOTCPP_SUFFIX)
set_target_properties(pipecat_godot PROPERTIES
  PREFIX "lib"
  OUTPUT_NAME "pipecat${GODOTCPP_SUFFIX}"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin"
)

# So Godot doesn't import what's in the build directory.
file(WRITE "${CMAKE_BINARY_DIR}/.gdignore" "")
