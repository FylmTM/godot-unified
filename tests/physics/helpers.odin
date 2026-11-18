// What the physics test files share: the tick, stepping, tolerances, and the sync-test the Rig and the Field run.
package test_physics

import "core:testing"

import "unified:headless"
import "unified:physics"
import "unified:sim"

HZ :: 64
DT: f32 : 1.0 / HZ
SUBSTEPS :: 4

// `count` ticks of `world`.
steps :: proc(world: ^physics.World, count: int) {
	for _ in 0 ..< count do physics.step(world, DT, SUBSTEPS)
}

near :: proc(a, b: [3]f32, tolerance: f32 = 1e-4) -> bool {
	delta := a - b
	return abs(delta.x) <= tolerance && abs(delta.y) <= tolerance && abs(delta.z) <= tolerance
}

near_f32 :: proc(a, b: f32, tolerance: f32 = 1e-4) -> bool {
	return abs(a - b) <= tolerance
}

SYNC_WINDOW :: 8

// Sync-tests `game` for `ticks` ticks (headless.Run: after every tick a rollback SYNC_WINDOW ticks back, check_refs,
// and a re-simulation that must reproduce every checksum), with `each` after every forward tick and `after` once at
// the end; then a portable snapshot of the last tick resumes in a second session, bit-exact for 64 ticks. Returns the
// forward checksums (temp-allocated), which the 4-worker run must reproduce.
synctest_and_resume :: proc(
	t: ^testing.T,
	game: ^$G,
	seed: u64,
	ticks: u32,
	inputs: proc(tick: u32) -> sim.Inputs(G),
	each: proc(t: ^testing.T, simulation: ^sim.Sim(G)) = nil,
	after: proc(t: ^testing.T, simulation: ^sim.Sim(G)) = nil,
) -> []u64 {
	run := headless.run_begin(game, seed, window = SYNC_WINDOW)
	defer headless.run_end(&run)
	for tick in u32(1) ..= ticks {
		tick_inputs := inputs(tick)
		headless.run_step(&run, &tick_inputs)
		if each != nil do each(t, run.simulation)
	}
	testing.expectf(
		t,
		run.mismatches == 0,
		"%d re-simulated ticks differ, first tick %d",
		run.mismatches,
		run.first_tick,
	)
	testing.expectf(t, run.check == "", "after restoring tick %d: %s", run.check_tick, run.check)
	if after != nil do after(t, run.simulation)
	forward := make([]u64, len(run.forward), context.temp_allocator)
	copy(forward, run.forward[:])

	snap := sim.snapshot_encode(run.simulation, ticks)
	defer delete(snap)
	resumed, err := sim.from_snapshot(game, snap)
	testing.expect_value(t, err, sim.Snap_Error.None)
	if resumed == nil do return forward
	defer sim.destroy(resumed)
	for tick in ticks + 1 ..= ticks + 64 {
		tick_inputs, resumed_inputs := inputs(tick), inputs(tick)
		sim.step(run.simulation, &tick_inputs)
		sim.step(resumed, &resumed_inputs)
		testing.expect_value(t, sim.checksum(resumed), sim.checksum(run.simulation))
	}
	return forward
}
