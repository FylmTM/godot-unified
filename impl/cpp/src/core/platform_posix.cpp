// macOS and Linux.
#include "core/platform.h"

#include <csignal>

namespace uni::platform {

void init() {
    // A UDP peer that vanished must not kill us with SIGPIPE (sendto on an unconnected socket doesn't
    // raise it, but be explicit).
    std::signal(SIGPIPE, SIG_IGN);
}

void shutdown() {}

std::FILE* open_file(const std::string& utf8_path, bool write) {
    return std::fopen(utf8_path.c_str(), write ? "wb" : "rb");
}

} // namespace uni::platform
