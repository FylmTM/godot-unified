// Scripted test inputs (games/survivor/SPEC.md "Scripted inputs"): per slot, a value re-drawn every 24 ticks
// as a hash of (seed, slot, block), so any tick can be asked for in any order (netcode clients
// sample ticks as their clock reaches them, tests jump around).
package survivor

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 24
// The scripted input hook (what the headless modes and test sessions feed in): the input of the player in `slot`
// for `tick` (>= 1). It ignores the state.
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State) -> (input: Input) {
	roll := sim.script_bits(seed, slot, tick, SCRIPT_PERIOD)
	if roll % 9 != 8 {
		direction := roll % 8
		input.move_x = dmath.axis_i8(dmath.DIR8[direction].x)
		input.move_z = dmath.axis_i8(dmath.DIR8[direction].y)
	}
	if roll % 13 == 0 {
		input.buttons += {.Dash}
	}
	return
}

// The scripted commands hook: a level-up pick at the start of every 24-tick block, whether or not one is
// pending (the sim ignores it then), so the script depends on (seed, slot, tick) only, like the inputs.
scripted_commands :: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out(Cmd)) {
	if (tick - 1) % SCRIPT_PERIOD == 0 {
		sim.send_command(out, Cmd_Pick{Upgrade(sim.script_bits(seed, slot, tick, SCRIPT_PERIOD) % 3)})
	}
}
