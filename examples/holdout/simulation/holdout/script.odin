// Scripted inputs for the headless modes and test sessions: pure functions of (seed, slot, tick), so any tick can be
// asked for in any order and a Godot scripted session sends what the offline binary does.
package holdout

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 32 // ticks a scripted stick direction holds
SCRIPT_LOOK_PERIOD :: 256 // ticks a scripted player faces one gate (each slot its own)
SCRIPT_THROW_EVERY :: 160 // ticks between a slot's grenade presses
SCRIPT_READY_AT :: 64 // slot 0 presses Ready this far into every SCRIPT_READY_EVERY ticks
SCRIPT_READY_EVERY :: 1024

// The headings toward the yard's gates from the middle (yaw in turns, Aim's convention: 0 along -Z, a quarter toward
// -X): north, east, west (game/levels/yard.tscn's gate markers).
@(rodata)
SCRIPT_GATE_YAWS := [3]f32{0, 0.75, 0.25}

// The player in `slot` wanders (a stick drawn every SCRIPT_PERIOD ticks, at half tilt), faces one of the gates and
// sweeps its aim across it, fires three ticks in four, throws a grenade every SCRIPT_THROW_EVERY ticks (each slot at
// its own tick), holds Use now and then, and slot 0 presses Ready so the runs start.
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State) -> Input {
	bits := sim.script_bits(seed, slot, tick, SCRIPT_PERIOD)
	move := dmath.DIR8[bits % 8] * 0.5
	input := Input {
		move_x = dmath.axis_i8(move.x),
		move_z = dmath.axis_i8(move.y),
	}
	gate := sim.script_bits(seed, slot, tick, SCRIPT_LOOK_PERIOD) % 3
	sweep := f32((tick + u32(slot) * 37) % 64) / 64 // a triangle wave across ±0.04 turns
	sweep = (sweep < 0.5 ? sweep : 1 - sweep) * 0.16 - 0.04
	input.aim = dmath.aim(SCRIPT_GATE_YAWS[gate] + sweep, -0.012)
	if tick % 4 != 0 do input.buttons += {.Fire}
	if (tick + u32(slot) * 40) % SCRIPT_THROW_EVERY == 0 do input.buttons += {.Grenade}
	if (bits >> 8) % 4 == 0 do input.buttons += {.Use}
	if (bits >> 12) % 8 == 0 do input.buttons += {.Jump}
	if slot == 0 && tick % SCRIPT_READY_EVERY == SCRIPT_READY_AT do input.buttons += {.Ready}
	return input
}
