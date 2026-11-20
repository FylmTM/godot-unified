// The toy game's end-to-end suite: every standard scenario of unified:headless/scenarios, and the
// library's own reference run. It is the
// template a game's suite copies (examples/<game>/simulation/tests/suite_test.odin): the standard part
// is the same shape, but a game runs only its minimal set unless `scenarios.LONG`; a game adds its
// own scenarios after it.
package test_scenarios

import "core:strings"
import "core:testing"

import "../toy"
import "unified:headless"
import "unified:headless/scenarios"

SUITE := scenarios.Suite(toy.Game) {
	game    = &toy.GAME,
	players = 4,
	seed    = 42,
	ticks   = 3600,
}

// The reference run (src/headless/README.md, Reference runs).
REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 1800,
	snapshot_tick = 900,
	checkpoints   = {0x158851ac6c2b7bf4, 0x015e8170d3da70ca, 0x7a2fd927919e9c88, 0x86fe7aadc5f51db6},
	trace         = 0x60ab6219320e6a6a,
	snapshot      = 0x0cea544caeb4f4a3,
	log           = 0xbcf914c2614033fa,
	compat        = 0xec8e9314b71d5804,
}

@(test)
rollback_every_tick :: proc(t: ^testing.T) {scenarios.rollback_every_tick(t, &SUITE)}
@(test)
presence_churn :: proc(t: ^testing.T) {scenarios.presence_churn(t, &SUITE)}
@(test)
two_runs_match :: proc(t: ^testing.T) {scenarios.runs_match(t, &SUITE)}

@(test)
two_clients_agree_on_an_ideal_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 2, .Ideal)}
@(test)
two_clients_agree_on_a_wan :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 2, .Wan)}
@(test)
two_clients_agree_on_a_bad_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 2, .Bad)}
@(test)
four_clients_agree_on_an_ideal_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 4, .Ideal)}
@(test)
four_clients_agree_on_a_wan :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 4, .Wan)}
@(test)
four_clients_agree_on_a_bad_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 4, .Bad)}
@(test)
four_clients_agree_when_inputs_change_every_tick :: proc(t: ^testing.T) {scenarios.session_agrees(
		t,
		&SUITE,
		4,
		.Wan,
		churn = true,
	)}

@(test)
a_late_joiner_agrees :: proc(t: ^testing.T) {scenarios.late_join_agrees(t, &SUITE, .Wan, 3, 1200)}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &toy.GAME, REFERENCE)}

// A script that steers by the state it is handed plays another player in a session than offline (each client hands
// it its own prediction): a sync-tested run with script_check (the standard scenarios') asks it again with an older
// state and names it; without, or for a script that answers from (seed, slot, tick), nothing is said.
@(test)
a_script_that_reads_the_state_is_named :: proc(t: ^testing.T) {
	game := toy.GAME
	game.scripted_input = proc(seed: u64, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
		input := toy.scripted_input(seed, slot, tick)
		input.dx = i8(state.spawned % 3) // the state's count, not (seed, slot, tick)
		return input
	}
	result := headless.run_synctest(&game, 200, 8, SUITE.seed, SUITE.players, script_check = true)
	testing.expectf(t, strings.contains(result.problem, "scripted player reads the state"), "%q", result.problem)
	unchecked := headless.run_synctest(&game, 200, 8, SUITE.seed, SUITE.players)
	testing.expect_value(t, unchecked.problem, "")
	clean := headless.run_synctest(&toy.GAME, 200, 8, SUITE.seed, SUITE.players, script_check = true)
	testing.expect_value(t, clean.problem, "")
}

// A script that reads the state it is given, in a session with a late joiner (whose client has no state before its
// snapshot): the harness never hands it a nil one.
@(test)
a_late_joiners_script_always_gets_a_state :: proc(t: ^testing.T) {
	game := toy.GAME
	game.scripted_input = proc(seed: u64, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
		input := toy.scripted_input(seed, slot, tick, state)
		if state.spawned > 1_000_000 do input.dx = 0 // a read of the state: a nil one faults here
		return input
	}
	suite := SUITE
	suite.game = &game
	suite.ticks = 600
	scenarios.late_join_agrees(t, &suite, .Wan, 3, 300)
}
