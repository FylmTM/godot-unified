#include "core/hash.h"

#include <new>

#define XXH_INLINE_ALL
#define XXH_STATIC_LINKING_ONLY
#include "xxhash.h"

namespace uni {

static_assert(sizeof(XXH3_state_t) <= 640, "grow Hasher::state_");
static_assert(alignof(XXH3_state_t) <= 64);

static XXH3_state_t* st(unsigned char* p) { return std::launder(reinterpret_cast<XXH3_state_t*>(p)); }
static const XXH3_state_t* st(const unsigned char* p) {
    return std::launder(reinterpret_cast<const XXH3_state_t*>(p));
}

Hasher::Hasher() {
    new (state_) XXH3_state_t;
    XXH3_INITSTATE(st(state_));
    XXH3_64bits_reset_withSeed(st(state_), 0);
}

Hasher::~Hasher() = default;

void Hasher::update(const void* data, usize size) { XXH3_64bits_update(st(state_), data, size); }

u64 Hasher::digest() const { return XXH3_64bits_digest(st(state_)); }

u64 xxh3_64(const void* data, usize size) { return XXH3_64bits_withSeed(data, size, 0); }

} // namespace uni
