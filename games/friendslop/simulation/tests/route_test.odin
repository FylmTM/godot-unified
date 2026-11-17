// games/friendslop/SPEC.md "The route": each beat's mechanism on the real level, sync-tested every tick. Setups place
// players and items directly (then re-save that tick, so the sync-test never rewinds past a setup).
package test_friendslop

import "core:testing"

import fs "../friendslop"
import "unified:headless"
import "unified:level"
import "unified:physics"

// Applies a setup to the current tick and makes it the tick's saved state.
setup :: proc(run: ^Run, apply: proc(run: ^Run)) {
	apply(run)
	headless.run_pin(&run.checked)
}

marker_named :: proc(run: ^Run, name: string) -> ^level.Marker {
	return level.find_named(&run.simulation.world.level, name)
}

item_at_marker :: proc(run: ^Run, name: string) -> int {
	marker := marker_named(run, name)
	if marker == nil do return -1
	for i in 0 ..< run.simulation.world.item_count {
		if run.simulation.world.items[i].marker == marker.index do return i
	}
	return -1
}

platform_at_marker :: proc(run: ^Run, name: string) -> int {
	marker := marker_named(run, name)
	if marker == nil do return -1
	for i in 0 ..< run.simulation.world.platform_count {
		if run.simulation.world.platforms[i].marker == marker.index do return i
	}
	return -1
}

trigger_at_marker :: proc(run: ^Run, name: string) -> int {
	marker := marker_named(run, name)
	if marker == nil do return -1
	for i in 0 ..< run.simulation.world.trigger_count {
		if run.simulation.world.triggers[i].marker == marker.index do return i
	}
	return -1
}

put_item :: proc(run: ^Run, item: int, at: [3]f32) {
	run.setup_index, run.setup_pos = item, at
	setup(run, proc(run: ^Run) {
		physics.body_set_transform(
			run.simulation.world.phys,
			run.simulation.state.items[run.setup_index].body,
			run.setup_pos,
			{0, 0, 0, 1},
		)
		physics.body_set_linear_velocity(
			run.simulation.world.phys,
			run.simulation.state.items[run.setup_index].body,
			{},
		)
		physics.body_set_angular_velocity(
			run.simulation.world.phys,
			run.simulation.state.items[run.setup_index].body,
			{},
		)
	})
}

put_player :: proc(run: ^Run, slot: int, at: [3]f32) {
	run.setup_index, run.setup_pos = slot, at
	setup(run, proc(run: ^Run) {
		physics.character_teleport(
			run.simulation.world.phys,
			&character(run, run.setup_index).controller,
			run.setup_pos,
		)
	})
}

platform_y :: proc(run: ^Run, platform: int) -> f32 {
	return physics.body_position(run.simulation.world.phys, run.simulation.state.platforms[platform].body).y
}

@(test)
route_start_checkpoint_respawn :: proc(t: ^testing.T) {
	run := start(1)
	defer finish(&run)
	idle(&run, 16)
	// Walk north out of the hub through the start gate.
	for _ in 0 ..< 400 {
		step(&run, {walk(&run, 0, {0, 0, -20}, 0.3), {}, {}, {}})
		if run.simulation.state.phase == .Run do break
	}
	testing.expect_value(t, run.simulation.state.phase, fs.Phase.Run)
	testing.expect_value(t, event_count(&run, fs.Event_Run_Started), 1)
	// Teleport to checkpoint 3's landing and fall off the side: respawn there.
	check3 := marker_named(&run, "Check3")
	put_player(&run, 0, check3.pos)
	idle(&run, 8)
	testing.expect_value(t, run.simulation.state.checkpoint, 3)
	for _ in 0 ..< 200 {
		step(&run, {walk(&run, 0, check3.pos + {10, 0, 0}, 0.1), {}, {}, {}})
		if event_count(&run, fs.Event_Fell) > 0 do break
	}
	testing.expect_value(t, event_count(&run, fs.Event_Fell), 1)
	idle(&run, 120)
	testing.expect_value(t, event_count(&run, fs.Event_Respawned), 1)
	at := player_pos(&run, 0)
	testing.expectf(
		t,
		abs(at.z - check3.pos.z) < 1.5 && abs(at.y - check3.pos.y) < 1.5,
		"respawned at %v, checkpoint %v",
		at,
		check3.pos,
	)
	expect_clean(t, &run)
}

