// Scripted inputs for the headless modes and test sessions: per player, a value re-drawn every
// 16 ticks from a hash of (seed, player, block), so any tick can be asked for in any order. The
// players wander, jump, look around, grab and drop, and charge and throw: chaos, not play.
package friendslop

import "unified:dmath"

SCRIPT_PERIOD :: 16

script_r :: proc(seed: u64, p: int, block: u32) -> u32 {
	x := seed * 0x9E3779B97F4A7C15 ~ u64(p + 1) * 0xBF58476D1CE4E5B9 ~ u64(block + 1) * 0x94D049BB133111EB
	x ~= x >> 31
	x *= 0xD6E8FEB86659FD93
	x ~= x >> 32
	return u32(x)
}

script_input :: proc(seed: u64, p: int, t: u32) -> Input {
	block := (t - 1) / SCRIPT_PERIOD
	in_block := (t - 1) % SCRIPT_PERIOD
	r := script_r(seed, p, block)
	in_: Input
	if r % 7 != 6 {
		k := r % 8
		in_.move_x = i8(dmath.DIR8_C[k] * 127)
		in_.move_z = i8(dmath.DIR8_S[k] * 127)
	}
	a := (r >> 4) % 8
	in_.aim_x = i8(dmath.DIR8_C[a] * 100)
	in_.aim_z = i8(dmath.DIR8_S[a] * 100)
	in_.aim_y = i8(int((r >> 8) % 61) - 40)
	if (r >> 12) % 4 == 0 do in_.buttons |= BUTTON_JUMP
	if (r >> 14) % 3 == 0 && in_block < 4 do in_.buttons |= BUTTON_GRAB
	// Throw: held for a whole block, released when the next block doesn't hold it.
	if (r >> 16) % 3 == 0 do in_.buttons |= BUTTON_THROW
	return in_
}

// The scripted input hook: what the headless modes and test sessions feed in.
script :: proc(seed: u64, p: int, t: u32, s: ^State) -> Input {
	return script_input(seed, p, t)
}
