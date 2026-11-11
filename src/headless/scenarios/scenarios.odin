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

// A game's suite: its headless descriptor and the parameters of its runs.
Suite :: struct($S, $I, $W: typeid, $P: int) {
	h:       ^headless.Headless(S, I, W, P),
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
rollback_every_tick :: proc(t: ^testing.T, s: ^Suite($S, $I, $W, $P), window: u32 = 8) {
	r := headless.run_synctest(s.h, s.ticks, window, s.seed, s.players)
	testing.expectf(
		t,
		r.mismatches == 0,
		"rollback_every_tick (window %d; %s): %d mismatches; first: tick %d re-simulated differently at tick %d",
		window,
		params(s),
		r.mismatches,
		r.first_tick,
		r.first_at,
	)
	testing.expectf(
		t,
		s.ticks < window || r.resimulated > 0,
		"rollback_every_tick (%s): nothing re-simulated",
		params(s),
	)
}

// Two scripted runs with the same parameters have identical traces.
runs_match :: proc(t: ^testing.T, s: ^Suite($S, $I, $W, $P)) {
	a, b: headless.Trace
	defer headless.trace_destroy(&a)
	defer headless.trace_destroy(&b)
	headless.run_sim(s.h, s.ticks, s.seed, s.players, &a)
	headless.run_sim(s.h, s.ticks, s.seed, s.players, &b)
	if tick, x, y, wrong := first_wrong_tick(&b, &a); wrong {
		testing.expectf(
			t,
			false,
			"runs_match (%s): the two runs differ first at tick %d: %016x vs %016x",
			params(s),
			tick,
			x,
			y,
		)
	}
}

// A session on the virtual clock: no desyncs, every client reaches `ticks` and verifies the same
// checksums, and rollbacks happen unless the network is ideal.
session_agrees :: proc(t: ^testing.T, s: ^Suite($S, $I, $W, $P), clients: int, profile: Profile) {
	what := fmt.tprintf("session_agrees (%d clients, %s network; %s)", clients, PROFILE_NAMES[profile], params(s))
	res := session(s, clients, profile)
	defer headless.session_result_destroy(&res)
	check_session(t, what, s, &res, profile != .Ideal)
}

// A session's official input log (the relay's) replays offline to every checksum each client
// verified.
session_log_replays :: proc(t: ^testing.T, s: ^Suite($S, $I, $W, $P), clients: int, profile: Profile) {
	what := fmt.tprintf("session_log_replays (%d clients, %s network; %s)", clients, PROFILE_NAMES[profile], params(s))
	res := session(s, clients, profile)
	defer headless.session_result_destroy(&res)
	if !testing.expectf(t, res.ok, "%s: the session did not complete", what) ||
	   !testing.expectf(t, len(res.log.ticks) == int(s.ticks), "%s: the log has %d ticks", what, len(res.log.ticks)) {
		return
	}
	tr: headless.Trace
	defer headless.trace_destroy(&tr)
	if _, ok := headless.run_replay(s.h, &res.log, &tr); !testing.expectf(t, ok, "%s: the log does not replay", what) {
		return
	}
	for c in res.clients {
		for e in c.checksums {
			got, _ := headless.trace_at(&tr, u32(e[0]))
			if got != e[1] {
				testing.expectf(
					t,
					false,
					"%s: the replay differs from client %d first at tick %d: %016x vs verified %016x",
					what,
					c.player,
					e[0],
					got,
					e[1],
				)
				break
			}
		}
	}
}

// A session of `s.players` clients in which `player` joins at `tick` (from a snapshot handed over
// through the relay): no desyncs, and the joiner's checksums match the others' from its first
// verified tick on.
late_join_agrees :: proc(t: ^testing.T, s: ^Suite($S, $I, $W, $P), profile: Profile, player: int, tick: u32) {
	what := fmt.tprintf(
		"late_join_agrees (player %d at tick %d, %s network; %s)",
		player,
		tick,
		PROFILE_NAMES[profile],
		params(s),
	)
	if !testing.expectf(
		t,
		player >= 1 && player < s.players && tick >= 2 && tick <= s.ticks,
		"%s: needs 1 <= player < players and 2 <= tick <= ticks",
		what,
	) {
		return
	}
	res := session(s, s.players, profile, player, tick)
	defer headless.session_result_destroy(&res)
	check_session(t, what, s, &res, false, player, tick)
}

// The replay of the committed ref.log reproduces ref.trace. With UNIFIED_REGEN it first writes a
// new reference run (and also checks its resume).
reference_replays :: proc(t: ^testing.T, s: ^Suite($S, $I, $W, $P)) {
	when UNIFIED_REGEN {
		if regenerate(t, s) {
			check_replay(t, s)
			check_resume(t, s)
		}
	} else {
		check_replay(t, s)
	}
}

// Resuming the committed snapshot reproduces the rest of ref.trace.
reference_resumes :: proc(t: ^testing.T, s: ^Suite($S, $I, $W, $P)) {
	when UNIFIED_REGEN {
		regen_note("reference_resumes: skipped while regenerating (reference_replays checks the new snapshot)")
	} else {
		check_resume(t, s)
	}
}

@(private)
check_replay :: proc(t: ^testing.T, s: ^Suite($S, $I, $W, $P)) {
	r := s.ref
	what := fmt.tprintf("reference_replays (%s)", ref_params(r))
	lg, ok := sim.log_read(ref_path(r, "ref.log"), I, P)
	if !testing.expectf(t, ok, "%s: cannot read %s", what, ref_path(r, "ref.log")) {
		return
	}
	defer sim.log_destroy(&lg)
	if !testing.expectf(
		t,
		lg.seed == r.seed && len(lg.ticks) == int(r.ticks) && card(lg.ticks[0].present) == r.players,
		"%s: ref.log is seed %d, %d ticks, %d players",
		what,
		lg.seed,
		len(lg.ticks),
		card(lg.ticks[0].present) if len(lg.ticks) > 0 else 0,
	) {
		return
	}
	want, wok := read_ref_trace(t, what, r)
	defer headless.trace_destroy(&want)
	if !wok {
		return
	}
	got: headless.Trace
	defer headless.trace_destroy(&got)
	if _, rok := headless.run_replay(s.h, &lg, &got); !testing.expectf(t, rok, "%s: ref.log does not replay", what) {
		return
	}
	if tick, x, y, wrong := first_wrong_tick(&got, &want); wrong {
		testing.expectf(
			t,
			false,
			"%s: the replay differs from ref.trace first at tick %d: %016x vs %016x",
			what,
			tick,
			x,
			y,
		)
	}
}

@(private)
check_resume :: proc(t: ^testing.T, s: ^Suite($S, $I, $W, $P)) {
	r := s.ref
	what := fmt.tprintf("reference_resumes (%s)", ref_params(r))
	if !testing.expectf(t, r.snapshot_tick > 0 && r.snapshot_tick < r.ticks, "%s: no snapshot tick", what) {
		return
	}
	snap := ref_path(r, fmt.tprintf("ref-%d.snap", r.snapshot_tick))
	data, err := os.read_entire_file(snap, context.allocator)
	if !testing.expectf(t, err == nil, "%s: cannot read %s", what, snap) {
		return
	}
	defer delete(data)
	want, wok := read_ref_trace(t, what, r)
	defer headless.trace_destroy(&want)
	if !wok {
		return
	}
	got: headless.Trace
	defer headless.trace_destroy(&got)
	res, ok := headless.run_resume(s.h, data, r.ticks - r.snapshot_tick, r.players, &got)
	if !testing.expectf(
		t,
		ok && res.final_tick == r.ticks,
		"%s: the snapshot does not resume to tick %d",
		what,
		r.ticks,
	) {
		return
	}
	if tick, x, y, wrong := first_wrong_tick(&got, &want); wrong {
		testing.expectf(
			t,
			false,
			"%s: the resume differs from ref.trace first at tick %d: %016x vs %016x",
			what,
			tick,
			x,
			y,
		)
	}
}

// --- helpers ---------------------------------------------------------------------------------------

@(private)
params :: proc(s: ^Suite($S, $I, $W, $P)) -> string {
	return fmt.tprintf("%d players, seed %d, %d ticks", s.players, s.seed, s.ticks)
}

@(private)
ref_params :: proc(r: Reference) -> string {
	return fmt.tprintf("%d players, seed %d, %d ticks, snapshot at %d", r.players, r.seed, r.ticks, r.snapshot_tick)
}

@(private)
ref_path :: proc(r: Reference, name: string) -> string {
	return strings.concatenate({r.dir, "/", name}, context.temp_allocator)
}

@(private)
read_ref_trace :: proc(t: ^testing.T, what: string, r: Reference) -> (tr: headless.Trace, ok: bool) {
	tr, ok = headless.trace_read(ref_path(r, "ref.trace"))
	ok = testing.expectf(t, ok, "%s: cannot read ref.trace in %s", what, r.dir)
	ok &&= testing.expectf(
		t,
		tr.first == 1 && len(tr.sums) == int(r.ticks),
		"%s: ref.trace covers ticks %d..%d",
		what,
		tr.first,
		int(tr.first) + len(tr.sums) - 1,
	)
	return
}

// The first tick of `got` whose checksum isn't `want`'s for that tick (one `want` lacks counts).
@(private)
first_wrong_tick :: proc(got, want: ^headless.Trace) -> (tick: u32, g, w: u64, wrong: bool) {
	for c, i in got.sums {
		tick = got.first + u32(i)
		wc, has := headless.trace_at(want, tick)
		if !has || wc != c {
			return tick, c, wc, true
		}
	}
	return 0, 0, 0, false
}

@(private)
session :: proc(
	s: ^Suite($S, $I, $W, $P),
	clients: int,
	profile: Profile,
	late_player := -1,
	late_tick: u32 = 0,
) -> headless.Session_Result(I, P) {
	np, ok := netcode.profile_by_name(PROFILE_NAMES[profile])
	assert(ok)
	return headless.session_run(
		s.h,
		{
			clients = clients,
			transport = "loopback",
			virtual = true,
			profile = np,
			ticks = s.ticks,
			seed = s.seed,
			late_player = late_player,
			late_tick = late_tick,
		},
	)
}

// A session's results agree: no desyncs; every client verified every tick; the starting clients'
// checksums cover every 16th tick and are equal; a late joiner's are contiguous from its first one
// (at or after its join tick) and equal the others'; rollbacks happened if `need_rollbacks`.
@(private)
check_session :: proc(
	t: ^testing.T,
	what: string,
	s: ^Suite($S, $I, $W, $P),
	res: ^headless.Session_Result(I, P),
	need_rollbacks: bool,
	joiner := -1,
	join_tick: u32 = 0,
) {
	testing.expectf(t, res.desyncs == 0, "%s: %d desyncs", what, res.desyncs)
	every := int(s.ticks / 16)
	ref := -1
	for c, i in res.clients {
		if !testing.expectf(
			t,
			c.ok && c.final_tick == s.ticks,
			"%s: client %d verified up to tick %d of %d",
			what,
			i,
			c.final_tick,
			s.ticks,
		) {
			continue
		}
		if i == joiner {
			continue
		}
		if !testing.expectf(
			t,
			len(c.checksums) == every && (every == 0 || c.checksums[every - 1][0] == u64(every * 16)),
			"%s: client %d's checksums don't cover every 16th tick (%d of %d)",
			what,
			i,
			len(c.checksums),
			every,
		) {
			continue
		}
		testing.expectf(t, !need_rollbacks || c.rollbacks > 0, "%s: client %d had no rollbacks", what, i)
		if ref < 0 {
			ref = i
			continue
		}
		for e, k in c.checksums {
			r := res.clients[ref].checksums[k]
			if e != r {
				testing.expectf(
					t,
					false,
					"%s: client %d's checksum differs from client %d's first at tick %d: %016x vs %016x",
					what,
					i,
					ref,
					e[0],
					e[1],
					r[1],
				)
				break
			}
		}
	}
	testing.expectf(t, res.ok, "%s: the session did not complete cleanly", what)
	if joiner < 0 || ref < 0 || joiner >= len(res.clients) || !res.clients[joiner].ok {
		return
	}
	cs := res.clients[joiner].checksums
	if !testing.expectf(t, len(cs) > 0, "%s: the joiner verified no checksums", what) {
		return
	}
	first := u32(cs[0][0])
	if !testing.expectf(
		t,
		first >= join_tick && first % 16 == 0 && len(cs) == every - int(first / 16) + 1,
		"%s: the joiner's checksums start at tick %d and are not every 16th tick from there to %d",
		what,
		first,
		s.ticks,
	) {
		return
	}
	for e in cs {
		r := res.clients[ref].checksums[e[0] / 16 - 1]
		if e != r {
			testing.expectf(
				t,
				false,
				"%s: the joiner's checksum differs from client %d's first at tick %d: %016x vs %016x",
				what,
				ref,
				e[0],
				e[1],
				r[1],
			)
			return
		}
	}
}

// Writes a new reference run into s.ref.dir: ref.log and ref.trace from run_sim, the snapshot from
// run_snapshot, and ref.json (where, when and how it was made).
@(private)
regenerate :: proc(t: ^testing.T, s: ^Suite($S, $I, $W, $P)) -> bool {
	r := s.ref
	if !testing.expectf(t, r.snapshot_tick > 0 && r.snapshot_tick < r.ticks, "regen: no snapshot tick") {
		return false
	}
	os.make_directory(r.dir)
	tr: headless.Trace
	defer headless.trace_destroy(&tr)
	lg: sim.Input_Log(I, P)
	defer sim.log_destroy(&lg)
	res := headless.run_sim(s.h, r.ticks, r.seed, r.players, &tr, &lg)
	snap, _ := headless.run_snapshot(s.h, r.snapshot_tick, r.seed, r.players)
	defer delete(snap)
	ok := headless.trace_write(&tr, ref_path(r, "ref.trace"))
	ok &&= sim.log_write(ref_path(r, "ref.log"), &lg)
	ok &&= os.write_entire_file(ref_path(r, fmt.tprintf("ref-%d.snap", r.snapshot_tick)), snap) == nil
	meta := ref_json(r, res.final_checksum)
	ok &&= os.write_entire_file(ref_path(r, "ref.json"), transmute([]u8)meta) == nil
	regen_note(fmt.tprintf("regen: wrote a reference run into %s (final checksum %016x)", r.dir, res.final_checksum))
	return testing.expectf(t, ok, "regen: cannot write the reference run into %s", r.dir)
}

// Not generic, so always type-checked: the imports they use count as used in a build without
// UNIFIED_REGEN too.
@(private)
regen_note :: proc(msg: string) {
	log.info(msg)
}

// ref.json: where, when and how a reference run was made, and its parameters (temp-allocated).
@(private)
ref_json :: proc(r: Reference, final_checksum: u64) -> string {
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
		r.seed,
		r.players,
		r.ticks,
		r.snapshot_tick,
		final_checksum,
	)
}