@(test)
route_plate_holds_gate :: proc(t: ^testing.T) {
	run := start(1)
	defer finish(&run)
	gate := platform_at_marker(&run, "PlateGate")
	plate := marker_named(&run, "Plate")
	cube := item_at_marker(&run, "WeightCube")
	testing.expect(t, gate >= 0 && plate != nil && cube >= 0)
	if gate < 0 || plate == nil || cube < 0 do return
	closed := platform_y(&run, gate)
	put_item(&run, cube, plate.pos + {0, 0.6, 0})
	idle(&run, 96)
	testing.expect(t, event_count(&run, fs.Event_Plate_On) >= 1)
	testing.expectf(t, platform_y(&run, gate) < closed - 4, "gate at %v (closed %v)", platform_y(&run, gate), closed)
	// Take the cube away: the gate closes again.
	put_item(&run, cube, plate.pos + {3, 0.6, 0})
	idle(&run, 96)
	testing.expect(t, event_count(&run, fs.Event_Plate_Off) >= 1)
	testing.expectf(t, abs(platform_y(&run, gate) - closed) < 0.01, "gate didn't close: %v", platform_y(&run, gate))
	expect_clean(t, &run)
}

@(test)
route_bell_bridge :: proc(t: ^testing.T) {
	run := start(1)
	defer finish(&run)
	bridge := platform_at_marker(&run, "Bridge")
	bell := marker_named(&run, "Bell")
	ball := item_at_marker(&run, "Ball1")
	testing.expect(t, bridge >= 0 && bell != nil && ball >= 0)
	if bridge < 0 || bell == nil || ball < 0 do return
	bridge_x_before := physics.body_position(run.simulation.world.phys, run.simulation.state.platforms[bridge].body).x
	// A ball flying at the bell.
	run.setup_index, run.setup_pos = ball, bell.pos
	setup(&run, proc(run: ^Run) {
		body := run.simulation.state.items[run.setup_index].body
		physics.body_set_transform(run.simulation.world.phys, body, run.setup_pos + {0, 0, 3}, {0, 0, 0, 1})
		physics.body_set_linear_velocity(run.simulation.world.phys, body, {})
		physics.body_set_angular_velocity(run.simulation.world.phys, body, {})
		physics.body_set_linear_velocity(run.simulation.world.phys, body, {0, 0, -9})
	})
	idle(&run, 32)
	testing.expect_value(t, event_count(&run, fs.Event_Bell_Rung), 1)
	idle(&run, 160)
	bridge_x_after := physics.body_position(run.simulation.world.phys, run.simulation.state.platforms[bridge].body).x
	testing.expectf(
		t,
		abs(bridge_x_after) < 0.01 && bridge_x_before > 7,
		"the bridge went from x %v to %v",
		bridge_x_before,
		bridge_x_after,
	)
	expect_clean(t, &run)
}

@(test)
route_key_lock_and_scale :: proc(t: ^testing.T) {
	run := start(1)
	defer finish(&run)
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
	put_player(&run, 0, scale.pos + {0, fs.FEET, 0})
	idle(&run, 96)
	testing.expectf(t, abs(platform_y(&run, scale_gate) - closed) < 0.01, "a player opened the scale's gate")
	put_player(&run, 0, scale.pos + {4, fs.FEET, 2})
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
	expect_clean(t, &run)
}

