// unified:headless on the toy game, without a process per mode: the offline runs (sim, synctest,
// replay, snapshot/resume) agree with each other, traces and logs round-trip through files, and
// in-process sessions on the virtual clock finish with every checksum agreeing, a late joiner
// included. The standard end-to-end scenarios on the toy are in tests/scenarios.
package test_headless

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

import "../toy"
import "unified:headless"
import "unified:netcode"
import "unified:sim"

H :: headless.Headless(toy.State, toy.Input, toy.World, toy.SLOTS)

HEADLESS := H {
	game = &toy.GAME,
	script = proc(seed: u64, slot: int, t: u32, state: ^toy.State) -> toy.Input {
		return toy.script(seed, slot, t)
	},
}

temp_path :: proc(name: string) -> string {
	dir := os.temp_directory(context.temp_allocator) or_else "."
	p, _ := filepath.join(
		{dir, fmt.tprintf("unified-headless-test-%d-%s", os.get_pid(), name)},
		context.temp_allocator,
	)
	return p
}

@(test)
offline_modes_agree :: proc(t: ^testing.T) {
	h := HEADLESS
	log_path, trace_path := temp_path("run.log"), temp_path("run.trace")
	defer for p in ([]string{log_path, trace_path}) {
		os.remove(p)
	}
	tr, b_tr: headless.Trace
	defer headless.trace_destroy(&tr)
	defer headless.trace_destroy(&b_tr)
	lg: sim.Input_Log(toy.Input, toy.SLOTS)
	defer sim.log_destroy(&lg)
	a := headless.run_sim(&h, 300, 7, 3, &tr, &lg)
	b := headless.run_sim(&h, 300, 7, 3, &b_tr)
	testing.expect_value(t, a.final_checksum, b.final_checksum) // deterministic
	testing.expect(t, tr.first == 1 && len(tr.sums) == 300 && tr.sums[299] == a.final_checksum)
	sync := headless.run_synctest(&h, 300, 8, 7, 3)
	testing.expect_value(t, sync.mismatches, 0)
	testing.expect(t, sync.resimulated > 300)
	testing.expect_value(t, sync.final_checksum, a.final_checksum)
	// Through files: the log and the trace read back as written, and the log replays to the trace.
	testing.expect(t, sim.log_write(log_path, &lg) && headless.trace_write(&tr, trace_path))
	lg2, lok := sim.log_read(log_path, toy.Input, toy.SLOTS)
	defer sim.log_destroy(&lg2)
	testing.expect(t, lok)
	tr2, tok := headless.trace_read(trace_path)
	defer headless.trace_destroy(&tr2)
	testing.expect(t, tok && tr2.first == 1 && slice.equal(tr2.sums[:], tr.sums[:]))
	rt: headless.Trace
	defer headless.trace_destroy(&rt)
	r, rok := headless.run_replay(&h, &lg2, &rt)
	testing.expect(t, rok)
	testing.expect_value(t, r.final_checksum, a.final_checksum)
	testing.expect(t, slice.equal(rt.sums[:], tr.sums[:]))
	// Snapshot at 200, resume 100 ticks: the same ticks 201..300 as the straight run.
	snap, _ := headless.run_snapshot(&h, 200, 7, 3)
	defer delete(snap)
	st: headless.Trace
	defer headless.trace_destroy(&st)
	res, resok := headless.run_resume(&h, snap, 100, 3, &st)
	testing.expect(t, resok)
	testing.expect_value(t, res.final_tick, 300)
	testing.expect_value(t, res.final_checksum, a.final_checksum)
	testing.expect(t, st.first == 201 && slice.equal(st.sums[:], tr.sums[200:]))
	got, has := headless.trace_at(&st, 250)
	testing.expect(t, has && got == tr.sums[249])
	_, has = headless.trace_at(&st, 200)
	testing.expect(t, !has)
}

@(test)
session_on_the_virtual_clock :: proc(t: ^testing.T) {
	h := HEADLESS
	cfg := headless.Session_Config {
		clients     = 3,
		transport   = "loopback",
		virtual     = true,
		profile     = netcode.PROFILES[2], // bad: loss, jitter, reordering
		ticks       = 640,
		seed        = 11,
		late_player = 2,
		late_tick   = 320,
	}
	res := headless.session_run(&h, cfg)
	defer headless.session_result_destroy(&res)
	testing.expect(t, res.ok)
	testing.expect_value(t, res.desyncs, 0)
	testing.expect_value(t, len(res.clients), 3)
	testing.expect_value(t, len(res.log.ticks), 640)
	// The relay's log replays to every client's last verified checksum (tick 640).
	s := sim.create(&toy.GAME, 11)
	defer sim.destroy(s)
	for &in_ in res.log.ticks {
		sim.step(s, &in_)
	}
	for c, i in res.clients {
		testing.expect_value(t, c.player, i)
		testing.expect_value(t, c.final_tick, 640)
		last := c.checksums[len(c.checksums) - 1] if len(c.checksums) > 0 else {}
		testing.expectf(t, last == {640, sim.checksum(s)}, "client %d's last verified checksum: %v", i, last)
	}
	testing.expect(t, res.clients[2].join_tick >= 320 && res.clients[2].checksums[0][0] >= 320)
	// The JSON the CLI prints is built from these results.
	j := headless.client_json(res.clients[0])
	testing.expect(t, strings.has_prefix(j, `{"player":0,"final_tick":640,"checksums":[[16,"`))
}

// The same session twice on the virtual clock: identical, to the byte.
@(test)
virtual_sessions_repeat :: proc(t: ^testing.T) {
	h := HEADLESS
	cfg := headless.Session_Config {
		clients     = 2,
		transport   = "loopback",
		virtual     = true,
		profile     = netcode.PROFILES[1],
		ticks       = 320,
		seed        = 3,
		late_player = -1,
	}
	a := headless.session_run(&h, cfg)
	defer headless.session_result_destroy(&a)
	b := headless.session_run(&h, cfg)
	defer headless.session_result_destroy(&b)
	testing.expect(t, a.ok && b.ok)
	testing.expect_value(t, headless.client_json(a.clients[0]), headless.client_json(b.clients[0]))
	testing.expect_value(t, a.relay_net, b.relay_net)
}

// Never called: instantiates every mode for the toy game, so the whole generic package type-checks
// here (and its imports count as used) just as it does in a game's binary.
@(private)
instantiate_all_modes :: proc() {
	h := HEADLESS
	headless.run(&h)
}
