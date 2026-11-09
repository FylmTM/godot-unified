// spec/friendslop.md: scenarios on the real level (the committed export of game/levels/park.tscn), each
// driven by a director that reads the World and records its inputs, while every tick is sync-tested
// (restore 8 ticks back, re-simulate with the recorded inputs, compare checksums). So platforms, carries,
// two-person lifts, throws, hits, held friends and pads are all checked for determinism under rollback.
package test_friendslop

import "core:testing"

import fs "../../games/friendslop/simulation/friendslop"
import "unified:dmath"
import "unified:physics"
import "unified:sim"

PARK :: #load("../../games/friendslop/game/levels/park.level")
WINDOW :: 8

Run :: struct {
	s:          ^fs.Sim,
	recorded:   [dynamic]fs.Inputs, // recorded[t] = the inputs of tick t
	forward:    [dynamic]u64,
	mismatches: int,
	counts:     [fs.Event_Kind]int, // events of the forward ticks
	present:    sim.Players,
}

start :: proc(players: int) -> Run {
	r := Run {
		s = sim.create(&fs.GAME, 1, PARK),
	}
	append(&r.recorded, fs.Inputs{})
	append(&r.forward, 0)
	for p in 0 ..< players do r.present += {p}
	return r
}

finish :: proc(r: ^Run) {
	sim.destroy(r.s)
	delete(r.recorded)
	delete(r.forward)
}

// One forward tick with these inputs, then the sync-test check of the last WINDOW ticks.
step :: proc(r: ^Run, ins: [fs.MAX_PLAYERS]fs.Input) {
	in_ := fs.Inputs {
		present = r.present,
		input   = ins,
	}
	append(&r.recorded, in_)
	sim.step(r.s, &in_)
	t := r.s.tick
	append(&r.forward, sim.checksum(r.s))
	for e in sim.events_at(r.s, t) do r.counts[fs.Event_Kind(e.kind)] += 1
	if t < WINDOW do return
	if !sim.restore(r.s, t - WINDOW) || !physics.check_refs(r.s.world.phys, &r.s.state) {
		r.mismatches += 1
		return
	}
	for u in t - WINDOW + 1 ..= t {
		sim.step(r.s, &r.recorded[u])
		if sim.checksum(r.s) != r.forward[u] do r.mismatches += 1
	}
}

pos :: proc(r: ^Run, p: int) -> [3]f32 {
	return physics.position(r.s.world.phys, r.s.state.players[p].mover.body)
}

item_pos :: proc(r: ^Run, i: int) -> [3]f32 {
	return physics.position(r.s.world.phys, r.s.state.items[i].body)
}

// The first item of a kind, in level order.
item_of :: proc(r: ^Run, kind: fs.Item_Kind, nth := 0) -> int {
	n := 0
	for i in 0 ..< r.s.world.n_items {
		if r.s.world.items[i].kind == kind {
			if n == nth do return i
			n += 1
		}
	}
	return -1
}

i8_of :: proc(x: f32) -> i8 {
	return i8(clamp(x * 127, -127, 127))
}

// Walks player p towards `target` (stops within `near`), looking at `look` (default: the target).
walk :: proc(r: ^Run, p: int, target: [3]f32, near: f32 = 0.3, look: Maybe([3]f32) = nil) -> fs.Input {
	at := pos(r, p)
	d := [2]f32{target.x - at.x, target.z - at.z}
	in_: fs.Input
	if dmath.length2(d) > near {
		m := dmath.normalize2(d)
		in_.move_x = i8_of(m.x)
		in_.move_z = i8_of(m.y)
	}
	return aim_at(r, p, look.? or_else target, in_)
}

aim_at :: proc(r: ^Run, p: int, target: [3]f32, in_: fs.Input) -> fs.Input {
	in_ := in_
	a := dmath.normalize3(target - (pos(r, p) + {0, fs.HOLD_UP, 0}))
	in_.aim_x = i8_of(a.x)
	in_.aim_y = i8_of(a.y)
	in_.aim_z = i8_of(a.z)
	return in_
}

