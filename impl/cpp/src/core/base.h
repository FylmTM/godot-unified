// Fixed-width types, assertions and a bounds-checked fixed array. Every module includes this.
#pragma once

#include <cstddef>
#include <cstdint>

using u8 = std::uint8_t;
using u16 = std::uint16_t;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using i8 = std::int8_t;
using i16 = std::int16_t;
using i32 = std::int32_t;
using i64 = std::int64_t;
using f32 = float;
using usize = std::size_t;

static_assert(sizeof(f32) == 4);

namespace uni {

[[noreturn]] void fatal(const char* file, int line, const char* fmt, ...)
#if defined(__clang__) || defined(__GNUC__)
    __attribute__((format(printf, 3, 4)))
#endif
    ;

} // namespace uni

// Always-on check: invariants whose failure would silently corrupt a run (protocol, file formats).
#define UNI_CHECK(cond, ...)                                                                                          \
    do {                                                                                                              \
        if (!(cond)) ::uni::fatal(__FILE__, __LINE__, __VA_ARGS__);                                                  \
    } while (0)

#define UNI_FATAL(...) ::uni::fatal(__FILE__, __LINE__, __VA_ARGS__)

// Dev-only check (UNI_CHECKS=1 in dev and sanitizer builds): bounds and internal consistency.
#if UNI_CHECKS
#define UNI_ASSERT(cond) UNI_CHECK(cond, "assertion failed: %s", #cond)
#define UNI_BOUNDS(i, n)                                                                                              \
    UNI_CHECK((usize)(i) < (usize)(n), "index %lld out of bounds [0, %lld)", (long long)(i), (long long)(n))
#else
#define UNI_ASSERT(cond) ((void)0)
#define UNI_BOUNDS(i, n) ((void)0)
#endif

namespace uni {

// A fixed-capacity array that lives inline in the state block. operator[] is bounds-checked in dev builds.
// It's an aggregate with no raw C array exposed, so the POD checker (pod_check.h) can recurse into it.
template <class T, int N>
struct Array {
    static_assert(N > 0);
    T items[N];

    static constexpr int size() { return N; }
    T& operator[](int i) {
        UNI_BOUNDS(i, N);
        return items[i];
    }
    const T& operator[](int i) const {
        UNI_BOUNDS(i, N);
        return items[i];
    }
    T* begin() { return items; }
    T* end() { return items + N; }
    const T* begin() const { return items; }
    const T* end() const { return items + N; }
};

// A non-owning view over contiguous bytes, bounds-checked in dev builds.
struct Bytes {
    const u8* data = nullptr;
    usize size = 0;
};

} // namespace uni
