// games/friendslop/README.md, The route: each beat's mechanism on the real level, sync-tested every tick. Setups place
// players and items directly (then re-save that tick, so the sync-test never rewinds past a setup).
package test_friendslop

import "core:testing"

import "unified:dmath"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:level"
import "unified:physics"
import "unified:sim"

import g "../friendslop"

marker_named :: proc(run: ^Run, name: string) -> ^level.Marker {
	return level.find_named(physics.level_data(run.simulation.world.phys, run.simulation.state.level.id), name)
}

// The index in a World list (items, platforms, triggers) of what the level marker called `name` placed, or -1.
index_at_marker :: proc(run: ^Run, list: []$Def, name: string) -> int {
	marker := marker_named(run, name)
	if marker == nil do return -1
	for &def, i in list {
		if def.marker == marker.index do return i
	}
	return -1
}

item_at_marker :: proc(run: ^Run, name: string) -> int {
	places := places_of(run)
	return index_at_marker(run, sim.slice(&places.items), name)
}

platform_at_marker :: proc(run: ^Run, name: string) -> int {
	places := places_of(run)
	return index_at_marker(run, sim.slice(&places.platforms), name)
}

// Puts an item at rest at `at`, then re-saves the tick (the sync-test never rewinds past it).
put_item :: proc(run: ^Run, item: int, at: [3]f32) {
	physics.body_teleport(run.simulation.world.phys, run.simulation.state.items[item].body, at)
	headless.run_pin(run)
}

// Teleports a player to `at`, then re-saves the tick.
put_player :: proc(run: ^Run, slot: int, at: [3]f32) {
	physics.character_teleport(run.simulation.world.phys, &sim.slot_data(run.simulation, slot).controller, at)
	headless.run_pin(run)
}

platform_y :: proc(run: ^Run, platform: int) -> f32 {
	return physics.body_position(run.simulation.world.phys, run.simulation.state.platforms[platform].body).y
}

@(test)
route_start_checkpoint_respawn :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	idle(&run, 16)
	// Walk north out of the hub through the start gate.
	for _ in 0 ..< 400 {
		step(&run, {walk(&run, 0, {0, 0, -20}, 0.3), {}, {}, {}})
		if run.simulation.state.phase == .Run do break
	}
	testing.expect_value(t, run.simulation.state.phase, g.Phase.Run)
	testing.expect_value(t, headless.run_events(&run, g.Event_Run_Started), 1)
	// Teleport to checkpoint 3's landing and fall off the side: respawn there.
	check3 := marker_named(&run, "Check3")
	put_player(&run, 0, check3.pos)
	idle(&run, 8)
	testing.expect_value(t, run.simulation.state.checkpoint, 3)
	for _ in 0 ..< 200 {
		step(&run, {walk(&run, 0, check3.pos + {10, 0, 0}, 0.1), {}, {}, {}})
		if headless.run_events(&run, g.Event_Fell) > 0 do break
	}
	testing.expect_value(t, headless.run_events(&run, g.Event_Fell), 1)
	idle(&run, 120)
	testing.expect_value(t, headless.run_events(&run, g.Event_Respawned), 1)
	at := player_pos(&run, 0)
	testing.expectf(
		t,
		abs(at.z - check3.pos.z) < 1.5 && abs(at.y - check3.pos.y) < 1.5,
		"respawned at %v, checkpoint %v",
		at,
		check3.pos,
	)
	scenarios.expect_synced(t, &run)
}

@(test)
route_plate_holds_gate :: proc(t: ^testing.T) {
	run := route_begin(1)
	defer headless.run_end(&run)
	gate := platform_at_marker(&run, "PlateGate")
	plate := marker_named(&run, "Plate")
	cube := item_at_marker(&run, "WeightCube")
	testing.expect(t, gate >= 0 && plate != nil && cube >= 0)
	if gate < 0 || plate == nil || cube < 0 do return
	closed := platform_y(&run, gate)
	put_item(&run, cube, plate.pos + {0, 0.6, 0})
	idle(&run, 96)
	testing.expect(t, headless.run_events(&run, g.Event_Plate_On) >= 1)
	testing.expectf(t, platform_y(&run, gate) < closed - 4, "gate at %v (closed %v)", platform_y(&run, gate), closed)
	// Take the cube away: the gate closes again.
	put_item(&run, cube, plate.pos + {3, 0.6, 0})
	idle(&run, 96)
	testing.expect(t, headless.run_events(&run, g.Event_Plate_Off) >= 1)
	testing.expectf(t, abs(platform_y(&run, gate) - closed) < 0.01, "gate didn't close: %v", platform_y(&run, gate))
	scenarios.expect_synced(t, &run)
}