idle :: proc(r: ^Run, ticks: int) {
	for _ in 0 ..< ticks do step(r, {})
}

expect_clean :: proc(t: ^testing.T, r: ^Run) {
	testing.expectf(t, r.mismatches == 0, "%d sync-test mismatches", r.mismatches)
}

@(test)
level_loads :: proc(t: ^testing.T) {
	r := start(1)
	defer finish(&r)
	w := r.s.world
	testing.expect(t, w.n_items >= 8)
	testing.expect(t, w.n_platforms >= 2)
	testing.expect(t, w.n_pads >= 1)
	testing.expect(t, item_of(&r, .Heavy) >= 0)
	idle(&r, 64)
	// Players stand on the floor: centre at FEET above it.
	testing.expectf(t, abs(pos(&r, 0).y - fs.FEET) < 0.05, "standing at %v", pos(&r, 0))
	testing.expect(t, physics.mover_grounded(&r.s.state.players[0].mover))
	expect_clean(t, &r)
}

// Two players lift the heavy crate together; one alone can only drag it.
@(test)
heavy_needs_two :: proc(t: ^testing.T) {
	r := start(2)
	defer finish(&r)
	h := item_of(&r, .Heavy)
	hp := item_pos(&r, h)
	rest_y := hp.y
	sides := [2][3]f32{hp + {-1.7, 0, 0}, hp + {1.7, 0, 0}}
	// Walk to the two ends, face the crate.
	for _ in 0 ..< 160 {
		step(&r, {walk(&r, 0, sides[0], 0.1, hp), walk(&r, 1, sides[1], 0.1, hp), {}, {}})
	}
	// P0 grabs alone and pulls up for 2 s: it stays on the floor.
	step(&r, {aim_at(&r, 0, hp + {0, 1, 0}, {buttons = fs.BUTTON_GRAB}), aim_at(&r, 1, hp, {}), {}, {}})
	testing.expect_value(t, r.s.state.players[0].held_kind, fs.Held_Kind.Item)
	for _ in 0 ..< 128 {
		step(&r, {aim_at(&r, 0, hp + {0, 2, 0}, {}), aim_at(&r, 1, hp, {}), {}, {}})
	}
	alone := item_pos(&r, h).y
	testing.expectf(t, alone < rest_y + 0.25, "one player lifted the heavy crate to %v (rest %v)", alone, rest_y)
	// P1 takes the other handle: together it rises.
	step(&r, {aim_at(&r, 0, hp + {0, 2, 0}, {}), aim_at(&r, 1, item_pos(&r, h), {buttons = fs.BUTTON_GRAB}), {}, {}})
	testing.expect_value(t, r.s.state.players[1].held_kind, fs.Held_Kind.Item)
	if r.s.state.players[1].held_kind == .Item {
		testing.expect(t, r.s.state.players[1].handle != r.s.state.players[0].handle)
	}
	peak: f32 = 0
	for _ in 0 ..< 128 {
		step(&r, {aim_at(&r, 0, hp + {0, 2, 0}, {}), aim_at(&r, 1, hp + {0, 2, 0}, {}), {}, {}})
		peak = max(peak, item_pos(&r, h).y)
	}
	testing.expectf(t, peak > rest_y + 0.4, "two players lifted it only to %v (rest %v)", peak, rest_y)
	// Carry it together for 2 s along -z.
	z0 := item_pos(&r, h).z
	for _ in 0 ..< 128 {
		step(&r, {{move_z = -127, aim_x = 100, aim_y = 40}, {move_z = -127, aim_x = -100, aim_y = 40}, {}, {}})
	}
	testing.expectf(t, z0 - item_pos(&r, h).z > 3, "carried only %v m", z0 - item_pos(&r, h).z)
	expect_clean(t, &r)
}

