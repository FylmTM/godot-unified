// drift's rules (examples/drift/README.md) as scenarios on the real arena (the committed export of
// game/levels/arena.tscn) while every tick is sync-tested (restore 8 ticks back, re-simulate with the recorded inputs
// and commands, compare checksums). So splits, warps, the station falling and the reset are all checked for
// determinism under rollback. That every body stays exactly on the plane is the library's
// (tests/physics/plane2d_test.odin).
package test_drift

import "core:testing"

import g "../drift"
import "unified:dmath"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:physics"
import "unified:sim"

Run :: headless.Run(g.Game)

// One sync-tested tick of the seated members (headless.run_seat) with these inputs, and slot 0's command when given.
step :: proc(run: ^Run, input: [g.PLAYERS]g.Input, command: g.Command = nil) {
	if command != nil {
		headless.run_command(run, input, 0, command)
	} else {
		headless.run_step(run, input)
	}
}

scripted :: proc(run: ^Run) -> (input: [g.PLAYERS]g.Input) {
	tick := run.simulation.tick + 1
	for slot in 0 ..< g.PLAYERS do input[slot] = g.scripted_input(7, slot, tick, &run.simulation.state)
	return
}

@(test)
a_match_brings_waves_that_split :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 4)
	defer headless.run_end(&run)
	step(&run, scripted(&run), g.Command_Start{})
	testing.expect_value(t, run.simulation.state.phase, g.Phase.Match)
	for _ in 0 ..< 2600 do step(&run, scripted(&run)) // two waves and a half
	scenarios.expect_synced(t, &run)
	testing.expect(t, headless.run_events(&run, g.Event_Wave) >= 2, "two waves")
	testing.expect(t, headless.run_events(&run, g.Event_Fired) > 100, "ships fire")
	testing.expect(t, headless.run_events(&run, g.Event_Rock_Hit) > 0, "bullets hit rocks")
	testing.expect(t, headless.run_events(&run, g.Event_Rock_Split) > 0, "rocks split inside rollback windows")
}

@(test)
the_station_falls_and_the_match_resets :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	state := &run.simulation.state
	step(&run, {}, g.Command_Start{})
	for _ in 0 ..< 200 do step(&run, {})
	testing.expect(t, state.rocks.count > 0, "the first wave's rocks")
	// a setup: one hit left
	state.station_hp = 1
	headless.run_pin(&run)
	for _ in 0 ..< 64 * 60 {
		step(&run, {})
		if state.phase == .Over do break
	}
	testing.expect_value(t, state.phase, g.Phase.Over)
	testing.expect_value(t, headless.run_events(&run, g.Event_Match_Over), 1)
	step(&run, {}, g.Command_Restart{})
	testing.expect_value(t, state.phase, g.Phase.Lobby)
	testing.expect_value(t, state.rocks.count, 0)
	testing.expect_value(t, state.station_hp, g.STATION_HP)
	for _ in 0 ..< 64 do step(&run, {})
	scenarios.expect_synced(t, &run)
}

@(test)
a_ship_warps_through_a_gate :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	world := run.simulation.world
	testing.expect(
		t,
		world.gates.count == 2 && sim.slice(&world.gates)[0].pair == 1 && sim.slice(&world.gates)[1].pair == 0,
		"the arena's gate pair",
	)
	// a setup: the ship just short of gate 0, flying into it
	gate := sim.slice(&world.gates)[0].pos
	ship := sim.slot_data(run.simulation, 0)
	physics.body_teleport_2d(world.phys, ship.body, gate - {1.5, 0}, g.UP)
	physics.body_set_linear_velocity_2d(world.phys, ship.body, {6, 0})
	headless.run_pin(&run)
	warp: g.Event_Warped
	for _ in 0 ..< 32 {
		step(&run, {})
		if event, warped := headless.run_last_event(&run, g.Event_Warped); warped {
			warp = event
			break
		}
	}
	testing.expect_value(t, headless.run_events(&run, g.Event_Warped), 1)
	testing.expect_value(t, warp.player, sim.player_in_slot(run.simulation, 0))
	testing.expect_value(t, warp.from_gate, 0)
	testing.expect_value(t, warp.to_gate, 1)
	pos := physics.body_position_2d(world.phys, ship.body)
	to := sim.slice(&world.gates)[1].pos
	testing.expect_value(t, warp.position, sim.position_2d(to))
	testing.expect(t, dmath.dist_sq(pos, to) < 1, "the ship comes out of the other gate")
	vel := physics.body_linear_velocity_2d(world.phys, ship.body)
	testing.expect(t, vel.x > 3, "it keeps its velocity")
	for _ in 0 ..< 64 do step(&run, {}) // both gates recharge: no warp back
	testing.expect_value(t, headless.run_events(&run, g.Event_Warped), 1)
	scenarios.expect_synced(t, &run)
}

// Things are owned by the person, not the slot: A's bullet stays A's while A is away and someone new takes A's slot
// (a new player with a zeroed ship), and A comes back in another slot with their ship as they left it.
@(test)
owners_follow_the_player_not_the_slot :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	state := &run.simulation.state
	first := sim.player_in_slot(run.simulation, 0)
	fire: [g.PLAYERS]g.Input
	fire[0].buttons = {.Fire}
	step(&run, fire)
	bullet: sim.Handle(g.Bullet)
	bullets := sim.iterate(&state.bullets)
	for each, handle in sim.next(&bullets) {
		if each.owner == first do bullet = handle
	}
	testing.expect(t, sim.get(&state.bullets, bullet) != nil, "slot 0 fired")
	testing.expect_value(t, sim.player_data(&state.players, first).shots, 1)

	headless.run_seat(&run, 0, 0) // A leaves
	step(&run, {})
	testing.expect_value(t, sim.player_data(&state.players, first).body, physics.Body_Ref{}) // no body while away
	testing.expect_value(t, sim.get(&state.bullets, bullet).owner, first)

	headless.run_seat(&run, 0, 100) // someone new in A's slot
	step(&run, {})
	testing.expect_value(t, sim.slot_data(run.simulation, 0).shots, 0)
	testing.expect_value(t, sim.get(&state.bullets, bullet).owner, first)

	headless.run_seat(&run, 2, 1) // A comes back in another slot
	step(&run, {})
	spawn, spawned := headless.run_last_event(&run, g.Event_Spawned)
	testing.expect(t, spawned, "A's ship spawned")
	ship := sim.player_data(&state.players, first)
	testing.expect_value(t, ship.shots, 1)
	testing.expect(t, ship.body != {}, "A's ship has a body again")
	pos := physics.body_position_2d(run.simulation.world.phys, ship.body)
	testing.expect_value(t, pos, run.simulation.world.spawns[2])
	testing.expect_value(t, spawn.player, first)
	testing.expect_value(t, sim.get(&state.bullets, bullet).owner, first)

	for _ in 0 ..< 32 do step(&run, scripted(&run))
	scenarios.expect_synced(t, &run)
}
