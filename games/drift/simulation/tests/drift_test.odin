// games/drift/SPEC.md: scenarios on the real arena (the committed export of game/levels/arena.tscn) while every
// tick is sync-tested (restore 8 ticks back, re-simulate with the recorded inputs and commands, compare
// checksums). So splits, warps, the station falling and the reset are all checked for determinism under
// rollback, and every body stays exactly on the plane.
package test_drift

import "core:testing"

import dr "../drift"
import "unified:physics"
import "unified:sim"

WINDOW :: 8

Run :: struct {
	simulation:   ^dr.Sim,
	recorded:     [dynamic]dr.Inputs, // recorded[tick] = the inputs of that tick
	forward:      [dynamic]u64,
	mismatches:   int,
	off_plane:    int, // bodies seen off the plane (z, or a rotation not about Z)
	seated:       [dr.PLAYERS]int, // the member in each slot (0: empty): a join record when it changes
	floor:        u32, // the sync-test never restores before this tick (a setup changed it)
	// events of the forward ticks
	waves:        int,
	shots:        int,
	rock_hits:    int,
	rock_splits:  int,
	matches_over: int,
	warps:        int,
	last_warp:    dr.Event_Warped,
	spawned:      [dynamic]dr.Event_Spawned,
}

start :: proc(players: int) -> Run {
	run := Run {
		simulation = sim.create(&dr.GAME, 1, ARENA),
	}
	append(&run.recorded, dr.Inputs{})
	append(&run.forward, 0)
	for slot in 0 ..< players do run.seated[slot] = slot + 1
	step(&run, {}) // ships join on the first tick
	return run
}

finish :: proc(run: ^Run) {
	sim.destroy(run.simulation)
	delete(run.recorded)
	delete(run.forward)
	delete(run.spawned)
}

