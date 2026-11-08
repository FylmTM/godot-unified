// The only OS-specific surface outside net/socket_*.cpp: process init, monotonic time, sleeping and
// UTF-8 file paths. Implemented in platform_posix.cpp / platform_win.cpp (+ portable bits in platform.cpp).
#pragma once

#include <cstdio>
#include <string>
#include <vector>

#include "core/base.h"

namespace uni::platform {

// Winsock startup and 1 ms timer resolution on Windows; nothing elsewhere. Call once from main().
void init();
void shutdown();

// Monotonic clock in microseconds since an arbitrary epoch (steady_clock: QPC on Windows,
// mach_absolute_time on macOS, CLOCK_MONOTONIC on Linux).
u64 now_us();
void sleep_us(u32 us);

// fopen with a UTF-8 path (Windows: converted to UTF-16 for _wfopen). Always binary mode.
std::FILE* open_file(const std::string& utf8_path, bool write);

bool read_file(const std::string& path, std::vector<u8>& out);
bool write_file(const std::string& path, const void* data, usize size);

} // namespace uni::platform
