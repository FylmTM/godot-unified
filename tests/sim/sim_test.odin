// Fast in-process checks of the harness. The long runs (3600-tick sync-test, replays, sessions,
// cross-platform references) are T1-T9 in tools/check.py.
package test_sim

import "core:testing"

import "unified:game"
import "unified:pod"
import "unified:sim"

@(test)
log_tick_is_plain_data :: proc(t: ^testing.T) {
	testing.expect_value(t, pod.violation(type_info_of(sim.Log_Tick)), "")
}

Scripted :: struct {
	s:       ^sim.Sim,
	scripts: [game.MAX_PLAYERS]game.Script,
}

scripted_make :: proc(seed: u32, players: int) -> (r: Scripted) {
	r.s = sim.create(seed, players)
	for p in 0 ..< game.MAX_PLAYERS {
		r.scripts[p] = game.script_init(seed, p)
	}
	return
}

scripted_run :: proc(r: ^Scripted, ticks: u32) {
	for _ in 0 ..< ticks {
		t := sim.tick(r.s) + 1
		sim.step(r.s, game.script_inputs(&r.scripts, &r.s.state, t, r.s.players))
	}
}

@(test)
synctest_short :: proc(t: ^testing.T) {
	mismatches, resimulated, _ := sim.run_synctest(240, 8, 42, 4)
	testing.expect_value(t, mismatches, 0)
	testing.expect_value(t, resimulated, (240 - 8 + 1) * 8)
}

@(test)
restore_rewinds_state_and_physics :: proc(t: ^testing.T) {
	r := scripted_make(42, 4)
	defer sim.destroy(r.s)
	scripted_run(&r, 30)
	at30 := sim.checksum(r.s)
	scripted_run(&r, 10)
	testing.expect(t, sim.checksum(r.s) != at30)
	testing.expect(t, sim.restore(r.s, 30))
	testing.expect_value(t, sim.tick(r.s), 30)
	testing.expect_value(t, sim.checksum(r.s), at30)
	testing.expect(t, !sim.restore(r.s, 40 - sim.RING)) // overwritten in the ring
}

@(test)
portable_snapshot_round_trip :: proc(t: ^testing.T) {
	a := scripted_make(7, 3)
	defer sim.destroy(a.s)
	scripted_run(&a, 90)
	data := sim.snapshot_encode(a.s, 90)
	defer delete(data)

	b := Scripted {
		s       = sim.from_snapshot(data),
		scripts = a.scripts,
	}
	testing.expect(t, b.s != nil)
	if b.s == nil {
		return
	}
	defer sim.destroy(b.s)
	testing.expect_value(t, sim.tick(b.s), 90)
	testing.expect_value(t, sim.checksum(b.s), sim.checksum(a.s))
	scripted_run(&a, 60)
	scripted_run(&b, 60)
	testing.expect_value(t, sim.checksum(b.s), sim.checksum(a.s))

	data[len(data) - 1] ~= 1 // payload digest must catch corruption
	testing.expect(t, sim.from_snapshot(data) == nil)
}
