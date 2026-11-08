// SlotPool operations (state.h). Deterministic: the free list is LIFO and lives in the block.
#pragma once

#include "game/state.h"

namespace game {

template <int N>
void pool_reset(SlotPool<N>& p) {
    p = SlotPool<N>{};
    p.free_head = NO_SLOT;
}

// Returns the slot index, or -1 when full.
template <int N>
int pool_alloc(SlotPool<N>& p) {
    int slot;
    if (p.free_head != NO_SLOT) {
        slot = p.free_head;
        p.free_head = p.next_free[slot];
    } else if (p.high_water < N) {
        slot = p.high_water++;
    } else {
        return -1;
    }
    p.next_free[slot] = NO_SLOT;
    ++p.count;
    return slot;
}

template <int N>
void pool_free(SlotPool<N>& p, int slot) {
    UNI_ASSERT(p.count > 0);
    p.next_free[slot] = p.free_head;
    p.free_head = (u16)slot;
    --p.count;
}

template <int N>
bool pool_full(const SlotPool<N>& p) {
    return p.count >= N;
}

} // namespace game
