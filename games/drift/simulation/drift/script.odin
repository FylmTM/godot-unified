// Scripted inputs for the headless modes and test sessions: per player, a value re-drawn every 16 ticks from a
// hash of (seed, player, block), so any tick can be asked for in any order. The ships wander, turn toward one
// of 8 directions, fire most of the time and boost now and then. Player 0 sends `start` and `restart` on a
// fixed beat (the sim ignores each outside its phase), so scripted runs play whole matches; commands depend only
// on (seed, player, tick), so a Godot session's scripted commands match the offline binary's.
package drift

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 16
SCRIPT_COMMAND_EVERY :: 256
SCRIPT_START_AT :: 32 // in each SCRIPT_COMMAND_EVERY ticks
SCRIPT_RESTART_AT :: 160

// 32 bits from a hash of (seed, player, block).
scripted_bits :: proc(seed: u64, player: int, block: u32) -> u32 {
	x := seed * 0x9E3779B97F4A7C15 ~ u64(player + 1) * 0xBF58476D1CE4E5B9 ~ u64(block + 1) * 0x94D049BB133111EB
	x ~= x >> 31
	x *= 0xD6E8FEB86659FD93
	x ~= x >> 32
	return u32(x)
}

// One player's scripted input for a tick, a pure function of (seed, player, tick): the input the headless modes,
// the end-to-end suite and a Godot scripted session feed the sim, identical wherever it is asked for.
scripted_input :: proc(seed: u64, player: int, tick: u32, state: ^State) -> Input {
	bits := scripted_bits(seed, player, (tick - 1) / SCRIPT_PERIOD)
	input: Input
	if bits % 5 != 4 {
		move := bits % 8
		input.move_x = i8(dmath.DIR8_C[move] * 127)
		input.move_y = i8(dmath.DIR8_S[move] * 127)
	}
	aim := (bits >> 4) % 8
	input.aim_x = i8(dmath.DIR8_C[aim] * 127)
	input.aim_y = i8(dmath.DIR8_S[aim] * 127)
	if (bits >> 8) % 4 != 0 do input.buttons |= BUTTON_FIRE
	if (bits >> 10) % 6 == 0 do input.buttons |= BUTTON_BOOST
	return input
}

// Sends player 0's scripted `start` and `restart` on a fixed beat, so scripted runs go through whole matches and
// back to the lobby.
scripted_commands :: proc(seed: u64, player: int, tick: u32, state: ^State, out: ^sim.Command_Out) {
	if player != 0 do return
	switch tick % SCRIPT_COMMAND_EVERY {
	case SCRIPT_START_AT:
		sim.send_command(out, Cmd_Start{})
	case SCRIPT_RESTART_AT:
		sim.send_command(out, Cmd_Restart{})
	}
}