@(test)
route_bell_bridge :: proc(t: ^testing.T) {
	run := route_begin(1)
	defer headless.run_end(&run)
	bridge := platform_at_marker(&run, "Bridge")
	bell := marker_named(&run, "Bell")
	ball := item_at_marker(&run, "Ball1")
	testing.expect(t, bridge >= 0 && bell != nil && ball >= 0)
	if bridge < 0 || bell == nil || ball < 0 do return
	bridge_x_before := physics.body_position(run.simulation.world.phys, run.simulation.state.platforms[bridge].body).x
	// A ball flying at the bell.
	body := run.simulation.state.items[ball].body
	physics.body_teleport(run.simulation.world.phys, body, bell.pos + {0, 0, 3})
	physics.body_set_linear_velocity(run.simulation.world.phys, body, {0, 0, -9})
	headless.run_pin(&run)
	idle(&run, 32)
	testing.expect_value(t, headless.run_events(&run, g.Event_Bell_Rung), 1)
	idle(&run, 160)
	bridge_x_after := physics.body_position(run.simulation.world.phys, run.simulation.state.platforms[bridge].body).x
	testing.expectf(
		t,
		abs(bridge_x_after) < 0.01 && bridge_x_before > 7,
		"the bridge went from x %v to %v",
		bridge_x_before,
		bridge_x_after,
	)
	scenarios.expect_synced(t, &run)
}

@(test)
route_key_lock_and_scale :: proc(t: ^testing.T) {
	run := route_begin(1)
	defer headless.run_end(&run)
	key := item_at_marker(&run, "Key")
	lock := marker_named(&run, "Lock")
	lock_gate := platform_at_marker(&run, "LockGate")
	heavy := item_at_marker(&run, "HeavyCrate")
	scale := marker_named(&run, "Scale")
	scale_gate := platform_at_marker(&run, "ScaleGate")
	testing.expect(t, key >= 0 && lock != nil && lock_gate >= 0 && heavy >= 0 && scale != nil && scale_gate >= 0)
	if key < 0 || lock == nil || lock_gate < 0 || heavy < 0 || scale == nil || scale_gate < 0 do return
	closed := platform_y(&run, scale_gate)
	idle(&run, 2) // players join on the first tick
	// A player on the scale doesn't count (items only).
	put_player(&run, 0, scale.pos + {0, g.FEET, 0})
	idle(&run, 96)
	testing.expectf(t, abs(platform_y(&run, scale_gate) - closed) < 0.01, "a player opened the scale's gate")
	put_player(&run, 0, scale.pos + {4, g.FEET, 2})
	put_item(&run, heavy, scale.pos + {0, 0.6, 0})
	idle(&run, 96)
	testing.expectf(t, platform_y(&run, scale_gate) < closed - 4, "the heavy crate didn't open the scale's gate")
	// The key in the lock opens its gate for good.
	lock_closed := platform_y(&run, lock_gate)
	put_item(&run, key, lock.pos)
	idle(&run, 8)
	put_item(&run, key, lock.pos + {2, 0, 0})
	idle(&run, 96)
	testing.expectf(t, platform_y(&run, lock_gate) < lock_closed - 4, "the lock's gate didn't stay open")
	scenarios.expect_synced(t, &run)
}