// A charged throw of a crate at a friend knocks them over; they get up again.
@(test)
throw_hits_friend :: proc(t: ^testing.T) {
	r := start(2)
	defer finish(&r)
	c := item_of(&r, .Crate)
	cp := item_pos(&r, c)
	stand := cp + {-1.3, 0, 0}
	friend := cp + {-1.3, 0, -5}
	for _ in 0 ..< 200 {
		step(&r, {walk(&r, 0, stand, 0.1, cp), walk(&r, 1, friend, 0.1), {}, {}})
	}
	step(&r, {aim_at(&r, 0, item_pos(&r, c), {buttons = fs.BUTTON_GRAB}), {}, {}, {}})
	testing.expect_value(t, r.s.state.players[0].held_kind, fs.Held_Kind.Item)
	for _ in 0 ..< 40 do step(&r, {aim_at(&r, 0, pos(&r, 1) + {0, 0.6, 0}, {buttons = fs.BUTTON_THROW}), {}, {}, {}})
	step(&r, {aim_at(&r, 0, pos(&r, 1) + {0, 0.6, 0}, {}), {}, {}, {}}) // release: throw
	testing.expect_value(t, r.counts[.Thrown], 1)
	stunned := false
	for _ in 0 ..< 96 {
		step(&r, {})
		stunned ||= r.s.state.players[1].stun > 0
	}
	testing.expect(t, stunned)
	testing.expectf(t, r.counts[.Hit] >= 1, "no hit (thrown %d)", r.counts[.Thrown])
	idle(&r, 96)
	testing.expect_value(t, r.s.state.players[1].stun, 0)
	testing.expect(t, .Limp not_in r.s.state.players[1].mover.flags)
	expect_clean(t, &r)
}

// Ride the lift up and step off onto the ledge; ride the ferry sideways.
@(test)
platforms_carry_players :: proc(t: ^testing.T) {
	r := start(2)
	defer finish(&r)
	w := r.s.world
	lift, ferry := -1, -1
	for i in 0 ..< w.n_platforms {
		d := &w.platforms[i]
		if d.path.points[1].y > d.path.points[0].y + 1 do lift = i
		else do ferry = i
	}
	testing.expect(t, lift >= 0 && ferry >= 0)
	if lift < 0 || ferry < 0 do return
	lift_at := w.platforms[lift].origin
	ferry_at := w.platforms[ferry].origin
	// Wait at the bottom: the lift comes back down every cycle.
	cycle := int(physics.path_duration_ticks(&w.platforms[lift].path, fs.TICK_HZ))
	on_lift := false
	top: f32 = 0
	for i in 0 ..< 2 * cycle {
		lp := physics.position(w.phys, r.s.state.platforms[lift].body)
		target := lp.y < lift_at.y + 0.1 || on_lift ? lift_at : lift_at + {-3, 0, 0}
		step(&r, {walk(&r, 0, target, 0.1), walk(&r, 1, ferry_at, 0.1), {}, {}})
		if abs(pos(&r, 0).x - lift_at.x) < 0.5 && abs(pos(&r, 0).z - lift_at.z) < 0.5 do on_lift = true
		if on_lift do top = max(top, pos(&r, 0).y)
		_ = i
	}
	testing.expectf(t, on_lift && top > lift_at.y + 2.5, "rode the lift to %v", top)
	// P1 stood on the ferry: it moved P1 along x by most of the ferry's 8 m.
	xs: [2]f32 = {1e9, -1e9}
	for _ in 0 ..< cycle {
		step(&r, {{}, {}, {}, {}})
		xs = {min(xs[0], pos(&r, 1).x), max(xs[1], pos(&r, 1).x)}
	}
	testing.expectf(t, xs[1] - xs[0] > 6, "the ferry moved its rider only %v m", xs[1] - xs[0])
	expect_clean(t, &r)
}

