# unified core, C++ implementation. Driven by build.py (which passes the Box3D paths and the mode);
# usable directly with any CMake >= 3.21 + Ninja + clang/clang-cl.
cmake_minimum_required(VERSION 3.21)
project(unified_cpp LANGUAGES CXX)

set(UNI_MODE "release" CACHE STRING "dev | release | asan | tsan")
set(BOX3D_INCLUDE_DIR "" CACHE PATH "Box3D include directory (tools/box3d.py --json: include_dir)")
set(BOX3D_LIBRARY "" CACHE FILEPATH "Box3D static library (tools/box3d.py --json: lib)")
set(BOX3D_LINK_LIBS "" CACHE STRING "Extra system libraries for Box3D (tools/box3d.py --json: link_libs)")
set(UNI_OUTPUT_DIR "${CMAKE_BINARY_DIR}" CACHE PATH "Where the unified executable goes")

if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
	message(FATAL_ERROR "unified/cpp is built with clang (clang-cl on Windows), got ${CMAKE_CXX_COMPILER_ID}")
endif()
if(NOT BOX3D_INCLUDE_DIR OR NOT BOX3D_LIBRARY)
	message(FATAL_ERROR "BOX3D_INCLUDE_DIR / BOX3D_LIBRARY not set: build with `python impl/cpp/build.py dev|release`")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL") # /MD, same CRT as the Box3D build
# Optimization comes from UNI_MODE below, not from CMake's per-config defaults.
foreach(cfg "" _DEBUG _RELEASE _RELWITHDEBINFO _MINSIZEREL)
	set(CMAKE_CXX_FLAGS${cfg} "")
endforeach()
if(MSVC)
	set(CMAKE_CXX_FLAGS "/EHsc") # the MSVC STL's own headers expect it; our code never throws
endif()

find_package(Threads REQUIRED)

# ---- Box3D (prebuilt by tools/box3d.py, -O2, FP contraction off) ----------------------------------
add_library(box3d STATIC IMPORTED)
set_target_properties(box3d PROPERTIES IMPORTED_LOCATION "${BOX3D_LIBRARY}")
target_include_directories(box3d SYSTEM INTERFACE "${BOX3D_INCLUDE_DIR}")
if(BOX3D_LINK_LIBS)
	target_link_libraries(box3d INTERFACE ${BOX3D_LINK_LIBS})
endif()

# ---- flags shared by all of our targets -----------------------------------------------------------
add_library(uni_flags INTERFACE)
if(MSVC) # clang-cl
	target_compile_options(uni_flags INTERFACE
		/W4 /WX -Wshadow /utf-8 /GR-
		/clang:-ffp-contract=off /clang:-fwrapv /clang:-fno-math-errno)
	target_compile_definitions(uni_flags INTERFACE
		_CRT_SECURE_NO_WARNINGS NOMINMAX WIN32_LEAN_AND_MEAN)
else()
	target_compile_options(uni_flags INTERFACE
		-Wall -Wextra -Wshadow -Werror
		-ffp-contract=off -fwrapv -fno-math-errno -fno-fast-math
		-fno-exceptions -fno-rtti)
endif()

if(UNI_MODE STREQUAL "release")
	set(uni_opt -O2)
	set(uni_checks 0)
elseif(UNI_MODE STREQUAL "dev")
	set(uni_opt -O1 -g)
	set(uni_checks 1)
elseif(UNI_MODE STREQUAL "asan")
	set(uni_opt -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer)
	set(uni_checks 1)
elseif(UNI_MODE STREQUAL "tsan")
	set(uni_opt -O1 -g -fsanitize=thread -fno-omit-frame-pointer)
	set(uni_checks 1)
else()
	message(FATAL_ERROR "unknown UNI_MODE '${UNI_MODE}'")
endif()
if(MSVC)
	list(TRANSFORM uni_opt REPLACE "^-O([0-9])$" "/O\\1")
	list(TRANSFORM uni_opt REPLACE "^-g$" "/Z7")
endif()
target_compile_options(uni_flags INTERFACE ${uni_opt})
target_compile_definitions(uni_flags INTERFACE UNI_CHECKS=${uni_checks})
if(UNI_MODE MATCHES "asan|tsan")
	target_link_options(uni_flags INTERFACE ${uni_opt})
endif()
if(uni_checks)
	# Checked STL access in dev builds (our own Array is checked via UNI_CHECKS).
	if(APPLE)
		target_compile_definitions(uni_flags INTERFACE _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE)
	elseif(NOT MSVC)
		target_compile_definitions(uni_flags INTERFACE _GLIBCXX_ASSERTIONS)
	endif()
endif()

# ---- modules --------------------------------------------------------------------------------------
if(WIN32)
	set(uni_platform_src src/core/platform_win.cpp)
	set(uni_socket_src src/net/socket_win.cpp)
else()
	set(uni_platform_src src/core/platform_posix.cpp)
	set(uni_socket_src src/net/socket_posix.cpp)
endif()

add_library(uni_core STATIC
	src/core/hash.cpp
	src/core/input_log.cpp
	src/core/json.cpp
	src/core/platform.cpp
	${uni_platform_src})
target_include_directories(uni_core PUBLIC src)
target_include_directories(uni_core SYSTEM PRIVATE third_party/xxhash)
target_link_libraries(uni_core PRIVATE uni_flags)
if(WIN32)
	target_link_libraries(uni_core PUBLIC ws2_32 winmm)
endif()

add_library(uni_physics STATIC
	src/physics/physics.cpp
	src/physics/world_state_ext.cpp)
target_link_libraries(uni_physics PUBLIC uni_core box3d PRIVATE uni_flags)

add_library(uni_game STATIC
	src/game/script.cpp
	src/game/systems.cpp
	src/game/world.cpp)
target_link_libraries(uni_game PUBLIC uni_physics PRIVATE uni_flags)

add_library(uni_sim STATIC
	src/sim/sim.cpp)
target_link_libraries(uni_sim PUBLIC uni_game PRIVATE uni_flags)

add_library(uni_net STATIC
	src/net/client.cpp
	src/net/host.cpp
	src/net/loopback.cpp
	src/net/netsim.cpp
	src/net/protocol.cpp
	src/net/relay.cpp
	src/net/session.cpp
	${uni_socket_src})
target_link_libraries(uni_net PUBLIC uni_sim Threads::Threads PRIVATE uni_flags)

add_executable(unified
	src/cli/args.cpp
	src/cli/main.cpp
	src/cli/net_commands.cpp
	src/cli/offline.cpp)
target_link_libraries(unified PRIVATE uni_net uni_flags)
set_target_properties(unified PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${UNI_OUTPUT_DIR}")
foreach(cfg DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
	set_target_properties(unified PROPERTIES RUNTIME_OUTPUT_DIRECTORY_${cfg} "${UNI_OUTPUT_DIR}")
endforeach()
