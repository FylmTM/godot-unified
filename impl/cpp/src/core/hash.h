// XXH3-64 (seed 0), streaming. xxhash.h is included only by hash.cpp.
#pragma once

#include "core/base.h"

namespace uni {

class Hasher {
public:
    Hasher();
    ~Hasher();
    Hasher(const Hasher&) = delete;
    Hasher& operator=(const Hasher&) = delete;

    void update(const void* data, usize size);
    u64 digest() const;

private:
    alignas(64) unsigned char state_[640]; // XXH3_state_t, size checked in hash.cpp
};

u64 xxh3_64(const void* data, usize size);

} // namespace uni
