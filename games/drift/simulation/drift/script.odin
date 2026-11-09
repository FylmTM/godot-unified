// Scripted inputs for the headless modes and test sessions: per player, a value re-drawn every 16 ticks from a
// hash of (seed, player, block), so any tick can be asked for in any order. The ships wander, turn toward one
// of 8 directions, fire most of the time and boost now and then. Slot 0 sends `start` and `restart` on a fixed
// beat (the sim ignores each outside its phase), so scripted runs play whole matches; commands depend only on
// (seed, slot, tick), so a Godot session's scripted commands match the offline binary's.
package drift

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 16
SCRIPT_COMMAND_EVERY :: 256
SCRIPT_START_AT :: 32 // in each SCRIPT_COMMAND_EVERY ticks
SCRIPT_RESTART_AT :: 160

script_r :: proc(seed: u64, p: int, block: u32) -> u32 {
	x := seed * 0x9E3779B97F4A7C15 ~ u64(p + 1) * 0xBF58476D1CE4E5B9 ~ u64(block + 1) * 0x94D049BB133111EB
	x ~= x >> 31
	x *= 0xD6E8FEB86659FD93
	x ~= x >> 32
	return u32(x)
}

script :: proc(seed: u64, p: int, t: u32, s: ^State) -> Input {
	r := script_r(seed, p, (t - 1) / SCRIPT_PERIOD)
	in_: Input
	if r % 5 != 4 {
		k := r % 8
		in_.move_x = i8(dmath.DIR8_C[k] * 127)
		in_.move_y = i8(dmath.DIR8_S[k] * 127)
	}
	a := (r >> 4) % 8
	in_.aim_x = i8(dmath.DIR8_C[a] * 127)
	in_.aim_y = i8(dmath.DIR8_S[a] * 127)
	if (r >> 8) % 4 != 0 do in_.buttons |= BUTTON_FIRE
	if (r >> 10) % 6 == 0 do in_.buttons |= BUTTON_BOOST
	return in_
}

script_commands :: proc(seed: u64, p: int, t: u32, s: ^State, out: ^sim.Command_Out) {
	if p != 0 do return
	switch t % SCRIPT_COMMAND_EVERY {
	case SCRIPT_START_AT:
		sim.send_command(out, Cmd_Start{})
	case SCRIPT_RESTART_AT:
		sim.send_command(out, Cmd_Restart{})
	}
}
