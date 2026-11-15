// games/drift/SPEC.md: scenarios on the real arena (the committed export of game/levels/arena.tscn) while every
// tick is sync-tested (restore 8 ticks back, re-simulate with the recorded inputs and commands, compare
// checksums). So splits, warps, the station falling and the reset are all checked for determinism under
// rollback, and every body stays exactly on the plane.
package test_drift

import "core:testing"

import dr "../drift"
import "unified:b3"
import "unified:physics"
import "unified:sim"

WINDOW :: 8

Run :: struct {
	simulation:   ^dr.Sim,
	recorded:     [dynamic]dr.Inputs, // recorded[tick] = the inputs of that tick
	forward:      [dynamic]u64,
	mismatches:   int,
	off_plane:    int, // bodies seen off the plane (z, or a rotation not about Z)
	present:      sim.Players,
	floor:        u32, // the sync-test never restores before this tick (a setup changed it)
	// events of the forward ticks
	waves:        int,
	shots:        int,
	rock_hits:    int,
	rock_splits:  int,
	matches_over: int,
	warps:        int,
	last_warp:    dr.Event_Warped,
}

start :: proc(players: int) -> Run {
	run := Run {
		simulation = sim.create(&dr.GAME, 1, ARENA),
	}
	append(&run.recorded, dr.Inputs{})
	append(&run.forward, 0)
	for player in 0 ..< players do run.present += {player}
	step(&run, {}) // ships join on the first tick
	return run
}

finish :: proc(run: ^Run) {
	sim.destroy(run.simulation)
	delete(run.recorded)
	delete(run.forward)
}

// One forward tick with these inputs (and player 0's command, when given), then the sync-test of the last
// WINDOW ticks and the plane check.
step :: proc(run: ^Run, input: [dr.PLAYERS]dr.Input, command: dr.Cmd = nil) {
	inputs := dr.Inputs {
		present = run.present,
		input   = input,
	}
	switch value in command {
	case dr.Cmd_Start:
		send(&inputs, value)
	case dr.Cmd_Restart:
		send(&inputs, value)
	}
	append(&run.recorded, inputs)
	simulation := run.simulation
	sim.step(simulation, &inputs)
	tick := simulation.tick
	append(&run.forward, sim.checksum(simulation))
	for &raw in sim.events_at(simulation, tick) do count_event(run, sim.event_value(&raw, dr.Event))
	check_plane(run)
	if tick < WINDOW do return
	from := max(tick - WINDOW, run.floor)
	if from == tick do return
	if !sim.restore(simulation, from) || !physics.check_refs(simulation.world.phys, &simulation.state) {
		run.mismatches += 1
		return
	}
	for redo in from + 1 ..= tick {
		sim.step(simulation, &run.recorded[redo])
		if sim.checksum(simulation) != run.forward[redo] do run.mismatches += 1
	}
}

count_event :: proc(run: ^Run, event: dr.Event) {
	#partial switch value in event {
	case dr.Event_Wave:
		run.waves += 1
	case dr.Event_Fired:
		run.shots += 1
	case dr.Event_Rock_Hit:
		run.rock_hits += 1
	case dr.Event_Rock_Split:
		run.rock_splits += 1
	case dr.Event_Match_Over:
		run.matches_over += 1
	case dr.Event_Warped:
		run.warps += 1
		run.last_warp = value
	}
}

// A setup changed the state or the world at the current tick: save it again, and never restore before it.
setup_done :: proc(run: ^Run) {
	sim.save(run.simulation)
	run.forward[run.simulation.tick] = sim.checksum(run.simulation)
	run.floor = run.simulation.tick
}

// Player 0 sends a command this tick.
send :: proc(inputs: ^dr.Inputs, value: $T) {
	raw, ok := sim.command_make(dr.Cmd, value)
	assert(ok && sim.add_command(inputs, raw))
}

// Every ship and rock: z == 0 and a rotation about Z only, bit-exact (−0 counts as 0).
check_plane :: proc(run: ^Run) {
	world := run.simulation.world.phys
	state := &run.simulation.state
	on_plane :: proc(world: ^physics.World, ref: physics.Body_Ref) -> bool {
		body := physics.body_id(world, ref)
		position := b3.body_get_position(body)
		rotation := b3.body_get_rotation(body)
		return position.z == 0 && rotation.x == 0 && rotation.y == 0
	}
	for &ship in state.ships do if ship.active && !on_plane(world, ship.body) do run.off_plane += 1
	rocks := sim.iterate(&state.rocks)
	for rock in sim.next(&rocks) {
		if !on_plane(world, rock.body) do run.off_plane += 1
	}
	if !on_plane(world, state.station) do run.off_plane += 1
}

