package test_minimal_3d

import "core:testing"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:lint"

import g "../minimal_3d"

HEADLESS := headless.Headless(g.Game) {
	game = &g.GAME,
	scripted_input = proc(seed: u64, slot: int, tick: u32, state: ^g.State) -> g.Input {
		return g.scripted_input(seed, slot, tick)
	},
	scripted_commands = g.scripted_commands,
}

SUITE := scenarios.Suite(g.Game) {
	game    = &HEADLESS,
	players = g.PLAYERS,
	seed    = 1,
	ticks   = 600,
}

@(test)
rollback_resimulates_the_same :: proc(t: ^testing.T) {
	result := headless.run_synctest(&HEADLESS, 600, 8, 1, g.PLAYERS)
	testing.expect_value(t, result.mismatches, 0)
}

// A player leaves, someone new takes the slot, and the first player comes back in another one, under rollback on
// every tick: the newcomer is someone else, the one who came back has their handle (and balls) again.
@(test)
presence_churn :: proc(t: ^testing.T) {
	scenarios.presence_churn(t, &SUITE)
}

@(test)
same_seed_same_run :: proc(t: ^testing.T) {
	first := headless.run_sim(&HEADLESS, 600, 7, 2)
	second := headless.run_sim(&HEADLESS, 600, 7, 2)
	testing.expect_value(t, first.final_checksum, second.final_checksum)
}

@(test)
determinism_lint :: proc(t: ^testing.T) {
	lint.check_game(t, #directory + "/..")
}
