// The standard end-to-end scenarios (src/headless/README.md, End-to-end suites), one proc each. Every
// game's suite (examples/<game>/simulation/tests/suite_test.odin) and the toy's (tests/scenarios) call
// each of them from a test of its own. Test-only: it imports core:testing, so game binaries never
// import it. Failures name the scenario, its parameters and the first tick that differs.
package scenarios

import "core:fmt"
@(require) import "core:log" // only in reference_reproduces and replays_reproduce (generic)
@(require) import "core:path/filepath" // only in replays_reproduce (generic)
@(require) import "core:slice" // only in reference_reproduces (generic)
import "core:testing"

import "unified:headless"
import "unified:netcode"
import "unified:sim"

// `uni test --long` builds with -define:UNIFIED_LONG_TESTS=true: a game's suite then runs every
// standard scenario at full length (src/headless/README.md, End-to-end suites). The toy's suite always does.
LONG :: #config(UNIFIED_LONG_TESTS, false)

// `uni test --bless` builds with -define:UNIFIED_BLESS=true: replays_reproduce then writes a new expectation for each
// recording that diverges or has none, instead of failing (src/headless/README.md, Replay regressions).
BLESS :: #config(UNIFIED_BLESS, false)

// A game's suite: the game and the parameters of its runs.
Suite :: struct($G: typeid) {
	game:    ^G, // its scripted player (sim.Game.scripted_input) plays every run, on its levels (sim.Game.levels)
	players: int, // scripted players in offline runs
	seed:    u64,
	ticks:   u32, // length of offline runs and sessions
}

// Whether the game passes sim.game_violation (an event field named `kind`, a Setup that doesn't read as sent...): one
// failure saying why instead of a panic in every run, and the leak report the panic leaves.
@(private)
game_ok :: proc(t: ^testing.T, game: ^$G) -> bool {
	reason := sim.game_violation(game)
	return testing.expectf(t, reason == "", "the game breaks a rule of the harness: %s", reason)
}

// A run every platform must reproduce, pinned by hashes: the game's scripted run of `ticks` ticks with `players`
// players and `seed` (run_sim). A game's tests keep it as a constant (`REFERENCE :: scenarios.Reference{...}`);
// reference_reproduces prints the literal to paste when a deliberate sim change moves it (the unified-sim-change skill).
Reference :: struct {
	seed:          u64,
	players:       int,
	ticks:         u32,
	snapshot_tick: u32, // the portable snapshot taken there resumes to `ticks`
	checkpoints:   [4]u64, // the checksum at ticks / 4, ticks / 2, 3 * ticks / 4 and ticks
	trace:         u64, // the hash of every tick's checksum
	snapshot:      u64, // the hash of the snapshot's bytes
	log:           u64, // the hash of the input log's bytes
}


// Restoring `window` ticks back and re-simulating, every tick, reproduces every tick's checksum and events, the Extra
// agrees after every restore and no NaN reaches the block (headless.run_synctest). `window` is at most
// headless.max_window(game) (the game's ring).
rollback_every_tick :: proc(t: ^testing.T, suite: ^Suite($G), window: u32 = 8) {
	if !game_ok(t, suite.game) do return
	longest := headless.max_window(suite.game)
	if !testing.expectf(
		t,
		window >= 1 && int(window) <= longest,
		"rollback_every_tick (window %d): the game's ring allows windows of 1 to %d",
		window,
		longest,
	) {
		return
	}
	result := headless.run_synctest(suite.game, suite.ticks, window, suite.seed, suite.players)
	testing.expectf(
		t,
		result.mismatches == 0,
		"rollback_every_tick (window %d; %s): %d mismatches; first: tick %d re-simulated differently at tick %d",
		window,
		params(suite),
		result.mismatches,
		result.first_tick,
		result.first_at,
	)
	testing.expectf(
		t,
		result.check == "",
		"rollback_every_tick (window %d; %s): after restoring tick %d: %s",
		window,
		params(suite),
		result.check_tick,
		result.check,
	)
	testing.expectf(
		t,
		result.problem == "",
		"rollback_every_tick (window %d; %s): %s",
		window,
		params(suite),
		result.problem,
	)
	testing.expectf(
		t,
		suite.ticks < window || result.resimulated > 0,
		"rollback_every_tick (%s): nothing re-simulated",
		params(suite),
	)
}

