// Scripted inputs for the headless modes and test sessions: per slot, a value re-drawn every SCRIPT_PERIOD ticks from
// a hash of (seed, slot, block), so any tick can be asked for in any order. The ships wander, turn toward one
// of 8 directions, fire most of the time and boost now and then. Slot 0 sends `Command_Start` and `Command_Restart` on a
// fixed beat (the sim ignores each outside its phase), so scripted runs play whole matches; commands depend only
// on (seed, slot, tick), so a Godot session's scripted commands match the offline binary's.
package drift

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 16
SCRIPT_COMMAND_EVERY :: 256
SCRIPT_START_AT :: 32 // in each SCRIPT_COMMAND_EVERY ticks
SCRIPT_RESTART_AT :: 160
SCRIPT_IDLE_ONE_IN :: 5 // one block in this many a ship drifts with no thrust
SCRIPT_HOLD_FIRE_ONE_IN :: 4 // and one in this many it holds its fire
SCRIPT_BOOST_ONE_IN :: 6 // and one in this many it boosts

// The scripted input of the player in `slot` for a tick, a pure function of (seed, slot, tick): the input the headless
// modes, the end-to-end suite and a Godot scripted session feed the sim, identical wherever it is asked for.
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State, setup: sim.No_Setup) -> Input {
	bits := sim.script_bits(seed, slot, tick, SCRIPT_PERIOD)
	input: Input
	if bits % SCRIPT_IDLE_ONE_IN != SCRIPT_IDLE_ONE_IN - 1 {
		move := bits % 8
		input.move_x = dmath.axis_i8(dmath.DIR8[move].x)
		input.move_y = dmath.axis_i8(dmath.DIR8[move].y)
	}
	aim := (bits >> 4) % 8
	input.aim = dmath.dir2(dmath.DIR8[aim])
	if (bits >> 8) % SCRIPT_HOLD_FIRE_ONE_IN != 0 do input.buttons += {.Fire}
	if (bits >> 10) % SCRIPT_BOOST_ONE_IN == 0 do input.buttons += {.Boost}
	return input
}

// Sends the slot-0 player's scripted `Command_Start` and `Command_Restart` on a fixed beat, so scripted runs go through whole
// matches and back to the lobby.
scripted_commands :: proc(
	seed: u64,
	slot: int,
	tick: u32,
	state: ^State,
	setup: sim.No_Setup,
	out: ^sim.Command_Out(Command),
) {
	if slot != 0 do return
	switch tick % SCRIPT_COMMAND_EVERY {
	case SCRIPT_START_AT:
		sim.send_command(out, Command_Start{})
	case SCRIPT_RESTART_AT:
		sim.send_command(out, Command_Restart{})
	}
}