// Toss: a friend thrown up onto the perch touches the switch, which lowers the gate.
@(test)
route_toss_friend_to_switch :: proc(t: ^testing.T) {
	run := route_begin(2)
	defer headless.run_end(&run)
	gate := platform_at_marker(&run, "TossGate")
	toss_switch := marker_named(&run, "TossSwitch")
	testing.expect(t, gate >= 0 && toss_switch != nil)
	if gate < 0 || toss_switch == nil do return
	closed := platform_y(&run, gate)
	idle(&run, 2) // players join on the first tick
	// Both on F, under the perch (x 3..7, 3 m up), the thrower facing it.
	base := [3]f32{1.0, 14.5 + g.FEET, toss_switch.pos.z}
	put_player(&run, 0, base)
	put_player(&run, 1, base + {1.2, 0, 0})
	idle(&run, 32)
	step(&run, {aim_at(&run, 0, player_pos(&run, 1), {buttons = {.Grab}}), {}, {}, {}})
	testing.expect_value(t, sim.slot_data(run.simulation, 0).held_kind, g.Held_Kind.Player)
	for _ in 0 ..< 24 do step(&run, {aim_at(&run, 0, player_pos(&run, 0) + {1, 0.2, 0}, {}), {}, {}, {}})
	// Full charge, aimed up and over the perch's edge.
	for _ in 0 ..< 40 {
		step(&run, {aim_at(&run, 0, player_pos(&run, 0) + {1, 1.3, 0}, {buttons = {.Throw}}), {}, {}, {}})
	}
	step(&run, {aim_at(&run, 0, player_pos(&run, 0) + {1, 1.3, 0}, {}), {}, {}, {}})
	testing.expect_value(t, headless.run_events(&run, g.Event_Thrown), 1)
	idle(&run, 96)
	if headless.run_events(&run, g.Event_Switch_On) == 0 {
		// Landed on the perch but short of the switch: walk to it.
		for _ in 0 ..< 160 {
			step(&run, {{}, walk(&run, 1, toss_switch.pos, 0.1), {}, {}})
			if headless.run_events(&run, g.Event_Switch_On) > 0 do break
		}
	}
	testing.expectf(
		t,
		headless.run_events(&run, g.Event_Switch_On) == 1,
		"the friend never reached the switch (at %v)",
		player_pos(&run, 1),
	)
	idle(&run, 96)
	testing.expectf(t, platform_y(&run, gate) < closed - 4, "the toss gate didn't open")
	scenarios.expect_synced(t, &run)
}

@(test)
route_finish_and_reset :: proc(t: ^testing.T) {
	run := route_begin(1)
	defer headless.run_end(&run)
	testing.expect_value(t, run.simulation.state.phase, g.Phase.Run) // the travel to the route started the run
	trophy := item_at_marker(&run, "Trophy")
	finish_marker := marker_named(&run, "Finish")
	put_item(&run, trophy, finish_marker.pos)
	idle(&run, 4)
	testing.expect_value(t, run.simulation.state.phase, g.Phase.Finished)
	testing.expect_value(t, headless.run_events(&run, g.Event_Run_Finished), 1)
	testing.expect(t, run.simulation.state.best_ticks > 0)
	idle(&run, int(g.FINISH_HOLD_TICKS) + 8)
	// Back in the hub level: its things as the hub makes them, the player at their hub spawn.
	testing.expect_value(t, run.simulation.state.phase, g.Phase.Hub)
	testing.expect_value(t, run.simulation.state.checkpoint, -1)
	testing.expect_value(t, run.simulation.state.level.id, g.Level_Id.Hub)
	hub := places_of(&run)
	for def, i in sim.slice(&hub.items) {
		at := item_pos(&run, i)
		testing.expectf(t, abs(at.x - def.pos.x) + abs(at.z - def.pos.z) < 0.5, "hub item %d at %v", i, at)
	}
	testing.expectf(t, abs(player_pos(&run, 0).z) < 2, "the player is back in the hub? %v", player_pos(&run, 0))
	scenarios.expect_synced(t, &run)
}

// When the last player leaves, the run ends there: back to the hub, the checkpoint cleared (like drift and survivor).
@(test)
route_resets_when_nobody_is_present :: proc(t: ^testing.T) {
	run := route_begin(1)
	defer headless.run_end(&run)
	put_player(&run, 0, marker_named(&run, "Check3").pos)
	run.simulation.state.phase = .Run
	run.simulation.state.run_tick = sim.game_time(&run.simulation.state, run.simulation.tick)
	run.simulation.state.checkpoint = 3
	headless.run_pin(&run)
	idle(&run, 4)
	testing.expect_value(t, run.simulation.state.phase, g.Phase.Run)
	headless.run_seat(&run, 0, 0)
	idle(&run, 4)
	testing.expect_value(t, run.simulation.state.phase, g.Phase.Hub)
	testing.expect_value(t, run.simulation.state.checkpoint, -1)
	scenarios.expect_synced(t, &run)
}

// The ferry follows the designer curve on its marker (platform.gd's `easing`, level.prop_curve): a slow start through
// (0.6, 0.3), then a quick finish.
@(test)
the_ferry_eases_by_its_curve :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	ferry := platform_at_marker(&run, "Ferry")
	if !testing.expect(t, ferry >= 0, "the Ferry marker") do return
	path := &sim.slice(&places_of(&run).platforms)[ferry].path
	testing.expect_value(t, path.ease, physics.Path_Ease.Curve)
	testing.expect(t, path.curve.samples[0] == 0 && path.curve.samples[31] == 1, "from 0 to 1")
	eased := dmath.curve_sample(path.curve, 0.6)
	testing.expectf(t, abs(eased - 0.3) < 0.01, "at 0.6 of the leg's time: %v of the way", eased)
}