// A game test's sync-tested run (headless.Run) re-simulated every tick the same, and its extra agreed with the block
// after every restore.
expect_synced :: proc(t: ^testing.T, run: ^headless.Run($G), loc := #caller_location) -> bool {
	synced := testing.expectf(
		t,
		run.mismatches == 0,
		"%d mismatches; first: tick %d re-simulated differently at tick %d",
		run.mismatches,
		run.first_tick,
		run.first_at,
		loc = loc,
	)
	agreed := testing.expectf(t, run.check == "", "after restoring tick %d: %s", run.check_tick, run.check, loc = loc)
	clean := testing.expectf(t, run.problem == "", "%s", run.problem, loc = loc)
	return synced && agreed && clean
}

// Every replay regression in `dir` (a game's `#directory + "/replays"`: one replay folder per recording,
// headless.regression_folders) reproduces its blessed expectation: each tick's checksum and events, the first that
// differs named with the fields that differ (headless.regression_run). With BLESS, a recording that diverges or has no
// expectation is blessed instead (a warning says which, and where it diverged); with LONG, each replay is sync-tested
// too. No folder: nothing to check.
replays_reproduce :: proc(t: ^testing.T, game: ^$G, dir: string) {
	if !game_ok(t, game) do return
	for folder in headless.regression_folders(dir) {
		name := fmt.tprintf("%s/%s", filepath.base(dir), filepath.base(folder)) // replays/<name>
		result := headless.regression_run(game, folder, bless = BLESS, synctest = LONG)
		switch {
		case result.blessed:
			log.warnf("replays_reproduce: blessed %s (%s)", name, result.report)
		case result.status == .Broken:
			testing.expectf(t, false, "replays_reproduce: %s: %s", name, result.report)
		case result.status == .Unblessed:
			testing.expectf(
				t,
				false,
				"replays_reproduce: %s: %s: ./uni test %s --bless",
				name,
				result.report,
				game.name,
			)
		case result.status == .Diverges:
			testing.expectf(
				t,
				false,
				"replays_reproduce: %s: %s; if the change was meant: ./uni test %s --bless (the unified-sim-change skill)",
				name,
				result.report,
				game.name,
			)
		}
		synctest := &result.synctest
		testing.expectf(
			t,
			synctest.mismatches == 0,
			"replays_reproduce (sync-tested): %s: %d mismatches; first: tick %d re-simulated differently at tick %d",
			name,
			synctest.mismatches,
			synctest.first_tick,
			synctest.first_at,
		)
		testing.expectf(
			t,
			synctest.check == "",
			"replays_reproduce (sync-tested): %s: after restoring tick %d: %s",
			name,
			synctest.check_tick,
			synctest.check,
		)
		testing.expectf(t, synctest.problem == "", "replays_reproduce (sync-tested): %s: %s", name, synctest.problem)
	}
}

