package test_scenarios

import "core:testing"

import "../toy"
import "unified:headless"

// The toy's save changes several times over the suite's run, so each session scenario's check that every client saved
// what the relay's log replays to (Game.save on verified ticks only) compares real saves.
@(test)
the_toy_saves_now_and_then :: proc(t: ^testing.T) {
	result := headless.run_sim(&toy.GAME, SUITE.ticks, SUITE.seed, SUITE.players)
	testing.expectf(t, result.saves >= 3 && result.save_hash != 0, "%d saves", result.saves)
}
