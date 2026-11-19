// Scripted inputs for the headless modes and test sessions: per slot, a value re-drawn every
// SCRIPT_PERIOD ticks from a hash of (seed, slot, block), so any tick can be asked for in any order. The
// players wander, jump, look around, grab and drop, and charge and throw: chaos, not play.
package friendslop

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 16

// The aim: a DIR8 direction SCRIPT_AIM_FLAT long, raised by one of SCRIPT_AIM_STEPS whole steps from SCRIPT_AIM_LOW
// (-40 .. 20: from about 22 degrees down to 11 up).
SCRIPT_AIM_FLAT :: 100
SCRIPT_AIM_LOW :: -40
SCRIPT_AIM_STEPS :: 61

// The scripted input hook: what the headless modes and test sessions feed in (a function of seed, slot and
// tick only; `state` may be nil).
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State) -> Input {
	in_block := (tick - 1) % SCRIPT_PERIOD
	hash := sim.script_bits(seed, slot, tick, SCRIPT_PERIOD)
	input: Input
	if hash % 7 != 6 {
		move := hash % 8
		input.move_x = dmath.axis_i8(dmath.DIR8[move].x)
		input.move_z = dmath.axis_i8(dmath.DIR8[move].y)
	}
	flat := dmath.DIR8[(hash >> 4) % 8] * SCRIPT_AIM_FLAT
	input.aim = dmath.dir3({flat.x, f32(SCRIPT_AIM_LOW + int((hash >> 8) % SCRIPT_AIM_STEPS)), flat.y})
	if (hash >> 12) % 4 == 0 do input.buttons += {.Jump}
	if (hash >> 14) % 3 == 0 && in_block < 4 do input.buttons += {.Grab}
	// Throw: held for a whole block, released when the next block doesn't hold it.
	if (hash >> 16) % 3 == 0 do input.buttons += {.Throw}
	return input
}