// Players come and go under rollback (restore `window` ticks back on every tick, as rollback_every_tick): slot 0's
// player leaves, someone new takes slot 0, a slot empties and the first player comes back there. Every re-simulated
// tick matches the forward run and the Extra agrees after every restore. (What the presence itself does, handles and
// join events, is sim.Players', proven in tests/sim; a game proves what its own things do.)
presence_churn :: proc(t: ^testing.T, suite: ^Suite($G), window: u32 = 8) {
	if !game_ok(t, suite.game) do return
	what := fmt.tprintf("presence_churn (window %d; %s)", window, params(suite))
	if !testing.expectf(
		t,
		suite.players >= 2 && suite.ticks >= 64 && int(window) <= headless.max_window(suite.game),
		"%s: needs 2 players, 64 ticks and a window the ring allows",
		what,
	) {
		return
	}
	start := suite.ticks / 4
	back := suite.players < sim.part(G, sim.GAME_PLAYERS) ? suite.players : suite.players - 1 // a free slot, or the last one, emptied
	NEWCOMER :: 100 // a member id the script gives nobody else
	seats := []headless.Seat {
		{tick = start, slot = 0, member = 0}, // member 1 leaves slot 0
		{tick = start + 8, slot = 0, member = NEWCOMER}, // someone new takes it
		{tick = start + 12, slot = back, member = 0},
		{tick = start + 20, slot = back, member = 1}, // member 1 comes back in another slot
	}
	result := headless.run_synctest(suite.game, suite.ticks, window, suite.seed, suite.players, seats)
	testing.expectf(
		t,
		result.mismatches == 0,
		"%s: %d mismatches; first: tick %d re-simulated differently at tick %d",
		what,
		result.mismatches,
		result.first_tick,
		result.first_at,
	)
	testing.expectf(t, result.check == "", "%s: after restoring tick %d: %s", what, result.check_tick, result.check)
	testing.expectf(t, result.problem == "", "%s: %s", what, result.problem)
}

// Two scripted runs with the same parameters compute the same ticks, alive in one process at once: the
// second created halfway through the first, then stepped alongside it and on after it (headless.run_interleaved).
runs_match :: proc(t: ^testing.T, suite: ^Suite($G)) {
	if !game_ok(t, suite.game) do return
	result := headless.run_interleaved(suite.game, suite.ticks, suite.seed, suite.players)
	testing.expectf(
		t,
		result.mismatches == 0,
		"runs_match (%s): a second run, created at the first's tick %d, differs first at tick %d: %016x vs %016x (%d ticks differ)",
		params(suite),
		result.second_start,
		result.first_tick,
		result.second,
		result.first,
		result.mismatches,
	)
}

// A session on the virtual clock: no desyncs, every client reaches `ticks` and verifies the same checksums, the
// relay's input log replays offline to them, and rollbacks happen unless the network is ideal. `churn`: every slot's
// input changes every tick (headless.Session_Config.churn), so every client rolls back on most of the ticks it
// verifies, and rollbacks cross the checksum ticks (their snapshots kept for a desync report on the way).
session_agrees :: proc(t: ^testing.T, suite: ^Suite($G), clients: int, profile: netcode.Network, churn := false) {
	if !game_ok(t, suite.game) do return
	what := fmt.tprintf(
		"session_agrees (%d clients, %s network%s; %s)",
		clients,
		netcode.PROFILES[profile].name,
		churn ? ", churn" : "",
		params(suite),
	)
	result := session(suite, clients, profile, churn = churn)
	defer headless.session_result_destroy(&result)
	check_session(t, what, suite, &result, profile != .Ideal)
	if churn && profile != .Ideal {
		for client, i in result.clients {
			testing.expectf(
				t,
				client.rollbacks * 2 > int(suite.ticks),
				"%s: client %d rolled back %d times in %d ticks",
				what,
				i,
				client.rollbacks,
				suite.ticks,
			)
		}
	}
}

// A session of `suite.players` clients in which slot `slot` joins at `tick` (from a snapshot handed over
// through the relay): no desyncs, the joiner's checksums match the others' from its first verified tick on, and the
// relay's input log replays to them.
late_join_agrees :: proc(t: ^testing.T, suite: ^Suite($G), profile: netcode.Network, slot: int, tick: u32) {
	if !game_ok(t, suite.game) do return
	what := fmt.tprintf(
		"late_join_agrees (slot %d at tick %d, %s network; %s)",
		slot,
		tick,
		netcode.PROFILES[profile].name,
		params(suite),
	)
	if !testing.expectf(
		t,
		slot >= 1 && slot < suite.players && tick >= 2 && tick <= suite.ticks,
		"%s: needs 1 <= slot < players and 2 <= tick <= ticks",
		what,
	) {
		return
	}
	result := session(suite, suite.players, profile, slot, tick)
	defer headless.session_result_destroy(&result)
	check_session(t, what, suite, &result, false, slot, tick)
}

