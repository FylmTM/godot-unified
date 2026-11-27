// Replay regressions on the toy (headless.regression_run): a recording blesses, reproduces, and a rule change names the
// first tick that differs and the field; an events-only change names the event (and, on the build that blessed it, is
// never blessed); another recording, a broken one and one that continues a snapshot.
package test_headless

import "core:os"
import "core:strings"
import "core:testing"

import "../toy"
import "unified:headless"
import "unified:sim"

// A replay folder holding a scripted run of the toy (seed, players, ticks) as its inputs.unil; the caller removes it.
@(private = "file")
record_folder :: proc(name: string, seed: u64, ticks: u32) -> string {
	folder := temp_path(name)
	_ = os.make_directory_all(folder)
	input_log: sim.Input_Log(toy.Game)
	defer sim.log_destroy(&input_log)
	headless.run_sim(&toy.GAME, ticks, seed, 3, input_log = &input_log)
	headless.log_write(strings.concatenate({folder, "/inputs.unil"}, context.temp_allocator), &input_log)
	return folder
}

// The toy, but from tick 150 on every tick also counts one more spawn: a rules change the block shows.
@(private = "file")
spawns_more :: proc(t: ^toy.Tick) {
	toy.tick(t)
	if t.number >= 150 do t.state.spawned += 1
}

// The toy, but tick 100 also emits an expiry: a change only the events show.
@(private = "file")
expires_more :: proc(t: ^toy.Tick) {
	toy.tick(t)
	if t.number == 100 do sim.emit(t, toy.Event_Expired{})
}

@(test)
a_recording_blesses_then_reproduces :: proc(t: ^testing.T) {
	folder := record_folder("regression-bless", 7, 300)
	defer os.remove_all(folder)
	unblessed := headless.regression_run(&toy.GAME, folder)
	testing.expect_value(t, unblessed.status, headless.Regression_Status.Unblessed)
	testing.expect(t, strings.contains(unblessed.report, "no expected.unie"), unblessed.report)
	testing.expect(t, !unblessed.blessed)
	blessing := headless.regression_run(&toy.GAME, folder, bless = true)
	testing.expect(t, blessing.blessed, "a recording without an expectation is blessed")
	again := headless.regression_run(&toy.GAME, folder, bless = true)
	testing.expect(t, again.status == .Reproduces && !again.blessed, "one that reproduces is left alone")
	result := headless.regression_run(&toy.GAME, folder)
	testing.expect_value(t, result.status, headless.Regression_Status.Reproduces)
	testing.expect_value(t, result.ticks, 300)
	testing.expect_value(t, result.diverged_tick, 0)
	testing.expect_value(t, result.report, "")
	// sync-tested: every tick rolled back and re-simulated agrees
	synced := headless.regression_run(&toy.GAME, folder, synctest = true)
	testing.expect_value(t, synced.status, headless.Regression_Status.Reproduces)
	testing.expect(t, synced.synctest.resimulated > 0 && synced.synctest.mismatches == 0, "the replay is sync-tested")
}

@(test)
a_rules_change_names_the_tick_and_the_field :: proc(t: ^testing.T) {
	folder := record_folder("regression-rules", 7, 300)
	defer os.remove_all(folder)
	headless.regression_run(&toy.GAME, folder, bless = true)
	changed := toy.GAME
	changed.tick = spawns_more
	changed.version = "changed" // another build: the report says so, and the results still decide
	result := headless.regression_run(&changed, folder)
	testing.expect_value(t, result.status, headless.Regression_Status.Diverges)
	testing.expect_value(t, result.diverged_tick, 150)
	testing.expectf(
		t,
		strings.contains(result.report, "first differs at tick 150") &&
		strings.contains(result.report, "at tick 160 (blessed vs now): spawned") &&
		strings.contains(result.report, "blessed by another build"),
		"the report names the tick, the stored block's field and the build: %s",
		result.report,
	)
	// blessing the change: it reproduces from then on, and the old rules diverge
	testing.expect(t, headless.regression_run(&changed, folder, bless = true).blessed)
	testing.expect_value(t, headless.regression_run(&changed, folder).status, headless.Regression_Status.Reproduces)
	testing.expect_value(t, headless.regression_run(&toy.GAME, folder).diverged_tick, 150)
}

