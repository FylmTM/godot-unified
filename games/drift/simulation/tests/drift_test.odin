// games/drift/SPEC.md: scenarios on the real arena (the committed export of game/levels/arena.tscn) while every
// tick is sync-tested (restore 8 ticks back, re-simulate with the recorded inputs and commands, compare
// checksums). So splits, warps, the station falling and the reset are all checked for determinism under
// rollback, and every body stays exactly on the plane.
package test_drift

import "core:testing"

import dr "../drift"
import b3 "unified:box3d_port"
import "unified:physics"
import "unified:sim"

WINDOW :: 8

Cmd :: enum {
	None,
	Start,
	Restart,
}

Run :: struct {
	s:          ^dr.Sim,
	recorded:   [dynamic]dr.Inputs, // recorded[t] = the inputs of tick t
	forward:    [dynamic]u64,
	mismatches: int,
	off_plane:  int, // bodies seen off the plane (z, or a rotation not about Z)
	counts:     [dr.Event_Kind]int, // events of the forward ticks
	present:    sim.Players,
	floor:      u32, // the sync-test never restores before this tick (a setup changed it)
}

start :: proc(players: int) -> Run {
	r := Run {
		s = sim.create(&dr.GAME, 1, ARENA),
	}
	append(&r.recorded, dr.Inputs{})
	append(&r.forward, 0)
	for p in 0 ..< players do r.present += {p}
	step(&r, {}) // ships join on the first tick
	return r
}

finish :: proc(r: ^Run) {
	sim.destroy(r.s)
	delete(r.recorded)
	delete(r.forward)
}

// One forward tick with these inputs (and slot 0's command, when given), then the sync-test of the last WINDOW
// ticks and the plane check.
step :: proc(r: ^Run, ins: [dr.MAX_PLAYERS]dr.Input, cmd := Cmd.None) {
	in_ := dr.Inputs {
		present = r.present,
		input   = ins,
	}
	switch cmd {
	case .None:
	case .Start:
		push(&in_, dr.Cmd_Start{})
	case .Restart:
		push(&in_, dr.Cmd_Restart{})
	}
	append(&r.recorded, in_)
	sim.step(r.s, &in_)
	t := r.s.tick
	append(&r.forward, sim.checksum(r.s))
	for e in sim.events_at(r.s, t) do r.counts[dr.Event_Kind(e.kind)] += 1
	check_plane(r)
	if t < WINDOW do return
	from := max(t - WINDOW, r.floor)
	if from == t do return
	if !sim.restore(r.s, from) || !physics.check_refs(r.s.world.phys, &r.s.state) {
		r.mismatches += 1
		return
	}
	for u in from + 1 ..= t {
		sim.step(r.s, &r.recorded[u])
		if sim.checksum(r.s) != r.forward[u] do r.mismatches += 1
	}
}

// A setup changed the state or the world at the current tick: save it again, and never restore before it.
setup_done :: proc(r: ^Run) {
	sim.save(r.s)
	r.forward[r.s.tick] = sim.checksum(r.s)
	r.floor = r.s.tick
}

// Slot 0 sends a command this tick.
push :: proc(in_: ^dr.Inputs, v: $T) {
	c, ok := sim.command_make(dr.COMMANDS, v)
	assert(ok && sim.add_command(in_, c))
}

// Every ship and rock: z == 0 and a rotation about Z only, bit-exact (−0 counts as 0).
check_plane :: proc(r: ^Run) {
	w := r.s.world.phys
	s := &r.s.state
	on :: proc(w: ^physics.World, ref: physics.Body_Ref) -> bool {
		id := physics.body_id(w, ref)
		p := b3.Body_GetPosition(id)
		q := b3.Body_GetRotation(id)
		return p.z == 0 && q.v.x == 0 && q.v.y == 0
	}
	for &sh in s.ships do if sh.active && !on(w, sh.body) do r.off_plane += 1
	for i in 0 ..< s.rocks.high_water {
		rk := sim.at(&s.rocks, i) or_continue
		if !on(w, rk.body) do r.off_plane += 1
	}
	if !on(w, s.station) do r.off_plane += 1
}

scripted :: proc(r: ^Run) -> (ins: [dr.MAX_PLAYERS]dr.Input) {
	for p in 0 ..< dr.MAX_PLAYERS do ins[p] = dr.script(7, p, r.s.tick + 1, &r.s.state)
	return
}

@(test)
a_match_stays_on_the_plane :: proc(t: ^testing.T) {
	r := start(4)
	defer finish(&r)
	step(&r, scripted(&r), .Start)
	testing.expect_value(t, r.s.state.phase, dr.Phase.Match)
	for _ in 0 ..< 2600 do step(&r, scripted(&r)) // two waves and a half
	testing.expect_value(t, r.mismatches, 0)
	testing.expect_value(t, r.off_plane, 0)
	testing.expect(t, r.counts[.Wave] >= 2, "two waves")
	testing.expect(t, r.counts[.Fired] > 100, "ships fire")
	testing.expect(t, r.counts[.Rock_Hit] > 0, "bullets hit rocks")
	testing.expect(t, r.counts[.Rock_Split] > 0, "rocks split inside rollback windows")
}

@(test)
the_station_falls_and_the_match_resets :: proc(t: ^testing.T) {
	r := start(2)
	defer finish(&r)
	step(&r, {}, .Start)
	for _ in 0 ..< 200 do step(&r, {})
	testing.expect(t, r.s.state.rocks.count > 0, "the first wave's rocks")
	// a setup: one hit left
	r.s.state.station_hp = 1
	setup_done(&r)
	for _ in 0 ..< 64 * 60 {
		step(&r, {})
		if r.s.state.phase == .Over do break
	}
	testing.expect_value(t, r.s.state.phase, dr.Phase.Over)
	testing.expect_value(t, r.counts[.Match_Over], 1)
	step(&r, {}, .Restart)
	testing.expect_value(t, r.s.state.phase, dr.Phase.Lobby)
	testing.expect_value(t, r.s.state.rocks.count, 0)
	testing.expect_value(t, r.s.state.station_hp, dr.STATION_HP)
	for _ in 0 ..< 64 do step(&r, {})
	testing.expect_value(t, r.mismatches, 0)
	testing.expect_value(t, r.off_plane, 0)
}

@(test)
a_ship_warps_through_a_gate :: proc(t: ^testing.T) {
	r := start(1)
	defer finish(&r)
	w := r.s.world
	testing.expect(t, w.n_gates == 2 && w.gates[0].pair == 1 && w.gates[1].pair == 0, "the arena's gate pair")
	// a setup: the ship just short of gate 0, flying into it
	g := w.gates[0].pos
	sh := &r.s.state.ships[0]
	physics.teleport(w.phys, sh.body, {g.x - 1.5, g.y, 0})
	physics.set_velocity_2d(w.phys, sh.body, {6, 0}, 0)
	setup_done(&r)
	for _ in 0 ..< 32 {
		step(&r, {})
		if r.counts[.Warped] > 0 do break
	}
	testing.expect_value(t, r.counts[.Warped], 1)
	pos, _ := physics.pose_2d(w.phys, sh.body)
	to := w.gates[1].pos
	d := pos - to
	testing.expect(t, d.x * d.x + d.y * d.y < 1, "the ship comes out of the other gate")
	vel, _ := physics.velocity_2d(w.phys, sh.body)
	testing.expect(t, vel.x > 3, "it keeps its velocity")
	for _ in 0 ..< 64 do step(&r, {}) // both gates recharge: no warp back
	testing.expect_value(t, r.counts[.Warped], 1)
	testing.expect_value(t, r.mismatches, 0)
}