// The reference run reproduces on this platform: run_sim gives its checkpoints and every tick's checksums (`trace`),
// the input log it records encodes to the same bytes and replays to the same checksums, and the snapshot at
// `snapshot_tick` encodes to the same bytes and resumes to the same checksums. A mismatch prints the new literal: paste
// it only for a deliberate sim change (the unified-sim-change skill). To find the first tick that differs between two builds,
// run `uni headless <game> -- sim --trace FILE` on both and compare the files. A reference with only its four
// parameters set (seed, players, ticks, snapshot_tick: a new game's, the template's) is not pinned yet: the run warns
// with the literal to paste instead of failing, and its replay and resume checks still hold.
reference_reproduces :: proc(t: ^testing.T, game: ^$G, reference: Reference) {
	if !game_ok(t, game) do return
	what := fmt.tprintf("reference_reproduces (%s)", ref_params(reference))
	if !testing.expectf(
		t,
		reference.ticks >= 4 && reference.snapshot_tick > 0 && reference.snapshot_tick < reference.ticks,
		"%s: set the Reference's seed, players, ticks (4 or more) and snapshot_tick (inside the run); the run then prints the rest to paste",
		what,
	) {
		return
	}
	trace: headless.Trace
	defer headless.trace_destroy(&trace)
	input_log: sim.Input_Log(G)
	defer sim.log_destroy(&input_log)
	headless.run_sim(game, reference.ticks, reference.seed, reference.players, &trace, &input_log)
	got := reference
	for &checkpoint, k in got.checkpoints {
		checkpoint, _ = headless.trace_at(&trace, u32(k + 1) * reference.ticks / 4)
	}
	got.trace = sim.hash_bytes(slice.to_bytes(trace.sums[:]))
	log_bytes := sim.log_encode(&input_log)
	defer delete(log_bytes)
	got.log = sim.hash_bytes(log_bytes)
	snapshot, _ := headless.run_snapshot(game, reference.snapshot_tick, reference.seed, reference.players)
	defer delete(snapshot)
	got.snapshot = sim.hash_bytes(snapshot)
	literal := fmt.tprintf(
		"REFERENCE :: scenarios.Reference{{seed = %d, players = %d, ticks = %d, snapshot_tick = %d, checkpoints = " +
		"{{0x%016x, 0x%016x, 0x%016x, 0x%016x}}, trace = 0x%016x, snapshot = 0x%016x, log = 0x%016x}}",
		got.seed,
		got.players,
		got.ticks,
		got.snapshot_tick,
		got.checkpoints[0],
		got.checkpoints[1],
		got.checkpoints[2],
		got.checkpoints[3],
		got.trace,
		got.snapshot,
		got.log,
	)
	pinned := reference.checkpoints != {} || reference.trace != 0 || reference.snapshot != 0 || reference.log != 0
	if !pinned {
		// a new game's (the template's): nothing to compare with yet; the replay and resume checks below still hold
		// the literal indented: a passing run shows a warning's indented lines
		log.warnf("%s: no reference pinned yet; once the game's rules settle, pin this run:\n\t%s", what, literal)
	} else if got != reference {
		testing.expectf(
			t,
			false,
			"%s: this platform computes another run%s. If the sim changed on purpose, the reference is now:\n%s",
			what,
			first_checkpoint(reference, got),
			literal,
		)
	}
	// The log, decoded, replays to the run's checksums; the snapshot resumes to them.
	decoded, decoded_ok := sim.log_decode(log_bytes, G)
	defer sim.log_destroy(&decoded)
	replayed: headless.Trace
	defer headless.trace_destroy(&replayed)
	if _, replay_ok := headless.run_replay(game, &decoded, &replayed);
	   testing.expectf(t, decoded_ok && replay_ok, "%s: the log does not decode and replay", what) {
		expect_trace(t, what, "the replay", &replayed, &trace)
	}
	resumed: headless.Trace
	defer headless.trace_destroy(&resumed)
	resume_ticks := reference.ticks - reference.snapshot_tick
	if result, resume_ok := headless.run_resume(game, snapshot, resume_ticks, reference.players, &resumed);
	   testing.expectf(
		   t,
		   resume_ok && result.final_tick == reference.ticks,
		   "%s: the snapshot does not resume to tick %d",
		   what,
		   reference.ticks,
	   ) {
		expect_trace(t, what, "the resume", &resumed, &trace)
	}
}

