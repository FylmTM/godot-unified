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
		checkpoints   = {0xd6f4c3443165afc9, 0x8678c73bbeb489b6, 0x676bc6d44ad35dbc, 0x48a986280a0d734e},
		trace         = 0x14efb83fc39f344b,
		snapshot      = 0x5c5eb54055b38ce1,
		log           = 0xe2301237ad4788e5,
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
a_bad_session_log_replays :: proc(t: ^testing.T) {scenarios.session_log_replays(t, &SUITE, 4, .Bad)}
@(test)
a_late_joiner_agrees :: proc(t: ^testing.T) {scenarios.late_join_agrees(t, &SUITE, .Wan, 3, 1200)}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &SUITE)}