// Toss: a friend thrown up onto the perch touches the switch, which lowers the gate.
@(test)
route_toss_friend_to_switch :: proc(t: ^testing.T) {
	run := start(2)
	defer finish(&run)
	gate := platform_at_marker(&run, "TossGate")
	toss_switch := marker_named(&run, "TossSwitch")
	testing.expect(t, gate >= 0 && toss_switch != nil)
	if gate < 0 || toss_switch == nil do return
	closed := platform_y(&run, gate)
	idle(&run, 2) // players join on the first tick
	// Both on F, under the perch (x 3..7, 3 m up), the thrower facing it.
	base := [3]f32{1.0, 14.5 + fs.FEET, toss_switch.pos.z}
	put_player(&run, 0, base)
	put_player(&run, 1, base + {1.2, 0, 0})
	idle(&run, 32)
	step(&run, {aim_at(&run, 0, player_pos(&run, 1), {buttons = {.Grab}}), {}, {}, {}})
	testing.expect_value(t, character(&run, 0).held_kind, fs.Held_Kind.Player)
	for _ in 0 ..< 24 do step(&run, {aim_at(&run, 0, player_pos(&run, 0) + {1, 0.2, 0}, {}), {}, {}, {}})
	// Full charge, aimed up and over the perch's edge.
	for _ in 0 ..< 40 {
		step(&run, {aim_at(&run, 0, player_pos(&run, 0) + {1, 1.3, 0}, {buttons = {.Throw}}), {}, {}, {}})
	}
	step(&run, {aim_at(&run, 0, player_pos(&run, 0) + {1, 1.3, 0}, {}), {}, {}, {}})
	testing.expect_value(t, event_count(&run, fs.Event_Thrown), 1)
	idle(&run, 96)
	if event_count(&run, fs.Event_Switch_On) == 0 {
		// Landed on the perch but short of the switch: walk to it.
		for _ in 0 ..< 160 {
			step(&run, {{}, walk(&run, 1, toss_switch.pos, 0.1), {}, {}})
			if event_count(&run, fs.Event_Switch_On) > 0 do break
		}
	}
	testing.expectf(
		t,
		event_count(&run, fs.Event_Switch_On) == 1,
		"the friend never reached the switch (at %v)",
		player_pos(&run, 1),
	)
	idle(&run, 96)
	testing.expectf(t, platform_y(&run, gate) < closed - 4, "the toss gate didn't open")
	expect_clean(t, &run)
}

@(test)
route_finish_and_reset :: proc(t: ^testing.T) {
	run := start(1)
	defer finish(&run)
	for _ in 0 ..< 400 {
		step(&run, {walk(&run, 0, {0, 0, -20}, 0.3), {}, {}, {}})
		if run.simulation.state.phase == .Run do break
	}
	testing.expect_value(t, run.simulation.state.phase, fs.Phase.Run)
	trophy := item_at_marker(&run, "Trophy")
	finish_marker := marker_named(&run, "Finish")
	put_item(&run, trophy, finish_marker.pos)
	idle(&run, 4)
	testing.expect_value(t, run.simulation.state.phase, fs.Phase.Finished)
	testing.expect_value(t, event_count(&run, fs.Event_Run_Finished), 1)
	testing.expect(t, run.simulation.state.best_ticks > 0)
	idle(&run, int(fs.FINISH_HOLD_TICKS) + 8)
	testing.expect_value(t, run.simulation.state.phase, fs.Phase.Hub)
	testing.expect_value(t, run.simulation.state.checkpoint, -1)
	home := run.simulation.world.items[trophy].pos
	trophy_pos := item_pos(&run, trophy)
	testing.expectf(
		t,
		abs(trophy_pos.x - home.x) + abs(trophy_pos.z - home.z) < 0.1,
		"the trophy is at %v, home %v",
		trophy_pos,
		home,
	)
	testing.expectf(t, abs(player_pos(&run, 0).z) < 2, "the player is back in the hub? %v", player_pos(&run, 0))
	expect_clean(t, &run)
}

// When the last player leaves, the run ends there: back to the hub, the checkpoint cleared (like drift and survivor).
@(test)
route_resets_when_nobody_is_present :: proc(t: ^testing.T) {
	run := start(1)
	defer finish(&run)
	put_player(&run, 0, marker_named(&run, "Check3").pos)
	setup(&run, proc(run: ^Run) {
		run.simulation.state.phase = .Run
		run.simulation.state.run_tick = run.simulation.tick
		run.simulation.state.checkpoint = 3
	})
	idle(&run, 4)
	testing.expect_value(t, run.simulation.state.phase, fs.Phase.Run)
	leave(&run, 0)
	idle(&run, 4)
	testing.expect_value(t, run.simulation.state.phase, fs.Phase.Hub)
	testing.expect_value(t, run.simulation.state.checkpoint, -1)
	expect_clean(t, &run)
}