// Where a run first left its reference: the first checkpoint that differs, else the hash that does (temp-allocated).
@(private)
first_checkpoint :: proc(want, got: Reference) -> string {
	for checkpoint, k in got.checkpoints {
		if checkpoint != want.checkpoints[k] {
			return fmt.tprintf(" (by tick %d)", u32(k + 1) * want.ticks / 4)
		}
	}
	switch {
	case got.trace != want.trace:
		return " (between its checkpoints)"
	case got.snapshot != want.snapshot:
		return " (its snapshot's bytes)"
	case got.log != want.log:
		return " (its log's bytes)"
	}
	return ""
}

// Every tick of `got` has the checksum `want` has for it.
@(private)
expect_trace :: proc(t: ^testing.T, what, which: string, got, want: ^headless.Trace) {
	if tick, got_checksum, want_checksum, wrong := first_wrong_tick(got, want); wrong {
		testing.expectf(
			t,
			false,
			"%s: %s differs from the run first at tick %d: %016x vs %016x",
			what,
			which,
			tick,
			got_checksum,
			want_checksum,
		)
	}
}

// --- helpers ---------------------------------------------------------------------------------------

@(private)
params :: proc(suite: ^Suite($G)) -> string {
	return fmt.tprintf("%d players, seed %d, %d ticks", suite.players, suite.seed, suite.ticks)
}

@(private)
ref_params :: proc(reference: Reference) -> string {
	return fmt.tprintf(
		"%d players, seed %d, %d ticks, snapshot at %d",
		reference.players,
		reference.seed,
		reference.ticks,
		reference.snapshot_tick,
	)
}

// The first tick of `got` whose checksum isn't `want`'s for that tick (one `want` lacks counts).
@(private)
first_wrong_tick :: proc(got, want: ^headless.Trace) -> (tick: u32, got_checksum, want_checksum: u64, wrong: bool) {
	for checksum, i in got.sums {
		tick = got.first + u32(i)
		wanted, has := headless.trace_at(want, tick)
		if !has || wanted != checksum {
			return tick, checksum, wanted, true
		}
	}
	return 0, 0, 0, false
}

@(private)
session :: proc(
	suite: ^Suite($G),
	clients: int,
	profile: netcode.Network,
	late_slot := 0,
	late_tick: u32 = 0,
	churn := false,
) -> headless.Session_Result(G) {
	return headless.session_run(suite.game, {
		clients   = clients,
		profile   = netcode.PROFILES[profile],
		ticks     = suite.ticks,
		seed      = suite.seed,
		late_slot = late_slot,
		late_tick = late_tick,
		churn     = churn,
	})
}

