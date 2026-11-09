// spec/friendslop.md "The route": each beat's mechanism on the real level, sync-tested every tick. Setups place
// players and items directly (then re-save that tick, so the sync-test never rewinds past a setup).
package test_friendslop

import "core:testing"

import fs "../../games/friendslop/simulation/friendslop"
import "unified:level"
import "unified:physics"
import "unified:sim"

// Applies a setup to the current tick and makes it the tick's saved state.
setup :: proc(r: ^Run, f: proc(r: ^Run)) {
	f(r)
	sim.save(r.s)
	r.forward[r.s.tick] = sim.checksum(r.s)
	r.floor = r.s.tick
}

marker_named :: proc(r: ^Run, name: string) -> ^level.Marker {
	return level.find_named(&r.s.world.lvl, name)
}

item_at_marker :: proc(r: ^Run, name: string) -> int {
	m := marker_named(r, name)
	if m == nil do return -1
	for i in 0 ..< r.s.world.n_items {
		if r.s.world.items[i].marker == m.index do return i
	}
	return -1
}

platform_at_marker :: proc(r: ^Run, name: string) -> int {
	m := marker_named(r, name)
	if m == nil do return -1
	for i in 0 ..< r.s.world.n_platforms {
		if r.s.world.platforms[i].marker == m.index do return i
	}
	return -1
}

trigger_at_marker :: proc(r: ^Run, name: string) -> int {
	m := marker_named(r, name)
	if m == nil do return -1
	for i in 0 ..< r.s.world.n_triggers {
		if r.s.world.triggers[i].marker == m.index do return i
	}
	return -1
}

put_item :: proc(r: ^Run, i: int, p: [3]f32) {
	r.arg_i, r.arg_v = i, p
	setup(r, proc(r: ^Run) {physics.teleport(r.s.world.phys, r.s.state.items[r.arg_i].body, r.arg_v)})
}

put_player :: proc(r: ^Run, p: int, at: [3]f32) {
	r.arg_i, r.arg_v = p, at
	setup(r, proc(r: ^Run) {
		physics.mover_teleport(r.s.world.phys, &r.s.state.players[r.arg_i].mover, r.arg_v)
	})
}

plat_y :: proc(r: ^Run, i: int) -> f32 {
	return physics.position(r.s.world.phys, r.s.state.platforms[i].body).y
}

@(test)
route_start_checkpoint_respawn :: proc(t: ^testing.T) {
	r := start(1)
	defer finish(&r)
	idle(&r, 16)
	// Walk north out of the hub through the start gate.
	for _ in 0 ..< 400 {
		step(&r, {walk(&r, 0, {0, 0, -20}, 0.3), {}, {}, {}})
		if r.s.state.phase == .Run do break
	}
	testing.expect_value(t, r.s.state.phase, fs.Phase.Run)
	testing.expect_value(t, r.counts[.Run_Started], 1)
	// Teleport to checkpoint 3's landing and fall off the side: respawn there.
	c3 := marker_named(&r, "Check3")
	put_player(&r, 0, c3.pos)
	idle(&r, 8)
	testing.expect_value(t, r.s.state.checkpoint, 3)
	for _ in 0 ..< 200 {
		step(&r, {walk(&r, 0, c3.pos + {10, 0, 0}, 0.1), {}, {}, {}})
		if r.counts[.Fell] > 0 do break
	}
	testing.expect_value(t, r.counts[.Fell], 1)
	idle(&r, 120)
	testing.expect_value(t, r.counts[.Respawned], 1)
	p := pos(&r, 0)
	testing.expectf(
		t,
		abs(p.z - c3.pos.z) < 1.5 && abs(p.y - c3.pos.y) < 1.5,
		"respawned at %v, checkpoint %v",
		p,
		c3.pos,
	)
	expect_clean(t, &r)
}

