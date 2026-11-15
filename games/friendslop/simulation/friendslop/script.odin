// Scripted inputs for the headless modes and test sessions: per slot, a value re-drawn every
// 16 ticks from a hash of (seed, slot, block), so any tick can be asked for in any order. The
// players wander, jump, look around, grab and drop, and charge and throw: chaos, not play.
package friendslop

import "unified:dmath"

SCRIPT_PERIOD :: 16

// 32 bits from a hash of (seed, slot, block): the draw each scripted input block is made from.
scripted_hash :: proc(seed: u64, slot: int, block: u32) -> u32 {
	x := seed * 0x9E3779B97F4A7C15 ~ u64(slot + 1) * 0xBF58476D1CE4E5B9 ~ u64(block + 1) * 0x94D049BB133111EB
	x ~= x >> 31
	x *= 0xD6E8FEB86659FD93
	x ~= x >> 32
	return u32(x)
}

// The scripted input hook: what the headless modes and test sessions feed in (a function of seed, slot and
// tick only; `state` may be nil).
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State) -> Input {
	block := (tick - 1) / SCRIPT_PERIOD
	in_block := (tick - 1) % SCRIPT_PERIOD
	hash := scripted_hash(seed, slot, block)
	input: Input
	if hash % 7 != 6 {
		move := hash % 8
		input.move_x = i8(dmath.DIR8_C[move] * 127)
		input.move_z = i8(dmath.DIR8_S[move] * 127)
	}
	aim := (hash >> 4) % 8
	input.aim_x = i8(dmath.DIR8_C[aim] * 100)
	input.aim_z = i8(dmath.DIR8_S[aim] * 100)
	input.aim_y = i8(int((hash >> 8) % 61) - 40)
	if (hash >> 12) % 4 == 0 do input.buttons |= BUTTON_JUMP
	if (hash >> 14) % 3 == 0 && in_block < 4 do input.buttons |= BUTTON_GRAB
	// Throw: held for a whole block, released when the next block doesn't hold it.
	if (hash >> 16) % 3 == 0 do input.buttons |= BUTTON_THROW
	return input
}