// A session's results agree: no desyncs; every client verified every tick; the starting clients'
// checksums cover every 16th tick and are equal; a late joiner's are contiguous from its first one
// (at or after its join tick) and equal the others'; the relay's input log replays offline to every checksum a
// client verified; rollbacks happened if `need_rollbacks`.
@(private)
check_session :: proc(
	t: ^testing.T,
	what: string,
	suite: ^Suite($G),
	result: ^headless.Session_Result(G),
	need_rollbacks: bool,
	joiner := -1,
	join_tick: u32 = 0,
) {
	testing.expectf(t, result.desyncs == 0, "%s: %d desyncs", what, result.desyncs)
	every := int(suite.ticks / 16)
	baseline := -1 // the first starting client whose checksums are complete: the others compare with it
	for client, i in result.clients {
		if !testing.expectf(
			t,
			client.ok && client.final_tick == suite.ticks,
			"%s: client %d verified up to tick %d of %d",
			what,
			i,
			client.final_tick,
			suite.ticks,
		) {
			continue
		}
		if i == joiner {
			continue
		}
		if !testing.expectf(
			t,
			len(client.checksums) == every && (every == 0 || client.checksums[every - 1][0] == u64(every * 16)),
			"%s: client %d's checksums don't cover every 16th tick (%d of %d)",
			what,
			i,
			len(client.checksums),
			every,
		) {
			continue
		}
		testing.expectf(t, !need_rollbacks || client.rollbacks > 0, "%s: client %d had no rollbacks", what, i)
		if baseline < 0 {
			baseline = i
			continue
		}
		for checksum, k in client.checksums {
			expected := result.clients[baseline].checksums[k]
			if checksum != expected {
				testing.expectf(
					t,
					false,
					"%s: client %d's checksum differs from client %d's first at tick %d: %016x vs %016x",
					what,
					i,
					baseline,
					checksum[0],
					checksum[1],
					expected[1],
				)
				break
			}
		}
	}
	testing.expectf(t, result.ok, "%s: the session did not complete cleanly", what)
	expect_log_replays(t, what, suite, result)
	if joiner < 0 || baseline < 0 || joiner >= len(result.clients) || !result.clients[joiner].ok {
		return
	}
	joiner_checksums := result.clients[joiner].checksums
	if !testing.expectf(t, len(joiner_checksums) > 0, "%s: the joiner verified no checksums", what) {
		return
	}
	first := u32(joiner_checksums[0][0])
	if !testing.expectf(
		t,
		first >= join_tick && first % 16 == 0 && len(joiner_checksums) == every - int(first / 16) + 1,
		"%s: the joiner's checksums start at tick %d and are not every 16th tick from there to %d",
		what,
		first,
		suite.ticks,
	) {
		return
	}
	for checksum in joiner_checksums {
		expected := result.clients[baseline].checksums[checksum[0] / 16 - 1]
		if checksum != expected {
			testing.expectf(
				t,
				false,
				"%s: the joiner's checksum differs from client %d's first at tick %d: %016x vs %016x",
				what,
				baseline,
				checksum[0],
				checksum[1],
				expected[1],
			)
			return
		}
	}
}

// The relay's input log of a session replays offline to every checksum each client verified.
@(private)
expect_log_replays :: proc(t: ^testing.T, what: string, suite: ^Suite($G), result: ^headless.Session_Result(G)) {
	if !testing.expectf(
		t,
		len(result.log.ticks) == int(suite.ticks),
		"%s: the relay's log has %d ticks",
		what,
		len(result.log.ticks),
	) {
		return
	}
	trace: headless.Trace
	defer headless.trace_destroy(&trace)
	if _, ok := headless.run_replay(suite.game, &result.log, &trace);
	   !testing.expectf(t, ok, "%s: the relay's log does not replay", what) {
		return
	}
	for client in result.clients {
		for verified in client.checksums {
			got, _ := headless.trace_at(&trace, u32(verified[0]))
			if got != verified[1] {
				testing.expectf(
					t,
					false,
					"%s: the log's replay differs from client %d first at tick %d: %016x vs verified %016x",
					what,
					client.slot,
					verified[0],
					got,
					verified[1],
				)
				break
			}
		}
	}
}