@(test)
route_plate_holds_gate :: proc(t: ^testing.T) {
	r := start(1)
	defer finish(&r)
	gate := platform_at_marker(&r, "PlateGate")
	plate := marker_named(&r, "Plate")
	cube := item_at_marker(&r, "WeightCube")
	testing.expect(t, gate >= 0 && plate != nil && cube >= 0)
	if gate < 0 || plate == nil || cube < 0 do return
	closed := plat_y(&r, gate)
	put_item(&r, cube, plate.pos + {0, 0.6, 0})
	idle(&r, 96)
	testing.expect(t, r.counts[.Plate_On] >= 1)
	testing.expectf(t, plat_y(&r, gate) < closed - 4, "gate at %v (closed %v)", plat_y(&r, gate), closed)
	// Take the cube away: the gate closes again.
	put_item(&r, cube, plate.pos + {3, 0.6, 0})
	idle(&r, 96)
	testing.expect(t, r.counts[.Plate_Off] >= 1)
	testing.expectf(t, abs(plat_y(&r, gate) - closed) < 0.01, "gate didn't close: %v", plat_y(&r, gate))
	expect_clean(t, &r)
}

@(test)
route_bell_bridge :: proc(t: ^testing.T) {
	r := start(1)
	defer finish(&r)
	bridge := platform_at_marker(&r, "Bridge")
	bell := marker_named(&r, "Bell")
	ball := item_at_marker(&r, "Ball1")
	testing.expect(t, bridge >= 0 && bell != nil && ball >= 0)
	if bridge < 0 || bell == nil || ball < 0 do return
	x0 := physics.position(r.s.world.phys, r.s.state.platforms[bridge].body).x
	// A ball flying at the bell.
	r.arg_i, r.arg_v = ball, bell.pos
	setup(&r, proc(r: ^Run) {
		b := r.s.state.items[r.arg_i].body
		physics.teleport(r.s.world.phys, b, r.arg_v + {0, 0, 3})
		physics.set_velocity(r.s.world.phys, b, {0, 0, -9})
	})
	idle(&r, 32)
	testing.expect_value(t, r.counts[.Bell_Rung], 1)
	idle(&r, 160)
	x1 := physics.position(r.s.world.phys, r.s.state.platforms[bridge].body).x
	testing.expectf(t, abs(x1) < 0.01 && x0 > 7, "the bridge went from x %v to %v", x0, x1)
	expect_clean(t, &r)
}

@(test)
route_key_lock_and_scale :: proc(t: ^testing.T) {
	r := start(1)
	defer finish(&r)
	key := item_at_marker(&r, "Key")
	lock := marker_named(&r, "Lock")
	lock_gate := platform_at_marker(&r, "LockGate")
	heavy := item_at_marker(&r, "HeavyCrate")
	scale := marker_named(&r, "Scale")
	scale_gate := platform_at_marker(&r, "ScaleGate")
	testing.expect(t, key >= 0 && lock != nil && lock_gate >= 0 && heavy >= 0 && scale != nil && scale_gate >= 0)
	if key < 0 || lock == nil || lock_gate < 0 || heavy < 0 || scale == nil || scale_gate < 0 do return
	closed := plat_y(&r, scale_gate)
	idle(&r, 2) // players join on the first tick
	// A player on the scale doesn't count (items only).
	put_player(&r, 0, scale.pos + {0, fs.FEET, 0})
	idle(&r, 96)
	testing.expectf(t, abs(plat_y(&r, scale_gate) - closed) < 0.01, "a player opened the scale's gate")
	put_player(&r, 0, scale.pos + {4, fs.FEET, 2})
	put_item(&r, heavy, scale.pos + {0, 0.6, 0})
	idle(&r, 96)
	testing.expectf(t, plat_y(&r, scale_gate) < closed - 4, "the heavy crate didn't open the scale's gate")
	// The key in the lock opens its gate for good.
	lock_closed := plat_y(&r, lock_gate)
	put_item(&r, key, lock.pos)
	idle(&r, 8)
	put_item(&r, key, lock.pos + {2, 0, 0})
	idle(&r, 96)
	testing.expectf(t, plat_y(&r, lock_gate) < lock_closed - 4, "the lock's gate didn't stay open")
	expect_clean(t, &r)
}

