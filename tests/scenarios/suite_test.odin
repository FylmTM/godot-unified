// The toy game's end-to-end suite: every standard scenario of unified:headless/scenarios, and the
// library's own reference run. It is the
// template a game's suite copies (games/<game>/simulation/tests/suite_test.odin): the standard part
// is the same shape, but a game runs only its minimal set unless `scenarios.LONG`; a game adds its
// own scenarios after it.
package test_scenarios

import "core:testing"

import "../toy"
import "unified:headless/scenarios"

SUITE := scenarios.Suite(toy.Game) {
	game = &toy.GAME,
	players = 4,
	seed = 42,
	ticks = 3600,
	ref = {
		seed          = 7,
		players       = 4,
		ticks         = 1800,
		snapshot_tick = 900,
		checkpoints   = {0x3e4fda751648ba91, 0xe07675e224ea5791, 0xcf2f4bd1e72fb042, 0xb8798ac0bf4582d9},
		trace         = 0x162619003528a2d6,
		snapshot      = 0xd0c6940857b4b1a2,
		log           = 0x3ee75e18f3ba27ad,
	},
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
a_late_joiner_agrees :: proc(t: ^testing.T) {scenarios.late_join_agrees(t, &SUITE, .Wan, 3, 1200)}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &SUITE)}
