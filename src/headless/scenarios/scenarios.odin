// The standard end-to-end scenarios (src/headless/SPEC.md, End-to-end suites), one proc each. Every
// game's suite (games/<game>/simulation/tests/suite_test.odin) and the toy's (tests/scenarios) call
// each of them from a test of its own. Test-only: it imports core:testing, so game binaries never
// import it. Failures name the scenario, its parameters and the first tick that differs.
package scenarios

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "unified:headless"
import "unified:netcode"
import "unified:sim"

// `uni record-reference <game>|toy` runs a suite with -define:UNIFIED_REGEN=true:
// reference_replays then writes a new reference run (and checks it) instead of only reading it.
UNIFIED_REGEN :: #config(UNIFIED_REGEN, false)
// The commit a regenerated reference run is made from (record-reference passes it, "+dirty" when the
// tree has changes); recorded in ref.json.
UNIFIED_REGEN_COMMIT :: #config(UNIFIED_REGEN_COMMIT, "unknown")
// `uni test --long` builds with -define:UNIFIED_LONG_TESTS=true: a game's suite then runs every
// standard scenario at full length (src/headless/SPEC.md, Running). The toy's suite always does.
LONG :: #config(UNIFIED_LONG_TESTS, false)

// A game's suite: its headless descriptor and the parameters of its runs.
Suite :: struct($G: typeid) {
	game:    ^G, // its scripted player (sim.Game.scripted_input) plays every run
	content: []u8, // its level (src/level/SPEC.md), if it has one
	players: int, // scripted players in offline runs
	seed:    u64,
	ticks:   u32, // length of offline runs and sessions
	ref:     Reference,
}

// A committed run every platform must reproduce: ref.log, ref.trace and ref-<snapshot_tick>.snap
// in `dir`, with ref.json saying where and how it was made.
Reference :: struct {
	dir:                  string, // #directory + "/testdata"
	ticks, snapshot_tick: u32, // ref.trace covers 1..ticks; ref-<snapshot_tick>.snap
	seed:                 u64,
	players:              int,
}

// The headless runs of a suite's game and content.
@(private)
headless_of :: proc(suite: ^Suite($G)) -> headless.Headless(G) {
	return {game = suite.game, content = suite.content}
}

// The network profiles of src/headless/SPEC.md (CLI).
Profile :: enum {
	Ideal,
	Wan,
	Bad,
}

@(rodata)
PROFILE_NAMES := [Profile]string {
	.Ideal = "ideal",
	.Wan   = "wan",
	.Bad   = "bad",
}

// Restoring `window` ticks back and re-simulating, every tick, reproduces every tick's checksum.
// `window` is at most headless.max_window(game) (the game's ring).
rollback_every_tick :: proc(t: ^testing.T, suite: ^Suite($G), window: u32 = 8) {
	runs := headless_of(suite)
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
	result := headless.run_synctest(&runs, suite.ticks, window, suite.seed, suite.players)
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
		suite.ticks < window || result.resimulated > 0,
		"rollback_every_tick (%s): nothing re-simulated",
		params(suite),
	)
}

// Players come and go under rollback (restore `window` ticks back on every tick, as rollback_every_tick): slot 0's
// player leaves, someone new takes slot 0, a slot empties and the first player comes back there. Every re-simulated
// tick matches the forward run, the newcomer is someone else, and the one who came back has their handle again.
presence_churn :: proc(t: ^testing.T, suite: ^Suite($G), window: u32 = 8) {
	runs := headless_of(suite)
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
	result := headless.run_synctest(&runs, suite.ticks, window, suite.seed, suite.players, seats)
	testing.expectf(
		t,
		result.mismatches == 0,
		"%s: %d mismatches; first: tick %d re-simulated differently at tick %d",
		what,
		result.mismatches,
		result.first_tick,
		result.first_at,
	)
	// Forward, the handles: the newcomer is someone else, the one who came back is who they were.
	simulation := sim.create(suite.game, suite.seed, suite.content)
	defer sim.destroy(simulation)
	commands := headless.Scripted_Commands(G) {
		seats = seats,
	}
	defer headless.scripted_commands_destroy(&commands)
	first: sim.Player
	for tick in 1 ..= start + 20 {
		inputs := headless.scripted(&runs, simulation, tick, suite.players, &commands)
		sim.step(simulation, &inputs)
		if tick == 1 do first = sim.player_in_slot(simulation, 0)
	}
	newcomer := sim.player_in_slot(simulation, 0)
	testing.expectf(t, newcomer.id == NEWCOMER && newcomer != first, "%s: slot 0 holds %v", what, newcomer)
	testing.expectf(t, sim.player_in_slot(simulation, back) == first, "%s: %v did not come back", what, first)
	returned := false
	joined_kind := sim.variant_kind(sim.part(G, sim.GAME_EVENT), sim.Event_Player_Joined)
	for &raw in sim.events_at(simulation, start + 20) {
		if int(raw.kind) == joined_kind {
			joined := (^sim.Event_Player_Joined)(&raw.data[0])^
			returned ||= joined.player == first && joined.returning && int(joined.slot) == back
		}
	}
	testing.expectf(t, returned, "%s: no returning join event for %v", what, first)
}

