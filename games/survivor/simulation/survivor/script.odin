// Scripted test inputs (games/survivor/SPEC.md "Scripted inputs"): per slot, a value re-drawn every 24 ticks
// as a hash of (seed, slot, block), so any tick can be asked for in any order (netcode clients
// sample ticks as their clock reaches them, tests jump around).
package survivor

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 24

// The scripted value of `slot` for `tick`'s 24-tick block.
script_roll :: proc(seed: u64, slot: int, tick: u32) -> u32 {
	block := u64(tick - 1) / SCRIPT_PERIOD
	x := seed * 0x9E3779B97F4A7C15 ~ u64(slot + 1) * 0xBF58476D1CE4E5B9 ~ (block + 1) * 0x94D049BB133111EB
	x ~= x >> 31
	x *= 0xD6E8FEB86659FD93
	x ~= x >> 32
	return u32(x)
}

// The scripted input hook (what the headless modes and test sessions feed in): the input of the player in `slot`
// for `tick` (>= 1). It ignores the state.
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State) -> (input: Input) {
	roll := script_roll(seed, slot, tick)
	if roll % 9 != 8 {
		direction := roll % 8
		input.move_x = i8(dmath.DIR8_C[direction] * 127)
		input.move_z = i8(dmath.DIR8_S[direction] * 127)
	}
	if roll % 13 == 0 {
		input.buttons |= BUTTON_DASH
	}
	return
}

// The scripted commands hook: a level-up pick at the start of every 24-tick block, whether or not one is
// pending (the sim ignores it then), so the script depends on (seed, slot, tick) only, like the inputs.
scripted_commands :: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out) {
	if (tick - 1) % SCRIPT_PERIOD == 0 {
		sim.send_command(out, Cmd_Pick{Upgrade(script_roll(seed, slot, tick) % 3)})
	}
}
