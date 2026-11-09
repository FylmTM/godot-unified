// Scripted test inputs (games/survivor/SPEC.md "Scripted inputs"): per player, a value r re-drawn every 24 ticks
// as a hash of (seed, player, block), so any tick can be asked for in any order (netcode clients
// sample ticks as their clock reaches them, tests jump around).
package survivor

import "unified:dmath"

SCRIPT_PERIOD :: 24

script_r :: proc(seed: u64, p: int, t: u32) -> u32 {
	block := u64(t - 1) / SCRIPT_PERIOD
	x := seed * 0x9E3779B97F4A7C15 ~ u64(p + 1) * 0xBF58476D1CE4E5B9 ~ (block + 1) * 0x94D049BB133111EB
	x ~= x >> 31
	x *= 0xD6E8FEB86659FD93
	x ~= x >> 32
	return u32(x)
}

// Input of player p for tick t (t >= 1). `pending` is the player's pending level-up count in the
// caller's current state.
script_input :: proc(seed: u64, p: int, t: u32, pending: i32) -> Input {
	r := script_r(seed, p, t)
	in_: Input
	if r % 9 != 8 {
		k := r % 8
		in_.move_x = i8(dmath.DIR8_C[k] * 127)
		in_.move_z = i8(dmath.DIR8_S[k] * 127)
	}
	if r % 13 == 0 {
		in_.buttons |= BUTTON_DASH
	}
	if pending > 0 {
		// One pick per 24-tick block: the block number is the press sequence.
		in_.choice = choice_encode(int(r % 3) + 1, u8((t - 1) / SCRIPT_PERIOD % 63) + 1)
	}
	return in_
}

// The scripted input hook: what the headless modes and test sessions feed in.
script :: proc(seed: u64, p: int, t: u32, s: ^State) -> Input {
	return script_input(seed, p, t, s != nil ? s.players[p].pending_levelups : 0)
}
