// The stepped Run (src/headless/README.md, Runs): what a game's tests start from.
package test_headless

import "core:testing"

import "../toy"
import "unified:headless"
import "unified:sim"

// run_begin(seated = N): slots 0 ..< N hold members 1 .. N, present from tick 1 after one step of zero inputs; the
// next steps keep them seated.
@(test)
run_begin_seats_and_steps_once :: proc(t: ^testing.T) {
	run := headless.run_begin(&toy.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	testing.expect_value(t, run.simulation.tick, 1)
	testing.expect_value(t, sim.present_count(run.simulation), 2)
	testing.expect_value(t, sim.player_in_slot(run.simulation, 0).id, 1)
	testing.expect_value(t, sim.player_in_slot(run.simulation, 1).id, 2)
	testing.expect_value(t, sim.player_in_slot(run.simulation, 2), sim.Player{})
	inputs := headless.run_inputs(&run)
	headless.run_step(&run, &inputs)
	testing.expect_value(t, sim.present_count(run.simulation), 2)
	testing.expect_value(t, run.mismatches, 0)
	nobody := headless.run_begin(&toy.GAME, 1)
	defer headless.run_end(&nobody)
	testing.expect_value(t, nobody.simulation.tick, 0)
}

// Tick code that writes state only while draws are kept ("skip the work a draw needs" gone wrong) fails the standard
// sync-test: it re-simulates with every draw group on after forward ticks with none. Its report names the first field
// that differs, with the forward run's value and the re-simulation's.
Peek_Hero :: struct {
	pos:  [2]f32,
	warp: u32, // ticks computed while draws were kept: a dev-dependent value in the block
}

Peek_State :: struct {
	ticks:   u32,
	heroes:  [3]Peek_Hero,
	players: sim.Players(u32, sim.No_Profile, toy.Input, 1),
}

Peek_Game :: sim.Game(Peek_State, toy.Input, sim.No_World, toy.Event, sim.No_Commands, sim.No_Setup, sim.No_Profile, 1)

PEEK := Peek_Game {
	name = "peek",
	version = "1",
	tick_hz = 64,
	tick = proc(t: ^sim.Tick(Peek_Game)) {
		t.state.ticks += 1
		if sim.drawing(t) do t.state.heroes[2].warp += 1
	},
}

@(test)
the_sync_test_catches_state_written_while_drawing :: proc(t: ^testing.T) {
	result := headless.run_synctest(&PEEK, 64, 8, 3, 1)
	testing.expectf(t, result.mismatches > 0, "%d mismatches", result.mismatches)
	// tick 8 rolls back to tick 0: tick 1, computed forward without draws, re-simulates with them
	testing.expect_value(t, result.first_tick, 1)
	testing.expect_value(t, result.first_at, 8)
	testing.expect_value(t, result.first_diff, "heroes[2].warp 0 vs 1")
}

// A first mismatch in several fields names the first in field order and counts the rest; one the block doesn't show
// (the tick's events, here) says the State agrees.
@(test)
the_sync_test_names_the_first_differing_field :: proc(t: ^testing.T) {
	several := PEEK
	several.tick = proc(t: ^sim.Tick(Peek_Game)) {
		t.state.ticks += 1
		if !sim.drawing(t) do return
		t.state.heroes[1].pos.y = 2.5
		t.state.heroes[2].warp = 7
		t.state.heroes[0].warp = 3
	}
	result := headless.run_synctest(&several, 16, 8, 3, 1)
	testing.expect_value(t, result.first_tick, 1)
	testing.expect_value(t, result.first_diff, "heroes[0].warp 0 vs 3 (and 2 more fields)")
	evented := PEEK
	evented.tick = proc(t: ^sim.Tick(Peek_Game)) {
		t.state.ticks += 1
		if sim.drawing(t) do sim.emit(t, toy.Event_Expired{})
	}
	quiet := headless.run_synctest(&evented, 16, 8, 3, 1)
	testing.expect_value(t, quiet.first_tick, 1)
	testing.expect_value(t, quiet.first_diff, "the State agrees: the Extra or the tick's events differ")
	testing.expect(t, quiet.problem != "", "the events are the problem")
	clean := headless.run_synctest(&toy.GAME, 64, 8, 3, 2)
	testing.expect_value(t, clean.mismatches, 0)
	testing.expect_value(t, clean.first_diff, "")
}

// The test helpers a game's rule tests use: a run on a Setup, a step with inputs by slot, a step with a slot's
// command, the last event of a type, and a dev command known by its type.
@(test)
run_helpers_step_with_a_setup_inputs_and_commands :: proc(t: ^testing.T) {
	run := headless.run_begin(&toy.GAME, 3, setup = toy.Setup{life_bonus = 4}, seated = 2)
	defer headless.run_end(&run)
	testing.expect_value(t, run.simulation.setup.life_bonus, 4)
	moves: [toy.PLAYERS]toy.Input
	moves[1].dx = 5
	headless.run_step(&run, moves)
	testing.expect_value(t, run.recorded[run.simulation.tick].input[1].dx, 5)
	headless.run_command(&run, 1, toy.Command_Bump{amount = 7})
	testing.expect_value(t, sim.slot_data(run.simulation, 1).bump_sum, 7)
	headless.run_command(&run, moves, 0, toy.Command(toy.Command_Bump{amount = 2}))
	testing.expect_value(t, sim.slot_data(run.simulation, 0).bump_sum, 2)
	testing.expect_value(t, run.recorded[run.simulation.tick].input[1].dx, 5)
	for _ in 0 ..< 200 do headless.run_step(&run)
	testing.expect_value(t, run.mismatches, 0)
	_, found := headless.run_last_event(&run, sim.Event_Player_Left)
	testing.expect(t, !found, "nobody left")
	headless.run_seat(&run, 1, 0)
	headless.run_step(&run)
	left, left_found := headless.run_last_event(&run, sim.Event_Player_Left)
	testing.expect(t, left_found && left.player.id == 2, "the last tick's leave")
	testing.expect(t, !sim.command_is_dev(toy.Command_Bump))
}