// Two scripted runs with the same parameters compute the same ticks, alive in one process at once: the
// second created halfway through the first, then stepped alongside it and on after it (headless.run_interleaved).
runs_match :: proc(t: ^testing.T, suite: ^Suite($G)) {
	runs := headless_of(suite)
	result := headless.run_interleaved(&runs, suite.ticks, suite.seed, suite.players)
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

// A session on the virtual clock: no desyncs, every client reaches `ticks` and verifies the same
// checksums, and rollbacks happen unless the network is ideal.
session_agrees :: proc(t: ^testing.T, suite: ^Suite($G), clients: int, profile: Profile) {
	what := fmt.tprintf("session_agrees (%d clients, %s network; %s)", clients, PROFILE_NAMES[profile], params(suite))
	result := session(suite, clients, profile)
	defer headless.session_result_destroy(&result)
	check_session(t, what, suite, &result, profile != .Ideal)
}

// A session's official input log (the relay's) replays offline to every checksum each client
// verified.
session_log_replays :: proc(t: ^testing.T, suite: ^Suite($G), clients: int, profile: Profile) {
	runs := headless_of(suite)
	what := fmt.tprintf(
		"session_log_replays (%d clients, %s network; %s)",
		clients,
		PROFILE_NAMES[profile],
		params(suite),
	)
	result := session(suite, clients, profile)
	defer headless.session_result_destroy(&result)
	if !testing.expectf(t, result.ok, "%s: the session did not complete", what) ||
	   !testing.expectf(
			   t,
			   len(result.log.ticks) == int(suite.ticks),
			   "%s: the log has %d ticks",
			   what,
			   len(result.log.ticks),
		   ) {
		return
	}
	trace: headless.Trace
	defer headless.trace_destroy(&trace)
	if _, ok := headless.run_replay(&runs, &result.log, &trace);
	   !testing.expectf(t, ok, "%s: the log does not replay", what) {
		return
	}
	for client in result.clients {
		for verified in client.checksums {
			got, _ := headless.trace_at(&trace, u32(verified[0]))
			if got != verified[1] {
				testing.expectf(
					t,
					false,
					"%s: the replay differs from client %d first at tick %d: %016x vs verified %016x",
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

// A session of `suite.players` clients in which `player` joins at `tick` (from a snapshot handed over
// through the relay): no desyncs, and the joiner's checksums match the others' from its first
// verified tick on.
late_join_agrees :: proc(t: ^testing.T, suite: ^Suite($G), profile: Profile, player: int, tick: u32) {
	what := fmt.tprintf(
		"late_join_agrees (player %d at tick %d, %s network; %s)",
		player,
		tick,
		PROFILE_NAMES[profile],
		params(suite),
	)
	if !testing.expectf(
		t,
		player >= 1 && player < suite.players && tick >= 2 && tick <= suite.ticks,
		"%s: needs 1 <= player < players and 2 <= tick <= ticks",
		what,
	) {
		return
	}
	result := session(suite, suite.players, profile, player, tick)
	defer headless.session_result_destroy(&result)
	check_session(t, what, suite, &result, false, player, tick)
}

// The replay of the committed ref.log reproduces ref.trace. With UNIFIED_REGEN it first writes a
// new reference run (and also checks its resume).
reference_replays :: proc(t: ^testing.T, suite: ^Suite($G)) {
	when UNIFIED_REGEN {
		if regenerate(t, suite) {
			check_replay(t, suite)
			check_resume(t, suite)
		}
	} else {
		check_replay(t, suite)
	}
}

// Resuming the committed snapshot reproduces the rest of ref.trace.
reference_resumes :: proc(t: ^testing.T, suite: ^Suite($G)) {
	when UNIFIED_REGEN {
		regen_note("reference_resumes: skipped while regenerating (reference_replays checks the new snapshot)")
	} else {
		check_resume(t, suite)
	}
}

@(private)
check_replay :: proc(t: ^testing.T, suite: ^Suite($G)) {
	runs := headless_of(suite)
	reference := suite.ref
	what := fmt.tprintf("reference_replays (%s)", ref_params(reference))
	input_log, ok := sim.log_read(ref_path(reference, "ref.log"), G)
	if !testing.expectf(t, ok, "%s: cannot read %s", what, ref_path(reference, "ref.log")) {
		return
	}
	defer sim.log_destroy(&input_log)
	log_players := card(input_log.ticks[0].present) if len(input_log.ticks) > 0 else 0
	if !testing.expectf(
		t,
		input_log.seed == reference.seed &&
		len(input_log.ticks) == int(reference.ticks) &&
		log_players == reference.players,
		"%s: ref.log is seed %d, %d ticks, %d players",
		what,
		input_log.seed,
		len(input_log.ticks),
		log_players,
	) {
		return
	}
	want, want_ok := read_ref_trace(t, what, reference)
	defer headless.trace_destroy(&want)
	if !want_ok {
		return
	}
	got: headless.Trace
	defer headless.trace_destroy(&got)
	if _, replay_ok := headless.run_replay(&runs, &input_log, &got);
	   !testing.expectf(t, replay_ok, "%s: ref.log does not replay", what) {
		return
	}
	if tick, got_checksum, want_checksum, wrong := first_wrong_tick(&got, &want); wrong {
		testing.expectf(
			t,
			false,
			"%s: the replay differs from ref.trace first at tick %d: %016x vs %016x",
			what,
			tick,
			got_checksum,
			want_checksum,
		)
	}
}

@(private)
check_resume :: proc(t: ^testing.T, suite: ^Suite($G)) {
	runs := headless_of(suite)
	reference := suite.ref
	what := fmt.tprintf("reference_resumes (%s)", ref_params(reference))
	if !testing.expectf(
		t,
		reference.snapshot_tick > 0 && reference.snapshot_tick < reference.ticks,
		"%s: no snapshot tick",
		what,
	) {
		return
	}
	snapshot_path := ref_path(reference, fmt.tprintf("ref-%d.snap", reference.snapshot_tick))
	data, err := os.read_entire_file(snapshot_path, context.allocator)
	if !testing.expectf(t, err == nil, "%s: cannot read %s", what, snapshot_path) {
		return
	}
	defer delete(data)
	want, want_ok := read_ref_trace(t, what, reference)
	defer headless.trace_destroy(&want)
	if !want_ok {
		return
	}
	got: headless.Trace
	defer headless.trace_destroy(&got)
	resumed := reference.ticks - reference.snapshot_tick
	result, ok := headless.run_resume(&runs, data, resumed, reference.players, &got)
	if !testing.expectf(
		t,
		ok && result.final_tick == reference.ticks,
		"%s: the snapshot does not resume to tick %d",
		what,
		reference.ticks,
	) {
		return
	}
	if tick, got_checksum, want_checksum, wrong := first_wrong_tick(&got, &want); wrong {
		testing.expectf(
			t,
			false,
			"%s: the resume differs from ref.trace first at tick %d: %016x vs %016x",
			what,
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

@(private)
ref_path :: proc(reference: Reference, name: string) -> string {
	return strings.concatenate({reference.dir, "/", name}, context.temp_allocator)
}

@(private)
read_ref_trace :: proc(t: ^testing.T, what: string, reference: Reference) -> (trace: headless.Trace, ok: bool) {
	trace, ok = headless.trace_read(ref_path(reference, "ref.trace"))
	ok = testing.expectf(t, ok, "%s: cannot read ref.trace in %s", what, reference.dir)
	ok &&= testing.expectf(
		t,
		trace.first == 1 && len(trace.sums) == int(reference.ticks),
		"%s: ref.trace covers ticks %d..%d",
		what,
		trace.first,
		int(trace.first) + len(trace.sums) - 1,
	)
	return
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
	profile: Profile,
	late_player := -1,
	late_tick: u32 = 0,
) -> headless.Session_Result(G) {
	runs := headless_of(suite)
	network, ok := netcode.profile_by_name(PROFILE_NAMES[profile])
	assert(ok)
	return headless.session_run(&runs, {
		clients     = clients,
		transport   = "loopback",
		virtual     = true,
		profile     = network,
		ticks       = suite.ticks,
		seed        = suite.seed,
		late_player = late_player,
		late_tick   = late_tick,
	})
}

// A session's results agree: no desyncs; every client verified every tick; the starting clients'
// checksums cover every 16th tick and are equal; a late joiner's are contiguous from its first one
// (at or after its join tick) and equal the others'; rollbacks happened if `need_rollbacks`.
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

// Writes a new reference run into suite.ref.dir: ref.log and ref.trace from run_sim, the snapshot from
// run_snapshot, and ref.json (where, when and how it was made). A run that reproduces the committed one byte for byte
// leaves ref.json alone too, so the directory shows no change (`uni record-reference` says "nothing changed").
@(private)
regenerate :: proc(t: ^testing.T, suite: ^Suite($G)) -> bool {
	runs := headless_of(suite)
	reference := suite.ref
	if !testing.expectf(
		t,
		reference.snapshot_tick > 0 && reference.snapshot_tick < reference.ticks,
		"regen: no snapshot tick",
	) {
		return false
	}
	os.make_directory(reference.dir)
	trace: headless.Trace
	defer headless.trace_destroy(&trace)
	input_log: sim.Input_Log(G)
	defer sim.log_destroy(&input_log)
	result := headless.run_sim(&runs, reference.ticks, reference.seed, reference.players, &trace, &input_log)
	snapshot, _ := headless.run_snapshot(&runs, reference.snapshot_tick, reference.seed, reference.players)
	defer delete(snapshot)
	snapshot_path := ref_path(reference, fmt.tprintf("ref-%d.snap", reference.snapshot_tick))
	files := [3]string{ref_path(reference, "ref.trace"), ref_path(reference, "ref.log"), snapshot_path}
	before: [3]string
	for file, i in files {
		before[i] = read_or_empty(file)
	}
	ok := headless.trace_write(&trace, files[0])
	ok &&= sim.log_write(files[1], &input_log)
	ok &&= os.write_entire_file(files[2], snapshot) == nil
	reproduced := ok && os.is_file(ref_path(reference, "ref.json"))
	for file, i in files {
		reproduced &&= before[i] != "" && read_or_empty(file) == before[i]
	}
	if !reproduced {
		meta := ref_json(reference, result.final_checksum)
		ok &&= os.write_entire_file(ref_path(reference, "ref.json"), transmute([]u8)meta) == nil
	}
	regen_note(
		fmt.tprintf(
			"regen: %s %s (final checksum %016x)",
			reproduced ? "reproduced the reference run in" : "wrote a reference run into",
			reference.dir,
			result.final_checksum,
		),
	)
	return testing.expectf(t, ok, "regen: cannot write the reference run into %s", reference.dir)
}

// Not generic, so always type-checked: the imports they use count as used in a build without
// UNIFIED_REGEN too.
@(private)
regen_note :: proc(message: string) {
	log.info(message)
}

// A file's bytes ("" when it can't be read; temp-allocated).
@(private)
read_or_empty :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : ""
}

// ref.json: where, when and how a reference run was made, and its parameters (temp-allocated).
@(private)
ref_json :: proc(reference: Reference, final_checksum: u64) -> string {
	made, _ := time.time_to_rfc3339(time.now(), include_nanos = false, allocator = context.temp_allocator)
	build := strings.to_lower(fmt.tprintf("-o:%v", ODIN_OPTIMIZATION_MODE), context.temp_allocator)
	when ODIN_USE_SEPARATE_MODULES {build = strings.concatenate(
			{build, " -use-separate-modules"},
			context.temp_allocator,
		)}
	when ODIN_DEBUG {build = strings.concatenate({build, " -debug"}, context.temp_allocator)}
	when ODIN_NO_BOUNDS_CHECK {build = strings.concatenate({build, " -no-bounds-check"}, context.temp_allocator)}
	return fmt.tprintf(
		`{{
  "made_on": {{"os": "%v", "arch": "%v", "odin": "%s (%s)", "build": "%s", "commit": "%s"}},
  "made_at": "%s",
  "seed": %d,
  "players": %d,
  "ticks": %d,
  "snapshot_tick": %d,
  "final_checksum": "%016x"
}}
`,
		ODIN_OS,
		ODIN_ARCH,
		ODIN_VERSION,
		ODIN_VERSION_HASH,
		build,
		UNIFIED_REGEN_COMMIT,
		made,
		reference.seed,
		reference.players,
		reference.ticks,
		reference.snapshot_tick,
		final_checksum,
	)
}
