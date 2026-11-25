// Scripted inputs for the headless modes, test sessions, benchmarks and Godot's `--scripted` runs: pure functions of
// (seed, slot, tick), so any tick can be asked for in any order and a Godot scripted session sends what the offline
// binary does.
package horde

import "unified:dmath"
import "unified:sim"

SCRIPT_PERIOD :: 32 // ticks a scripted direction holds
SCRIPT_IDLE_ONE_IN :: 6 // one block in this many the scripted hero stands still

// The hero in `slot` walks one of 8 directions, drawn again every SCRIPT_PERIOD ticks (some blocks standing still).
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State, setup: sim.No_Setup) -> Input {
	bits := sim.script_bits(seed, slot, tick, SCRIPT_PERIOD)
	if bits % SCRIPT_IDLE_ONE_IN == 0 do return {}
	move := dmath.DIR8[bits / SCRIPT_IDLE_ONE_IN % 8]
	return {dx = dmath.axis_i8(move.x), dy = dmath.axis_i8(move.y)}
}

// A level-up pick at the start of every SCRIPT_PERIOD block, whether or not one is pending (the sim ignores it then):
// an upgrade drawn from (seed, slot, tick), so the script depends on nothing else, for the oldest level (level 0: the
// script can't read which).
scripted_commands :: proc(
	seed: u64,
	slot: int,
	tick: u32,
	state: ^State,
	setup: sim.No_Setup,
	out: ^sim.Command_Out(Command),
) {
	if (tick - 1) % SCRIPT_PERIOD != 0 do return
	bits := sim.script_bits(seed, slot, tick, SCRIPT_PERIOD)
	sim.send_command(out, Command_Pick{upgrade = Upgrade(bits / 7 % len(Upgrade))})
}

BENCH_HALF :: 24 // the bench's population starts spread over a square of twice this

// The bench's setup: the population held at `count` (the waves refill to it, the heroes take no damage and start with
// every weapon high), pre-spawned over the arena from a fixed stream (outside any tick).
bench_prepare :: proc(t: ^Tick, count: int) {
	t.state.bench_hold = u32(dmath.min(count, MAX_ENEMIES))
	rng := sim.rng_seed(u64(count))
	for _ in 0 ..< int(t.state.bench_hold) {
		x := f32(sim.rng_below(&rng, BENCH_HALF * 200)) / 100 - BENCH_HALF // whole centimetres
		y := f32(sim.rng_below(&rng, BENCH_HALF * 200)) / 100 - BENCH_HALF
		enemy, _ := sim.spawn(&t.state.enemies) or_break
		enemy_set(enemy, SPAWN_KINDS[sim.rng_below(&rng, len(SPAWN_KINDS))], {x, y}, 0)
	}
}
