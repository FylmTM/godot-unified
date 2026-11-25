// Scripted test inputs (examples/survivor/README.md, Scripted inputs): per slot, a value re-drawn every SCRIPT_PERIOD
// ticks as a hash of (seed, slot, block), so any tick can be asked for in any order (netcode clients sample ticks as
// their clock reaches them, tests jump around).
package survivor

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 24
SCRIPT_IDLE_ONE_IN :: 9 // one block in this many the scripted player stands still
SCRIPT_DASH_ONE_IN :: 13 // and one in this many it dashes

// The scripted input hook (what the headless modes and test sessions feed in): the input of the player in `slot`
// for `tick` (>= 1). It ignores the state.
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State, setup: Setup) -> (input: Input) {
	roll := sim.script_bits(seed, slot, tick, SCRIPT_PERIOD)
	if roll % SCRIPT_IDLE_ONE_IN != SCRIPT_IDLE_ONE_IN - 1 {
		direction := roll % 8
		input.move_x = dmath.axis_i8(dmath.DIR8[direction].x)
		input.move_z = dmath.axis_i8(dmath.DIR8[direction].y)
	}
	if roll % SCRIPT_DASH_ONE_IN == 0 {
		input.buttons += {.Dash}
	}
	return
}

// The scripted commands hook: a level-up pick at the start of every SCRIPT_PERIOD-tick block, whether or not one is
// pending (the sim ignores it then), for the oldest level (level 0: the script can't read which), so the script
// depends on (seed, slot, tick) only, like the inputs.
scripted_commands :: proc(
	seed: u64,
	slot: int,
	tick: u32,
	state: ^State,
	setup: Setup,
	out: ^sim.Command_Out(Command),
) {
	if (tick - 1) % SCRIPT_PERIOD == 0 {
		upgrade := Upgrade(sim.script_bits(seed, slot, tick, SCRIPT_PERIOD) % len(Upgrade))
		sim.send_command(out, Command_Pick{upgrade = upgrade})
	}
}
