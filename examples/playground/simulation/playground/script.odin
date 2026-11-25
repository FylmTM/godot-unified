// Scripted inputs for the headless modes, the benchmarks and test sessions: pure functions of (seed, slot, tick), so every
// client of a session (whatever state it has when it asks) and every offline run play the same players.
package playground

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 32 // ticks a scripted stick holds
SCRIPT_GRAB_EVERY :: 128 // a slot grabs for SCRIPT_GRAB_TICKS of every this many ticks
SCRIPT_GRAB_TICKS :: 48
SCRIPT_SHOOT_EVERY :: 40
SCRIPT_SPAWN_EVERY :: 72
SCRIPT_EXPLODE_EVERY :: 160
SCRIPT_DRIVE_EVERY :: 256 // Driving: a slot gets in or out of a car
SCRIPT_SCENE_TICKS :: 640 // slot 0 changes the scene this often (after a benchmark's 600 ticks)
SCRIPT_LOOK_TICKS :: 256 // a scripted look sweeps left and right once in this many ticks

// The player in `slot` flies a stick drawn every SCRIPT_PERIOD ticks (mostly sideways and up or down: it stays near the
// scene it looks at), looks toward -Z (where each scene is, from the cameras' starts) sweeping a sixteenth of a turn
// either way every SCRIPT_LOOK_TICKS, a little down, and holds Grab for SCRIPT_GRAB_TICKS of every SCRIPT_GRAB_EVERY
// (reeling in or out).
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State, setup: Setup) -> Input {
	bits := sim.script_bits(seed, slot, tick, SCRIPT_PERIOD)
	direction := dmath.DIR8[bits % 8]
	input := Input {
		right   = dmath.axis_i8(direction.x),
		forward = dmath.axis_i8(direction.y * 0.3),
		up      = i8(bits / 8 % 3) * 60 - 60,
	}
	sweep := f32((tick + u32(slot) * 64) % SCRIPT_LOOK_TICKS) / SCRIPT_LOOK_TICKS // 0..1
	input.aim = dmath.aim(0.0625 * (2 * abs(2 * sweep - 1) - 1), -0.04)
	if (tick + u32(slot) * 32) % SCRIPT_GRAB_EVERY < SCRIPT_GRAB_TICKS {
		input.buttons += {.Grab}
		input.buttons += bits % 2 == 0 ? {.Closer} : {.Farther}
	}
	return input
}
// The player in `slot` shoots every SCRIPT_SHOOT_EVERY ticks, spawns a shape every SCRIPT_SPAWN_EVERY and sets off an
// explosion every SCRIPT_EXPLODE_EVERY (each slot at its own tick), gets in and out of a car every SCRIPT_DRIVE_EVERY (in
// Driving: elsewhere it does nothing), and slot 0 changes the scene every SCRIPT_SCENE_TICKS (the n-th change to the
// n-th scene, round the list), so the reference run crosses scene changes.
scripted_commands :: proc(
	seed: u64,
	slot: int,
	tick: u32,
	state: ^State,
	setup: Setup,
	out: ^sim.Command_Out(Command),
) {
	at := tick + u32(slot) * 8
	if slot == 0 && tick % SCRIPT_SCENE_TICKS == 0 && tick > 0 {
		sim.send_command(out, Command_Scene{scene = Scene(tick / SCRIPT_SCENE_TICKS % len(Scene))})
		return
	}
	switch {
	case at % SCRIPT_SHOOT_EVERY == 0:
		sim.send_command(out, Command_Shoot{})
	case at % SCRIPT_SPAWN_EVERY == 0:
		sim.send_command(out, Command_Spawn{shape = Shape(at / SCRIPT_SPAWN_EVERY % len(Shape))})
	case at % SCRIPT_EXPLODE_EVERY == 0:
		sim.send_command(out, Command_Explode{})
	case at % SCRIPT_DRIVE_EVERY == 0:
		sim.send_command(out, Command_Drive{})
	}
}
