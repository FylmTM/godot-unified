// Scripted inputs for the headless modes and test sessions: per slot, a value re-drawn every SCRIPT_PERIOD ticks from
// a hash of (seed, slot, block), so any tick can be asked for in any order. The ships wander, turn toward one
// of 8 directions, fire most of the time and boost now and then. Slot 0 sends `start` and `restart` on a
// fixed beat (the sim ignores each outside its phase), so scripted runs play whole matches; commands depend only
// on (seed, slot, tick), so a Godot session's scripted commands match the offline binary's.
package drift

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 16
SCRIPT_COMMAND_EVERY :: 256
SCRIPT_START_AT :: 32 // in each SCRIPT_COMMAND_EVERY ticks
SCRIPT_RESTART_AT :: 160


// The scripted input of the player in `slot` for a tick, a pure function of (seed, slot, tick): the input the headless modes,
// the end-to-end suite and a Godot scripted session feed the sim, identical wherever it is asked for.
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State) -> Input {
	bits := sim.script_bits(seed, slot, tick, SCRIPT_PERIOD)
	input: Input
	if bits % 5 != 4 {
		move := bits % 8
		input.move_x = dmath.axis_i8(dmath.DIR8[move].x)
		input.move_y = dmath.axis_i8(dmath.DIR8[move].y)
	}
	aim := (bits >> 4) % 8
	input.aim = dmath.dir2(dmath.DIR8[aim])
	if (bits >> 8) % 4 != 0 do input.buttons += {.Fire}
	if (bits >> 10) % 6 == 0 do input.buttons += {.Boost}
	return input
}

// Sends the slot-0 player's scripted `start` and `restart` on a fixed beat, so scripted runs go through whole matches and
// back to the lobby.
scripted_commands :: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out(Cmd)) {
	if slot != 0 do return
	switch tick % SCRIPT_COMMAND_EVERY {
	case SCRIPT_START_AT:
		sim.send_command(out, Cmd_Start{})
	case SCRIPT_RESTART_AT:
		sim.send_command(out, Cmd_Restart{})
	}
}