// One forward tick with these inputs (and slot 0's command, when given), then the sync-test of the last
// WINDOW ticks and the plane check. A slot whose seated member isn't the one holding it gets a join record.
step :: proc(run: ^Run, input: [dr.PLAYERS]dr.Input, command: dr.Cmd = nil) {
	inputs := dr.Inputs {
		input = input,
	}
	for member, slot in run.seated {
		if member == 0 do continue
		inputs.present += {slot}
		if int(sim.player_in_slot(run.simulation, slot).id) != member do sim.join(&inputs, slot, member)
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
	if !sim.restore(simulation, from) || physics.check_refs(simulation.world.phys, &simulation.state) != "" {
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
	case dr.Event_Spawned:
		append(&run.spawned, value)
	}
}

// A setup changed the state or the world at the current tick: save it again, and never restore before it.
setup_done :: proc(run: ^Run) {
	sim.save(run.simulation)
	run.forward[run.simulation.tick] = sim.checksum(run.simulation)
	run.floor = run.simulation.tick
}

// Slot 0 sends a command this tick.
send :: proc(inputs: ^dr.Inputs, value: $T) {
	ok := sim.add_command(inputs, sim.command_make(dr.Cmd, value))
	assert(ok)
}

// Every ship and rock: z == 0 and a rotation about Z only, bit-exact (−0 counts as 0).
check_plane :: proc(run: ^Run) {
	world := run.simulation.world.phys
	state := &run.simulation.state
	on_plane :: proc(world: ^physics.World, ref: physics.Body_Ref) -> bool {
		position := physics.body_position(world, ref)
		rotation := physics.body_rotation(world, ref)
		return position.z == 0 && rotation.x == 0 && rotation.y == 0
	}
	ships := sim.iterate_present(&state.players)
	for ship in sim.next(&ships) {
		if !on_plane(world, ship.body) do run.off_plane += 1
	}
	rocks := sim.iterate(&state.rocks)
	for rock in sim.next(&rocks) {
		if !on_plane(world, rock.body) do run.off_plane += 1
	}
	if !on_plane(world, state.station) do run.off_plane += 1
}

scripted :: proc(run: ^Run) -> (input: [dr.PLAYERS]dr.Input) {
	tick := run.simulation.tick + 1
	for slot in 0 ..< dr.PLAYERS do input[slot] = dr.scripted_input(7, slot, tick, &run.simulation.state)
	return
}

// The ship of whoever holds `slot` (nil: nobody).
ship_in_slot :: proc(run: ^Run, slot: int) -> ^dr.Ship {
	players := &run.simulation.state.players
	return sim.player_data(players, sim.player_in_slot(players, slot))
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
	ship := ship_in_slot(&run, 0)
	physics.body_set_transform(world.phys, ship.body, {gate.x - 1.5, gate.y, 0}, {0, 0, 0, 1})
	physics.body_set_linear_velocity(world.phys, ship.body, {})
	physics.body_set_angular_velocity(world.phys, ship.body, {})
	physics.body_set_linear_velocity_2d(world.phys, ship.body, {6, 0})
	physics.body_set_angular_velocity_2d(world.phys, ship.body, 0)
	setup_done(&run)
	for _ in 0 ..< 32 {
		step(&run, {})
		if run.warps > 0 do break
	}
	testing.expect_value(t, run.warps, 1)
	testing.expect_value(t, run.last_warp.player, sim.player_in_slot(run.simulation, 0))
	testing.expect_value(t, run.last_warp.from_gate, 0)
	testing.expect_value(t, run.last_warp.to_gate, 1)
	pos := physics.body_position_2d(world.phys, ship.body)
	to := world.gates[1].pos
	testing.expect_value(t, run.last_warp.position, sim.Position{to.x, to.y, 0})
	offset := pos - to
	testing.expect(t, offset.x * offset.x + offset.y * offset.y < 1, "the ship comes out of the other gate")
	vel := physics.body_linear_velocity_2d(world.phys, ship.body)
	testing.expect(t, vel.x > 3, "it keeps its velocity")
	for _ in 0 ..< 64 do step(&run, {}) // both gates recharge: no warp back
	testing.expect_value(t, run.warps, 1)
	testing.expect_value(t, run.mismatches, 0)
}

// Things are owned by the person, not the slot: A's bullet stays A's while A is away and someone new takes A's slot
// (a new player with a zeroed ship), and A comes back in another slot with their ship as they left it.
@(test)
owners_follow_the_player_not_the_slot :: proc(t: ^testing.T) {
	run := start(2)
	defer finish(&run)
	state := &run.simulation.state
	first := sim.player_in_slot(run.simulation, 0)
	fire: [dr.PLAYERS]dr.Input
	fire[0].buttons = {.Fire}
	step(&run, fire)
	bullet: sim.Handle(dr.Bullet)
	bullets := sim.iterate(&state.bullets)
	for each, handle in sim.next(&bullets) {
		if each.owner == first do bullet = handle
	}
	testing.expect(t, sim.get(&state.bullets, bullet) != nil, "slot 0 fired")
	testing.expect_value(t, sim.player_data(&state.players, first).shots, 1)

	run.seated[0] = 0 // A leaves
	step(&run, {})
	testing.expect(t, !sim.player_present(&state.players, first), "A is away")
	testing.expect_value(t, sim.player_data(&state.players, first).body, physics.Body_Ref{}) // no body while away
	testing.expect_value(t, sim.get(&state.bullets, bullet).owner, first)

	run.seated[0] = 100 // someone new in A's slot
	step(&run, {})
	newcomer := sim.player_in_slot(run.simulation, 0)
	testing.expect(t, newcomer != {} && newcomer != first, "a new player in slot 0")
	testing.expect_value(t, sim.player_data(&state.players, newcomer).shots, 0)
	testing.expect_value(t, sim.get(&state.bullets, bullet).owner, first)

	run.seated[2] = 1 // A comes back in another slot
	step(&run, {})
	testing.expect_value(t, sim.player_in_slot(run.simulation, 2), first)
	ship := sim.player_data(&state.players, first)
	testing.expect_value(t, ship.shots, 1)
	testing.expect(t, ship.body != {}, "A's ship has a body again")
	pos := physics.body_position_2d(run.simulation.world.phys, ship.body)
	testing.expect_value(t, pos, run.simulation.world.spawns[2])
	last := run.spawned[len(run.spawned) - 1]
	testing.expect_value(t, last.player, first)
	testing.expect_value(t, sim.get(&state.bullets, bullet).owner, first)

	for _ in 0 ..< 32 do step(&run, scripted(&run))
	testing.expect_value(t, run.mismatches, 0)
	testing.expect_value(t, run.off_plane, 0)
}
