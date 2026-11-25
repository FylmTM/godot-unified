// horde's rule tests, each on a sync-tested run (headless.Run: every step re-simulated 8 ticks back and compared; a
// test that changes the state pins it with headless.run_pin and asserts the run stayed in sync).
package test_horde

import "core:testing"
import "unified:headless"
import "unified:headless/scenarios"
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
	scenarios.expect_synced(t, &run)
}

// An offered upgrade applies to the oldest pending level-up; one not offered is ignored.
@(test)
a_pick_takes_an_offered_upgrade :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	headless.run_step(&run)
	player := sim.player_in_slot(run.simulation, 0)
	hero := sim.slot_data(run.simulation, 0)
	hero.xp = g.xp_to_next(hero.level)
	headless.run_pin(&run)
	headless.run_step(&run)
	testing.expect_value(t, hero.pending_levelups, 1)
	level := g.oldest_pending_level(hero)
	offers := g.upgrade_offers(run.simulation.seed, player, level)
	testing.expect(
		t,
		offers[0] != offers[1] && offers[1] != offers[2] && offers[0] != offers[2],
		"three distinct offers",
	)
	missing: g.Upgrade
	for upgrade in g.Upgrade do if upgrade != offers[0] && upgrade != offers[1] && upgrade != offers[2] {missing = upgrade; break}
	headless.run_command(&run, 0, g.Command_Pick{upgrade = missing, level = u16(level)})
	testing.expect_value(t, hero.pending_levelups, 1)
	headless.run_command(&run, 0, g.Command_Pick{upgrade = offers[1], level = u16(level + 1)})
	testing.expect_value(t, hero.pending_levelups, 1) // a level not pending
	headless.run_command(&run, 0, g.Command_Pick{upgrade = offers[1], level = u16(level)})
	testing.expect_value(t, hero.pending_levelups, 0)
	for _ in 0 ..< 16 do headless.run_step(&run) // past the window: the picks re-simulated
	scenarios.expect_synced(t, &run)
}

// A pick names the level whose offers the HUD showed: the same card pressed twice spends one level-up, whether the
// second press lands in the same tick or a later one, even when the next level offers that card too.
@(test)
a_double_press_spends_one_level_up :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	headless.run_step(&run)
	player := sim.player_in_slot(run.simulation, 0)
	hero := sim.slot_data(run.simulation, 0)
	// A level whose offers share a card with the next one's.
	level := i32(2)
	shared: g.Upgrade
	found: for ; level < 100; level += 1 {
		next := g.upgrade_offers(run.simulation.seed, player, level + 1)
		for upgrade in g.upgrade_offers(run.simulation.seed, player, level) {
			if upgrade == next[0] || upgrade == next[1] || upgrade == next[2] {
				shared = upgrade
				break found
			}
		}
	}
	hero.level, hero.pending_levelups = level + 1, 2 // `level` and the next pending
	headless.run_pin(&run)
	press := g.Command_Pick {
		upgrade = shared,
		level   = u16(level),
	}

	inputs := headless.run_inputs(&run)
	testing.expect(t, sim.add_command(&inputs, 0, press) && sim.add_command(&inputs, 0, press))
	headless.run_step(&run, &inputs)
	testing.expect_value(t, hero.pending_levelups, 1)
	headless.run_command(&run, 0, press) // a tick later
	testing.expect_value(t, hero.pending_levelups, 1)
	for _ in 0 ..< 16 do headless.run_step(&run)
	scenarios.expect_synced(t, &run)
}

// Slot 1's hero is down with its respawn about to run out; `away` unseats its player across that tick.
down_hero :: proc(run: ^headless.Run(g.Game)) -> (hero: ^g.Hero) {
	for _ in 0 ..< 10 do headless.run_step(run)
	hero = sim.slot_data(run.simulation, 1)
	now := sim.game_time(&run.simulation.state, run.simulation.tick)
	hero.alive, hero.hp = false, 0
	hero.respawn = {now, now + 20}
	headless.run_pin(run)
	return
}

// A downed hero stands up when its respawn runs out, and one whose player was away then stands up on their first tick
// back.
@(test)
a_hero_away_when_its_respawn_runs_out_stands_up_on_return :: proc(t: ^testing.T) {
	for away in ([]bool{false, true}) {
		run := headless.run_begin(&g.GAME, 1, seated = 2)
		defer headless.run_end(&run)
		hero := down_hero(&run)
		if away do headless.run_seat(&run, 1, 0)
		for _ in 0 ..< 30 do headless.run_step(&run) // past the respawn's end
		testing.expect_value(t, hero.alive, !away)
		if away {
			headless.run_seat(&run, 1, 2) // the same member, back
			headless.run_step(&run)
			testing.expect_value(t, sim.slot_data(run.simulation, 1), hero) // the kept hero
			testing.expect(t, hero.alive, "stood up on return")
			testing.expect_value(t, hero.hp, hero.hp_max)
		}
		for _ in 0 ..< 16 do headless.run_step(&run)
		scenarios.expect_synced(t, &run)
	}
}

// A player away while the match resets comes back to the new match fresh: level 1, alive, the old upgrades gone.
@(test)
a_hero_away_through_a_reset_starts_the_new_match_fresh :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	hero := down_hero(&run)
	hero.level, hero.bolt_count, hero.pending_levelups = 5, 4, 2
	headless.run_pin(&run)
	headless.run_seat(&run, 1, 0)
	headless.run_step(&run) // slot 1 leaves
	state := &run.simulation.state
	slot0 := sim.slot_data(run.simulation, 0)
	now := sim.game_time(state, run.simulation.tick)
	slot0.alive, slot0.hp = false, 0 // the last present hero down: the match is over
	slot0.respawn = {now, now + 100 * g.TICK_HZ}
	headless.run_pin(&run)
	for _ in 0 ..< 3 do headless.run_step(&run)
	testing.expect_value(t, state.phase, g.Phase.Over)
	for state.phase == .Over do headless.run_step(&run)
	headless.run_seat(&run, 1, 2)
	headless.run_step(&run)
	testing.expect_value(t, sim.slot_data(run.simulation, 1), hero)
	testing.expect(t, hero.alive, "alive in the new match")
	testing.expect_value(t, hero.level, 1)
	testing.expect_value(t, hero.bolt_count, 1)
	testing.expect_value(t, hero.pending_levelups, 0)
	for _ in 0 ..< 16 do headless.run_step(&run)
	scenarios.expect_synced(t, &run)
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
