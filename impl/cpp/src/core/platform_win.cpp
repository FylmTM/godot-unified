// Windows: Winsock startup, 1 ms scheduler resolution, UTF-16 paths.
#include "core/platform.h"

#include <winsock2.h>
#include <windows.h>
#include <timeapi.h>

#include <fcntl.h>
#include <io.h>

namespace uni::platform {

void init() {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) UNI_FATAL("WSAStartup failed");
    // Default Windows sleep granularity is 15.6 ms, far too coarse for a 60 Hz tick loop.
    timeBeginPeriod(1);
    // stdout carries the JSON line; keep it LF-only like on POSIX.
    _setmode(_fileno(stdout), _O_BINARY);
}

void shutdown() {
    timeEndPeriod(1);
    WSACleanup();
}

std::FILE* open_file(const std::string& utf8_path, bool write) {
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8_path.c_str(), -1, nullptr, 0);
    if (n <= 0) return nullptr;
    std::wstring wide((usize)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8_path.c_str(), -1, wide.data(), n);
    return _wfopen(wide.c_str(), write ? L"wb" : L"rb");
}

} // namespace uni::platform