scripted :: proc(run: ^Run) -> (input: [dr.PLAYERS]dr.Input) {
	tick := run.simulation.tick + 1
	for player in 0 ..< dr.PLAYERS do input[player] = dr.scripted_input(7, player, tick, &run.simulation.state)
	return
}

@(test)
a_match_stays_on_the_plane :: proc(t: ^testing.T) {
	run := start(4)
	defer finish(&run)
	step(&run, scripted(&run), dr.Cmd_Start{})
	testing.expect_value(t, run.simulation.state.phase, dr.Phase.Match)
	for _ in 0 ..< 2600 do step(&run, scripted(&run)) // two waves and a half
	testing.expect_value(t, run.mismatches, 0)
	testing.expect_value(t, run.off_plane, 0)
	testing.expect(t, run.waves >= 2, "two waves")
	testing.expect(t, run.shots > 100, "ships fire")
	testing.expect(t, run.rock_hits > 0, "bullets hit rocks")
	testing.expect(t, run.rock_splits > 0, "rocks split inside rollback windows")
}

@(test)
the_station_falls_and_the_match_resets :: proc(t: ^testing.T) {
	run := start(2)
	defer finish(&run)
	state := &run.simulation.state
	step(&run, {}, dr.Cmd_Start{})
	for _ in 0 ..< 200 do step(&run, {})
	testing.expect(t, state.rocks.count > 0, "the first wave's rocks")
	// a setup: one hit left
	state.station_hp = 1
	setup_done(&run)
	for _ in 0 ..< 64 * 60 {
		step(&run, {})
		if state.phase == .Over do break
	}
	testing.expect_value(t, state.phase, dr.Phase.Over)
	testing.expect_value(t, run.matches_over, 1)
	step(&run, {}, dr.Cmd_Restart{})
	testing.expect_value(t, state.phase, dr.Phase.Lobby)
	testing.expect_value(t, state.rocks.count, 0)
	testing.expect_value(t, state.station_hp, dr.STATION_HP)
	for _ in 0 ..< 64 do step(&run, {})
	testing.expect_value(t, run.mismatches, 0)
	testing.expect_value(t, run.off_plane, 0)
}

@(test)
a_ship_warps_through_a_gate :: proc(t: ^testing.T) {
	run := start(1)
	defer finish(&run)
	world := run.simulation.world
	testing.expect(
		t,
		world.gate_count == 2 && world.gates[0].pair == 1 && world.gates[1].pair == 0,
		"the arena's gate pair",
	)
	// a setup: the ship just short of gate 0, flying into it
	gate := world.gates[0].pos
	ship := &run.simulation.state.ships[0]
	physics.teleport(world.phys, ship.body, {gate.x - 1.5, gate.y, 0})
	physics.set_velocity_2d(world.phys, ship.body, {6, 0}, 0)
	setup_done(&run)
	for _ in 0 ..< 32 {
		step(&run, {})
		if run.warps > 0 do break
	}
	testing.expect_value(t, run.warps, 1)
	testing.expect_value(t, run.last_warp.player, 0)
	testing.expect_value(t, run.last_warp.from_gate, 0)
	testing.expect_value(t, run.last_warp.to_gate, 1)
	pos, _ := physics.pose_2d(world.phys, ship.body)
	to := world.gates[1].pos
	testing.expect_value(t, run.last_warp.position, sim.Position{to.x, to.y, 0})
	offset := pos - to
	testing.expect(t, offset.x * offset.x + offset.y * offset.y < 1, "the ship comes out of the other gate")
	vel, _ := physics.velocity_2d(world.phys, ship.body)
	testing.expect(t, vel.x > 3, "it keeps its velocity")
	for _ in 0 ..< 64 do step(&run, {}) // both gates recharge: no warp back
	testing.expect_value(t, run.warps, 1)
	testing.expect_value(t, run.mismatches, 0)
}
