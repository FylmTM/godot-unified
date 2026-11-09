// Scripted test inputs (games/survivor/SPEC.md "Scripted inputs"): per player, a value r re-drawn every 24 ticks
// as a hash of (seed, player, block), so any tick can be asked for in any order (netcode clients
// sample ticks as their clock reaches them, tests jump around).
package survivor

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 24

script_r :: proc(seed: u64, p: int, t: u32) -> u32 {
	block := u64(t - 1) / SCRIPT_PERIOD
	x := seed * 0x9E3779B97F4A7C15 ~ u64(p + 1) * 0xBF58476D1CE4E5B9 ~ (block + 1) * 0x94D049BB133111EB
	x ~= x >> 31
	x *= 0xD6E8FEB86659FD93
	x ~= x >> 32
	return u32(x)
}

// Input of player p for tick t (t >= 1).
script_input :: proc(seed: u64, p: int, t: u32) -> Input {
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
	return in_
}

// The scripted input hook: what the headless modes and test sessions feed in.
script :: proc(seed: u64, p: int, t: u32, s: ^State) -> Input {
	return script_input(seed, p, t)
}

// The scripted commands hook: a level-up pick at the start of every 24-tick block, whether or not one is
// pending (the sim ignores it then), so the script depends on (seed, p, t) only, like the inputs.
script_commands :: proc(seed: u64, p: int, t: u32, s: ^State, out: ^sim.Command_Out) {
	if (t - 1) % SCRIPT_PERIOD == 0 {
		sim.send_command(out, Cmd_Pick{Upgrade(script_r(seed, p, t) % 3)})
	}
}
