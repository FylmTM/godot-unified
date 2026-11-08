// Per-player per-tick input (4 bytes) and the per-tick input set.
#pragma once

#include "core/base.h"

namespace uni {

constexpr int MAX_PLAYERS = 4;

constexpr u8 BUTTON_DASH = 0x01;
constexpr u8 BUTTON_ABSENT = 0x80;

struct Input {
    i8 move_x = 0; // -127..127
    i8 move_z = 0;
    u8 buttons = 0; // bit 0 dash, bit 7 absent
    u8 choice = 0;  // 0 none, 1..3 level-up option

    bool absent() const { return (buttons & BUTTON_ABSENT) != 0; }
    friend bool operator==(const Input&, const Input&) = default;
};
static_assert(sizeof(Input) == 4);

constexpr Input ABSENT_INPUT{0, 0, BUTTON_ABSENT, 0};

// One tick of official inputs: what the sim consumes, plus the relay's "replaced" bitmask (not seen by the
// game; recorded in the input log).
struct TickInputs {
    Input players[MAX_PLAYERS];
    u8 replaced = 0;

    bool same_inputs(const TickInputs& o) const {
        for (int p = 0; p < MAX_PLAYERS; ++p)
            if (!(players[p] == o.players[p])) return false;
        return true;
    }
};

} // namespace uni