@(test)
an_events_change_names_the_event :: proc(t: ^testing.T) {
	folder := record_folder("regression-events", 7, 200)
	defer os.remove_all(folder)
	headless.regression_run(&toy.GAME, folder, bless = true)
	changed := toy.GAME
	changed.tick = expires_more
	result := headless.regression_run(&changed, folder)
	testing.expect_value(t, result.status, headless.Regression_Status.Diverges)
	testing.expect_value(t, result.diverged_tick, 100)
	testing.expectf(t, strings.contains(result.report, "its events"), "the report names the events: %s", result.report)
	testing.expectf(t, !strings.contains(result.report, "blessed vs now"), "the block agrees: %s", result.report)
	// the same build (its version not bumped): never blessed, and the report says why
	testing.expectf(
		t,
		strings.contains(result.report, "on the build that blessed it"),
		"the report names the build: %s",
		result.report,
	)
	refused := headless.regression_run(&changed, folder, bless = true)
	testing.expect(t, refused.status == .Diverges && !refused.blessed, "a divergence on the blessing build stays")
	changed.version = "changed"
	testing.expect(
		t,
		headless.regression_run(&changed, folder, bless = true).blessed,
		"with a version bump it blesses",
	)
}

@(test)
another_recording_or_a_broken_one_is_not_checked :: proc(t: ^testing.T) {
	folder := record_folder("regression-swap", 7, 200)
	defer os.remove_all(folder)
	headless.regression_run(&toy.GAME, folder, bless = true)
	// another recording copied over the blessed one
	other := record_folder("regression-swap-other", 8, 200)
	defer os.remove_all(other)
	other_log, _ := os.read_entire_file(
		strings.concatenate({other, "/inputs.unil"}, context.temp_allocator),
		context.temp_allocator,
	)
	_ = os.write_entire_file(strings.concatenate({folder, "/inputs.unil"}, context.temp_allocator), other_log)
	swapped := headless.regression_run(&toy.GAME, folder)
	testing.expect_value(t, swapped.status, headless.Regression_Status.Unblessed)
	testing.expect(t, strings.contains(swapped.report, "another recording"), swapped.report)
	// bytes that are no recording of this game
	_ = os.write_entire_file(
		strings.concatenate({folder, "/inputs.unil"}, context.temp_allocator),
		transmute([]u8)string("UNIL?"),
	)
	broken := headless.regression_run(&toy.GAME, folder, bless = true)
	testing.expect_value(t, broken.status, headless.Regression_Status.Broken)
	testing.expect(t, !broken.blessed, "a broken recording is never blessed")
	// a damaged expectation is unblessed, not a crash
	_ = os.write_entire_file(strings.concatenate({folder, "/inputs.unil"}, context.temp_allocator), other_log)
	_ = os.write_entire_file(
		strings.concatenate({folder, "/", headless.REGRESSION_EXPECTED}, context.temp_allocator),
		transmute([]u8)string("UNIE\x01\x00"),
	)
	testing.expect_value(t, headless.regression_run(&toy.GAME, folder).status, headless.Regression_Status.Unblessed)
}

// The toy, but from tick 150 on a tick computed while draws are kept counts one more spawn: a plain replay never
// shows it, a sync-tested one does (its re-simulations keep every draw group, its forward ticks none).
@(private = "file")
spawns_more_while_drawing :: proc(t: ^toy.Tick) {
	toy.tick(t)
	if t.number >= 150 && sim.drawing(t) do t.state.spawned += 1
}

