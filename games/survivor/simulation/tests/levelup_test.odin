// Level-up picks are a command (g.Cmd_Pick): each pick takes the oldest pending level-up when it is one of that
// level's two offers (g.upgrade_offers), in order; a pick with nothing pending, or not offered, is ignored. That a
// command reaches the sim exactly once, and never with a value that is no Upgrade, is the library's (tests/sim,
// tests/netcode).
package test_survivor

import "core:testing"

import g "../survivor"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:sim"

SEED :: 5

// One sync-tested tick in which slot 0 picks `upgrades`, in order.
pick :: proc(run: ^headless.Run(g.Game), upgrades: ..g.Upgrade) {
	inputs := headless.run_inputs(run)
	for upgrade in upgrades {
		sent := sim.add_command(&inputs, 0, g.Cmd_Pick{upgrade})
		assert(sent)
	}
	headless.run_step(run, &inputs)
}

// The upgrade a level-up does not offer.
not_offered :: proc(offers: [2]g.Upgrade) -> g.Upgrade {
	for upgrade in g.Upgrade do if upgrade != offers[0] && upgrade != offers[1] do return upgrade
	unreachable()
}

@(test)
each_pick_takes_one_pending_level_up :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, SEED, seated = 1)
	defer headless.run_end(&run)
	character := sim.slot_data(run.simulation, 0)
	player := run.simulation.state.players.slots[0]
	character.level = 4
	character.pending_levelups = 3 // levels 2, 3 and 4
	headless.run_pin(&run)
	offers := [5][2]g.Upgrade{}
	for level in i32(2) ..= 4 {
		offers[level] = g.upgrade_offers(SEED, player, level)
		testing.expect(t, offers[level][0] != offers[level][1], "two different upgrades")
		testing.expect_value(t, offers[level], g.upgrade_offers(SEED, player, level)) // any time it is asked
	}

	pick(&run, not_offered(offers[2]))
	testing.expect_value(t, character.pending_levelups, 3) // not offered: ignored

	pick(&run, offers[2][1])
	testing.expect_value(t, character.pending_levelups, 2)

	// Two picks in one tick take two level-ups, in order; a third with nothing left is ignored.
	pick(&run, offers[3][0], offers[4][1], offers[4][0])
	testing.expect_value(t, character.pending_levelups, 0)
	testing.expect_value(
		t,
		character.damage_bonus,
		g.DAMAGE_LEVELUP *
		i32(int(offers[2][1] == .Damage) + int(offers[3][0] == .Damage) + int(offers[4][1] == .Damage)),
	)
	scenarios.expect_synced(t, &run)
}