// Toss: a friend thrown up onto the perch touches the switch, which lowers the gate.
@(test)
route_toss_friend_to_switch :: proc(t: ^testing.T) {
	r := start(2)
	defer finish(&r)
	gate := platform_at_marker(&r, "TossGate")
	sw := marker_named(&r, "TossSwitch")
	testing.expect(t, gate >= 0 && sw != nil)
	if gate < 0 || sw == nil do return
	closed := plat_y(&r, gate)
	idle(&r, 2) // players join on the first tick
	// Both on F, under the perch (x 3..7, 3 m up), the thrower facing it.
	base := [3]f32{1.0, 14.5 + fs.FEET, sw.pos.z}
	put_player(&r, 0, base)
	put_player(&r, 1, base + {1.2, 0, 0})
	idle(&r, 32)
	step(&r, {aim_at(&r, 0, pos(&r, 1), {buttons = fs.BUTTON_GRAB}), {}, {}, {}})
	testing.expect_value(t, r.s.state.players[0].held_kind, fs.Held_Kind.Player)
	for _ in 0 ..< 24 do step(&r, {aim_at(&r, 0, pos(&r, 0) + {1, 0.2, 0}, {}), {}, {}, {}})
	// Full charge, aimed up and over the perch's edge.
	for _ in 0 ..< 40 do step(&r, {aim_at(&r, 0, pos(&r, 0) + {1, 1.3, 0}, {buttons = fs.BUTTON_THROW}), {}, {}, {}})
	step(&r, {aim_at(&r, 0, pos(&r, 0) + {1, 1.3, 0}, {}), {}, {}, {}})
	testing.expect_value(t, r.counts[.Thrown], 1)
	idle(&r, 96)
	if r.counts[.Switch_On] == 0 {
		// Landed on the perch but short of the switch: walk to it.
		for _ in 0 ..< 160 {
			step(&r, {{}, walk(&r, 1, sw.pos, 0.1), {}, {}})
			if r.counts[.Switch_On] > 0 do break
		}
	}
	testing.expectf(t, r.counts[.Switch_On] == 1, "the friend never reached the switch (at %v)", pos(&r, 1))
	idle(&r, 96)
	testing.expectf(t, plat_y(&r, gate) < closed - 4, "the toss gate didn't open")
	expect_clean(t, &r)
}

@(test)
route_finish_and_reset :: proc(t: ^testing.T) {
	r := start(1)
	defer finish(&r)
	for _ in 0 ..< 400 {
		step(&r, {walk(&r, 0, {0, 0, -20}, 0.3), {}, {}, {}})
		if r.s.state.phase == .Run do break
	}
	testing.expect_value(t, r.s.state.phase, fs.Phase.Run)
	trophy := item_at_marker(&r, "Trophy")
	fin := marker_named(&r, "Finish")
	put_item(&r, trophy, fin.pos)
	idle(&r, 4)
	testing.expect_value(t, r.s.state.phase, fs.Phase.Finished)
	testing.expect_value(t, r.counts[.Run_Finished], 1)
	testing.expect(t, r.s.state.best_ticks > 0)
	idle(&r, int(fs.FINISH_HOLD_TICKS) + 8)
	testing.expect_value(t, r.s.state.phase, fs.Phase.Hub)
	testing.expect_value(t, r.s.state.checkpoint, -1)
	home := r.s.world.items[trophy].pos
	tp := item_pos(&r, trophy)
	testing.expectf(t, abs(tp.x - home.x) + abs(tp.z - home.z) < 0.1, "the trophy is at %v, home %v", tp, home)
	testing.expectf(t, abs(pos(&r, 0).z) < 2, "the player is back in the hub? %v", pos(&r, 0))
	expect_clean(t, &r)
}
