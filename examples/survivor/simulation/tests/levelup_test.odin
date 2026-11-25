// Level-up picks are a command (g.Command_Pick): each pick takes the oldest pending level-up when it is one of that
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

// One sync-tested tick in which slot 0 picks `upgrades`, in order, each for whichever level is oldest (level 0).
pick :: proc(run: ^headless.Run(g.Game), upgrades: ..g.Upgrade) {
	inputs := headless.run_inputs(run)
	for upgrade in upgrades {
		sent := sim.add_command(&inputs, 0, g.Command_Pick{upgrade = upgrade})
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
	player := sim.player_in_slot(run.simulation, 0)
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

// A pick names the level whose offers the HUD showed: the same card pressed twice spends one level-up, in one tick or
// the next, even when the next level offers that card too; a pick naming a level not pending is ignored.
@(test)
a_double_press_spends_one_level_up :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, SEED, seated = 1)
	defer headless.run_end(&run)
	character := sim.slot_data(run.simulation, 0)
	player := sim.player_in_slot(run.simulation, 0)
	// A level whose offers share a card with the next one's.
	level := i32(2)
	shared: g.Upgrade
	found: for ; level < 100; level += 1 {
		next := g.upgrade_offers(SEED, player, level + 1)
		for upgrade in g.upgrade_offers(SEED, player, level) {
			if upgrade == next[0] || upgrade == next[1] {
				shared = upgrade
				break found
			}
		}
	}
	character.level, character.pending_levelups = level + 1, 2 // `level` and the next pending
	headless.run_pin(&run)
	press := g.Command_Pick {
		upgrade = shared,
		level   = u16(level),
	}
	inputs := headless.run_inputs(&run)
	testing.expect(t, sim.add_command(&inputs, 0, press) && sim.add_command(&inputs, 0, press))
	headless.run_step(&run, &inputs)
	testing.expect_value(t, character.pending_levelups, 1)
	headless.run_command(&run, 0, press) // a tick later
	testing.expect_value(t, character.pending_levelups, 1)
	headless.run_command(&run, 0, g.Command_Pick{upgrade = shared, level = u16(level + 2)})
	testing.expect_value(t, character.pending_levelups, 1) // not pending
	for _ in 0 ..< 16 do headless.run_step(&run)
	scenarios.expect_synced(t, &run)
}