// A recording that continues a snapshot (a joiner's, an F3 note's, every session recording): it replays from its
// snapshot.unis, and without one it is broken; sync-tested, it rolls back from the snapshot's tick on, and a tick that
// re-simulates differently is caught.
@(test)
a_recording_from_a_snapshot_reproduces :: proc(t: ^testing.T) {
	folder := temp_path("regression-snapshot")
	_ = os.make_directory_all(folder)
	defer os.remove_all(folder)
	snapshot, _ := headless.run_snapshot(&toy.GAME, 120, 7, 3)
	defer delete(snapshot)
	simulation, err := sim.from_snapshot(&toy.GAME, snapshot)
	testing.expect_value(t, err, sim.Snap_Error.None)
	defer sim.destroy(simulation)
	input_log := sim.Input_Log(toy.Game) {
		seed    = simulation.seed,
		setup   = simulation.setup,
		content = simulation.content_hash,
		compat  = sim.compat_of(&toy.GAME),
		from    = 120,
	}
	defer sim.log_destroy(&input_log)
	commands: headless.Scripted_Commands(toy.Game)
	defer headless.scripted_commands_destroy(&commands)
	for tick in u32(121) ..= 300 {
		inputs := headless.scripted(&toy.GAME, simulation, tick, 3, &commands)
		sim.log_append(&input_log, &inputs)
		sim.step(simulation, &inputs)
	}
	headless.log_write(strings.concatenate({folder, "/inputs.unil"}, context.temp_allocator), &input_log)
	missing := headless.regression_run(&toy.GAME, folder)
	testing.expect_value(t, missing.status, headless.Regression_Status.Broken)
	_ = os.write_entire_file(strings.concatenate({folder, "/snapshot.unis"}, context.temp_allocator), snapshot)
	testing.expect(t, headless.regression_run(&toy.GAME, folder, bless = true).blessed)
	result := headless.regression_run(&toy.GAME, folder, synctest = true)
	testing.expect_value(t, result.status, headless.Regression_Status.Reproduces)
	testing.expect_value(t, result.ticks, 180)
	testing.expect_value(t, result.synctest.mismatches, 0)
	testing.expect_value(t, result.synctest.check, "")
	testing.expect_value(t, result.synctest.problem, "")
	// tick 120 + k rolls back min(k, 8) ticks: to the snapshot's tick at first, never before it
	testing.expect_value(t, result.synctest.resimulated, (1 + 2 + 3 + 4 + 5 + 6 + 7) + (180 - 7) * 8)
	// a tick that re-simulates differently: the plain replay reproduces, the sync-tested one names the first tick
	drawing := toy.GAME
	drawing.tick = spawns_more_while_drawing
	testing.expect_value(t, headless.regression_run(&drawing, folder).status, headless.Regression_Status.Reproduces)
	diverging := headless.regression_run(&drawing, folder, synctest = true)
	testing.expect(t, diverging.synctest.mismatches > 0, "the sync-test catches the re-simulation")
	testing.expect_value(t, diverging.synctest.first_tick, 150)
	testing.expect_value(t, diverging.synctest.first_at, 150)
	testing.expect_value(t, diverging.synctest.first_diff, "spawned 8 vs 9") // the forward run's, then the re-simulation's
	changed := toy.GAME
	changed.tick = spawns_more
	testing.expect_value(t, headless.regression_run(&changed, folder).diverged_tick, 150)
}

@(test)
regression_folders_are_the_folders_with_a_recording :: proc(t: ^testing.T) {
	root := temp_path("regression-folders")
	defer os.remove_all(root)
	for name in ([]string{"b", "a", "empty"}) {
		_ = os.make_directory_all(strings.concatenate({root, "/", name}, context.temp_allocator))
	}
	for name in ([]string{"b", "a"}) {
		_ = os.write_entire_file(
			strings.concatenate({root, "/", name, "/inputs.unil"}, context.temp_allocator),
			[]u8{},
		)
	}
	_ = os.write_entire_file(strings.concatenate({root, "/inputs.unil"}, context.temp_allocator), []u8{})
	folders := headless.regression_folders(root)
	testing.expect_value(t, len(folders), 2)
	if len(folders) == 2 {
		testing.expect(t, strings.has_suffix(folders[0], "a") && strings.has_suffix(folders[1], "b"), "sorted")
	}
	testing.expect_value(
		t,
		len(headless.regression_folders(strings.concatenate({root, "/none"}, context.temp_allocator))),
		0,
	)
}