// The jump pad launches a player onto the high ledge.
@(test)
pad_launches_player :: proc(t: ^testing.T) {
	r := start(1)
	defer finish(&r)
	pad := r.s.world.pads[0].vol.pos
	peak: f32 = 0
	for _ in 0 ..< 200 {
		step(&r, {walk(&r, 0, pad, 0.05), {}, {}, {}})
		peak = max(peak, pos(&r, 0).y)
		if r.counts[.Launched] > 0 do break
	}
	testing.expect(t, r.counts[.Launched] >= 1)
	for _ in 0 ..< 160 {
		step(&r, {})
		peak = max(peak, pos(&r, 0).y)
	}
	testing.expectf(t, peak > 5, "launched only to %v", peak)
	testing.expectf(t, pos(&r, 0).y > 5, "did not land on the high ledge: %v", pos(&r, 0))
	expect_clean(t, &r)
}

// Grab a friend, carry them, they mash jump and break free; grab again and throw them.
@(test)
hold_and_throw_friend :: proc(t: ^testing.T) {
	r := start(2)
	defer finish(&r)
	idle(&r, 32)
	for _ in 0 ..< 64 do step(&r, {walk(&r, 0, pos(&r, 1) + {-1.2, 0, 0}, 0.1, pos(&r, 1)), {}, {}, {}})
	step(&r, {aim_at(&r, 0, pos(&r, 1), {buttons = fs.BUTTON_GRAB}), {}, {}, {}})
	testing.expect_value(t, r.s.state.players[0].held_kind, fs.Held_Kind.Player)
	testing.expect_value(t, r.s.state.players[1].held_by, 1)
	y0 := pos(&r, 1).y
	for _ in 0 ..< 48 do step(&r, {aim_at(&r, 0, pos(&r, 0) + {0, 0.3, 2}, {}), {}, {}, {}})
	testing.expectf(t, pos(&r, 1).y > y0 + 0.2, "the friend wasn't lifted: %v -> %v", y0, pos(&r, 1).y)
	// Mash jump: 3 presses.
	for k in 0 ..< 12 {
		step(&r, {aim_at(&r, 0, pos(&r, 0) + {0, 0.3, 2}, {}), {buttons = k % 2 == 0 ? fs.BUTTON_JUMP : 0}, {}, {}})
	}
	testing.expect_value(t, r.counts[.Broke_Free], 1)
	testing.expect_value(t, r.s.state.players[1].held_by, 0)
	idle(&r, 96)
	// Grab again and throw.
	for _ in 0 ..< 96 do step(&r, {walk(&r, 0, pos(&r, 1) + {-1.2, 0, 0}, 0.1, pos(&r, 1)), {}, {}, {}})
	step(&r, {aim_at(&r, 0, pos(&r, 1), {buttons = fs.BUTTON_GRAB}), {}, {}, {}})
	testing.expect_value(t, r.s.state.players[0].held_kind, fs.Held_Kind.Player)
	for _ in 0 ..< 8 do step(&r, {{aim_x = 0, aim_y = 40, aim_z = 100, buttons = fs.BUTTON_THROW}, {}, {}, {}})
	step(&r, {{aim_x = 0, aim_y = 40, aim_z = 100}, {}, {}, {}})
	testing.expect_value(t, r.counts[.Thrown], 1)
	testing.expect(t, r.s.state.players[1].thrown)
	idle(&r, 160)
	testing.expect(t, !r.s.state.players[1].thrown)
	testing.expectf(
		t,
		physics.mover_grounded(&r.s.state.players[1].mover),
		"not back on its feet: %v at %v",
		r.s.state.players[1].mover.flags,
		pos(&r, 1),
	)
	testing.expect_value(t, r.counts[.Fell], 0)
	expect_clean(t, &r)
}

// Four chaos players for 20 s (the CLI's scripted input): everything at once, still deterministic.
@(test)
chaos_synctest :: proc(t: ^testing.T) {
	r := start(4)
	defer finish(&r)
	for tk in u32(1) ..= 1280 {
		ins: [fs.MAX_PLAYERS]fs.Input
		for p in 0 ..< 4 do ins[p] = fs.script_input(7, p, tk)
		step(&r, ins)
	}
	testing.expect(t, r.counts[.Grabbed] > 0)
	expect_clean(t, &r)
}
