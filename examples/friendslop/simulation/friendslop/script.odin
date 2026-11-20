// Scripted inputs for the headless modes and test sessions: per slot, a value re-drawn every
// SCRIPT_PERIOD ticks from a hash of (seed, slot, block), so any tick can be asked for in any order. The
// players wander, jump, look around, grab and drop, and charge and throw: chaos, not play.
package friendslop

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 16
SCRIPT_IDLE_ONE_IN :: 7 // one block in this many a player stands still
SCRIPT_JUMP_ONE_IN :: 4 // and one in this many it jumps
SCRIPT_GRAB_ONE_IN :: 3 // grabs at the block's start
SCRIPT_THROW_ONE_IN :: 3 // holds the throw for the block

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
	if hash % SCRIPT_IDLE_ONE_IN != SCRIPT_IDLE_ONE_IN - 1 {
		move := hash % 8
		input.move_x = dmath.axis_i8(dmath.DIR8[move].x)
		input.move_z = dmath.axis_i8(dmath.DIR8[move].y)
	}
	flat := dmath.DIR8[(hash >> 4) % 8] * SCRIPT_AIM_FLAT
	input.aim = dmath.dir3({flat.x, f32(SCRIPT_AIM_LOW + int((hash >> 8) % SCRIPT_AIM_STEPS)), flat.y})
	if (hash >> 12) % SCRIPT_JUMP_ONE_IN == 0 do input.buttons += {.Jump}
	if (hash >> 14) % SCRIPT_GRAB_ONE_IN == 0 && in_block < 4 do input.buttons += {.Grab}
	// Throw: held for a whole block, released when the next block doesn't hold it.
	if (hash >> 16) % SCRIPT_THROW_ONE_IN == 0 do input.buttons += {.Throw}
	return input
}

// The scripted commands: slot 0 takes the team to the route every SCRIPT_TRAVEL_EVERY ticks (at SCRIPT_TRAVEL_AT) and
// back to the hub SCRIPT_TRAVEL_STAY ticks later, so every scripted session, replay and reference run crosses level
// changes (a function of slot and tick only).
scripted_commands :: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out(Command)) {
	if slot != 0 do return
	if tick % SCRIPT_TRAVEL_EVERY == SCRIPT_TRAVEL_AT do sim.send_command(out, Command_Travel{.Route})
	if tick % SCRIPT_TRAVEL_EVERY == SCRIPT_TRAVEL_AT + SCRIPT_TRAVEL_STAY do sim.send_command(out, Command_Travel{.Hub})
}

SCRIPT_TRAVEL_EVERY :: 640
SCRIPT_TRAVEL_AT :: 200
SCRIPT_TRAVEL_STAY :: 320
