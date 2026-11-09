// unified:headless on the toy game, without a process per mode: the offline runs (sim, synctest,
// replay, snapshot/resume) agree with each other through real files, and in-process sessions on the
// virtual clock (the T3/T6 path) finish with every checksum agreeing, a late joiner included.
package test_headless

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
	replay_trace, snap := temp_path("replay.trace"), temp_path("run.snap")
	resume_trace := temp_path("resume.trace")
	defer for p in ([]string{log_path, trace_path, replay_trace, snap, resume_trace}) {
		os.remove(p)
	}
	a, aok := headless.run_sim(&h, 300, 7, 3, trace_path, log_path)
	b, _ := headless.run_sim(&h, 300, 7, 3, "", "")
	testing.expect(t, aok)
	testing.expect_value(t, a.final_checksum, b.final_checksum) // deterministic
	mm, resim, final := headless.run_synctest(&h, 300, 8, 7, 3)
	testing.expect_value(t, mm, 0)
	testing.expect(t, resim > 300)
	testing.expect_value(t, final, a.final_checksum)
	r, rok := headless.run_replay(&h, log_path, replay_trace)
	testing.expect(t, rok)
	testing.expect_value(t, r.final_checksum, a.final_checksum)
	tr1, _ := os.read_entire_file(trace_path, context.temp_allocator)
	tr2, _ := os.read_entire_file(replay_trace, context.temp_allocator)
	testing.expect(t, len(tr1) > 0 && string(tr1) == string(tr2))
	// Snapshot at 200, resume 100 ticks: the same tick 300 as the straight run.
	_, _, sok := headless.run_snapshot(&h, 200, 7, 3, snap)
	testing.expect(t, sok)
	res, resok := headless.run_resume(&h, snap, 100, 3, resume_trace)
	testing.expect(t, resok)
	testing.expect_value(t, res.final_tick, 300)
	testing.expect_value(t, res.final_checksum, a.final_checksum)
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
	defer sim.log_destroy(&res.log)
	defer delete(res.clients)
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
	want := fmt.tprintf(`[640,"%016x"]`, sim.checksum(s))
	for c in res.clients {
		testing.expectf(t, contains(c, want), "a client did not verify %s: %s", want, c)
	}
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
	defer sim.log_destroy(&a.log)
	defer delete(a.clients)
	b := headless.session_run(&h, cfg)
	defer sim.log_destroy(&b.log)
	defer delete(b.clients)
	testing.expect(t, a.ok && b.ok)
	testing.expect_value(t, a.clients[0], b.clients[0])
	testing.expect_value(t, a.relay_net, b.relay_net)
}

contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) {
		if s[i:i + len(sub)] == sub {
			return true
		}
	}
	return false
}

// Never called: instantiates every mode for the toy game, so the whole generic package type-checks
// here (and its imports count as used) just as it does in a game's binary.
@(private)
instantiate_all_modes :: proc() {
	h := HEADLESS
	headless.run(&h)
}
