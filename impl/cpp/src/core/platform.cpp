// Portable parts of the platform layer.
#include "core/platform.h"

#include <chrono>
#include <cstdarg>
#include <cstdlib>
#include <thread>

namespace uni {

void fatal(const char* file, int line, const char* fmt, ...) {
    std::fprintf(stderr, "fatal: %s:%d: ", file, line);
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(stderr, fmt, ap);
    va_end(ap);
    std::fprintf(stderr, "\n");
    std::fflush(stderr);
    std::abort();
}

} // namespace uni

namespace uni::platform {

u64 now_us() {
    using namespace std::chrono;
    return (u64)duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

void sleep_us(u32 us) { std::this_thread::sleep_for(std::chrono::microseconds(us)); }

bool read_file(const std::string& path, std::vector<u8>& out) {
    std::FILE* f = open_file(path, false);
    if (!f) return false;
    out.clear();
    u8 buf[1 << 16];
    for (;;) {
        usize n = std::fread(buf, 1, sizeof buf, f);
        out.insert(out.end(), buf, buf + n);
        if (n < sizeof buf) break;
    }
    bool ok = std::ferror(f) == 0;
    std::fclose(f);
    return ok;
}

bool write_file(const std::string& path, const void* data, usize size) {
    std::FILE* f = open_file(path, true);
    if (!f) return false;
    bool ok = std::fwrite(data, 1, size, f) == size;
    ok = (std::fclose(f) == 0) && ok;
    return ok;
}

} // namespace uni::platform
