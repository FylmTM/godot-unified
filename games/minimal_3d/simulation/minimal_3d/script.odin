// Scripted inputs for the headless modes and test sessions: pure functions of (seed, slot, tick), so any tick can be
// asked for in any order and a Godot scripted session sends what the offline binary does.
package minimal_3d

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 16 // ticks a scripted direction holds
SCRIPT_THROW_EVERY :: 32 // ticks between a slot's throws

// The player in `slot` steers one of 8 directions, drawn again every SCRIPT_PERIOD ticks.
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State) -> Input {
	bits := sim.script_bits(seed, slot, tick, SCRIPT_PERIOD)
	move := dmath.DIR8[bits % 8]
	return {dx = dmath.axis_i8(move.x), dy = dmath.axis_i8(move.y)}
}

// The player in `slot` throws a ball every SCRIPT_THROW_EVERY ticks (each slot at its own tick), 3 to 6 metres per
// second up.
scripted_commands :: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out(Cmd)) {
	if (tick + u32(slot) * 8) % SCRIPT_THROW_EVERY != 0 do return
	sim.send_command(out, Cmd_Throw_Ball{speed = 3 + u8(tick / SCRIPT_THROW_EVERY % 4)})
}
