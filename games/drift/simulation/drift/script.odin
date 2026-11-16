// Scripted inputs for the headless modes and test sessions: per slot, a value re-drawn every 16 ticks from a
// hash of (seed, slot, block), so any tick can be asked for in any order. The ships wander, turn toward one
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

// 32 bits from a hash of (seed, slot, block).
scripted_bits :: proc(seed: u64, slot: int, block: u32) -> u32 {
	x := seed * 0x9E3779B97F4A7C15 ~ u64(slot + 1) * 0xBF58476D1CE4E5B9 ~ u64(block + 1) * 0x94D049BB133111EB
	x ~= x >> 31
	x *= 0xD6E8FEB86659FD93
	x ~= x >> 32
	return u32(x)
}

// The scripted input of the player in `slot` for a tick, a pure function of (seed, slot, tick): the input the headless modes,
// the end-to-end suite and a Godot scripted session feed the sim, identical wherever it is asked for.
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State) -> Input {
	bits := scripted_bits(seed, slot, (tick - 1) / SCRIPT_PERIOD)
	input: Input
	if bits % 5 != 4 {
		move := bits % 8
		input.move_x = i8(dmath.DIR8_C[move] * 127)
		input.move_y = i8(dmath.DIR8_S[move] * 127)
	}
	aim := (bits >> 4) % 8
	input.aim = dmath.dir2({dmath.DIR8_C[aim], dmath.DIR8_S[aim]})
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
