// horde's rule tests, each on a sync-tested run (headless.Run: every step re-simulated 8 ticks back and compared).
package test_horde

import "core:testing"
import "unified:headless"
import "unified:sim"

import g "../horde"

// A match spawns enemies in waves, the heroes' weapons kill some, and the dead leave gems.
@(test)
waves_come_and_weapons_kill :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	for _ in 0 ..< 20 * g.TICK_HZ do headless.run_step(&run)
	state := &run.simulation.state
	testing.expect(t, state.enemies.count > 0, "enemies spawned")
	testing.expect(t, state.kills > 0, "weapons killed some")
	testing.expect(t, headless.run_events(&run, g.Event_Arc) > 0, "lightning struck")
	testing.expect(t, headless.run_events(&run, g.Event_Bomb_Landed) > 0, "bombs landed")
}

// An offered upgrade applies to the oldest pending level-up; one not offered is ignored.
@(test)
a_pick_takes_an_offered_upgrade :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	headless.run_step(&run)
	player := run.simulation.state.players.slots[0]
	hero := sim.player_data(&run.simulation.state.players, player)
	hero.xp = g.xp_to_next(hero.level)
	headless.run_step(&run)
	testing.expect_value(t, hero.pending_levelups, 1)
	offers := g.upgrade_offers(run.simulation.seed, player, g.oldest_pending_level(hero))
	testing.expect(
		t,
		offers[0] != offers[1] && offers[1] != offers[2] && offers[0] != offers[2],
		"three distinct offers",
	)
	missing: g.Upgrade
	for upgrade in g.Upgrade do if upgrade != offers[0] && upgrade != offers[1] && upgrade != offers[2] {missing = upgrade; break}
	headless.run_command(&run, 0, g.Command_Pick{missing})
	testing.expect_value(t, hero.pending_levelups, 1)
	headless.run_command(&run, 0, g.Command_Pick{offers[1]})
	testing.expect_value(t, hero.pending_levelups, 0)
}

// The bench holds its population and its heroes never go down.
@(test)
the_bench_holds_its_population :: proc(t: ^testing.T) {
	simulation := sim.create(&g.GAME, 1)
	defer sim.destroy(simulation)
	g.bench_prepare(&simulation.state, simulation.world, 1500)
	inputs: g.Inputs
	for slot in 0 ..< g.PLAYERS do sim.seat(&inputs, simulation, slot, slot + 1)
	sim.step(simulation, &inputs) // the joins
	downed := 0
	for _ in 0 ..< 10 * g.TICK_HZ {
		inputs = {}
		inputs.present = {0, 1, 2, 3}
		sim.step(simulation, &inputs)
		for &raw in sim.events_at(simulation, simulation.tick) {
			if _, down := sim.event_value(&raw, g.Event).(g.Event_Hero_Down); down do downed += 1
		}
	}
	testing.expectf(t, simulation.state.enemies.count >= 1400, "the population: %d", simulation.state.enemies.count)
	testing.expect_value(t, downed, 0)
}
