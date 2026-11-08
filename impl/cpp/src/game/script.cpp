#include "game/game.h"
#include "game/tables.h"

namespace game {

Script::Script(u64 seed, int player) {
    u32 s = (u32)(seed * 7919u + (u64)player + 1u);
    seed_state_ = s == 0 ? 1u : s;
    rng_ = seed_state_;
}

uni::Input Script::input(u32 tick, bool levelup_pending) {
    UNI_ASSERT(tick >= 1);
    i64 draw = (i64)((tick - 1u) / 24u);
    if (draw < draw_) { // rewind
        rng_ = seed_state_;
        draw_ = -1;
    }
    while (draw_ < draw) {
        r_ = xorshift32(rng_);
        ++draw_;
    }
    uni::Input in;
    u32 d = r_ % 9u;
    if (d != 8u) {
        in.move_x = (i8)(RING_C[d] * 127.0f);
        in.move_z = (i8)(RING_S[d] * 127.0f);
    }
    if (r_ % 13u == 0u) in.buttons = uni::BUTTON_DASH;
    in.choice = levelup_pending ? (u8)(r_ % 3u + 1u) : (u8)0;
    return in;
}

} // namespace game
