package test_scenarios

import "core:testing"

import "../toy"
import "unified:headless/scenarios"

// The toy without an Input (sim.No_Input): its commands alone drive it, and every standard scenario holds with nothing
// on the input wire.
STILL_SUITE := scenarios.Suite(toy.Still_Game) {
	game    = &toy.STILL,
	players = 4,
	seed    = 42,
	ticks   = 1200,
}

@(test)
no_input_rollback_every_tick :: proc(t: ^testing.T) {scenarios.rollback_every_tick(t, &STILL_SUITE)}
@(test)
no_input_presence_churn :: proc(t: ^testing.T) {scenarios.presence_churn(t, &STILL_SUITE)}
@(test)
no_input_two_runs_match :: proc(t: ^testing.T) {scenarios.runs_match(t, &STILL_SUITE)}
@(test)
no_input_clients_agree_on_a_bad_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &STILL_SUITE, 4, .Bad)}
@(test)
no_input_late_joiner_agrees :: proc(t: ^testing.T) {scenarios.late_join_agrees(t, &STILL_SUITE, .Wan, 3, 600)}
