// The session's Setup (difficulty, the saved best wave) and each player's Profile (their role).
package test_survivor

import "core:testing"

import g "../survivor"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:sim"

// Hard scales the burst sizes and the enemies' HP growth; the best wave comes from the Setup.
@(test)
the_setup_sets_difficulty_and_best_wave :: proc(t: ^testing.T) {
	normal := sim.create(&g.GAME, 1)
	defer sim.destroy(normal)
	hard := sim.create(&g.GAME, 1, g.Setup{difficulty = .Hard, best_wave = 6})
	defer sim.destroy(hard)
	play := g.TUNINGS[.Play]
	testing.expect_value(t, normal.state.tuning, play)
	testing.expect_value(t, normal.state.best_wave, 0)
	testing.expect_value(t, hard.state.tuning.spawn_base, play.spawn_base * g.HARD_SPAWN_PCT / 100)
	testing.expect_value(t, hard.state.tuning.hp_pct_per_wave, play.hp_pct_per_wave + g.HARD_HP_PCT_PER_WAVE)
	testing.expect_value(t, hard.state.best_wave, 6)
}

// Each role's perk is there from the player's first tick (no swap a tick later), and the reset keeps the role.
@(test)
a_players_role_is_their_profiles_from_their_first_tick :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 3)
	defer headless.run_end(&run)
	headless.run_seat(&run, 0, 1, g.Profile{role = .Gunner})
	headless.run_seat(&run, 1, 2, g.Profile{role = .Bruiser})
	headless.run_seat(&run, 2, 3, g.Profile{role = .Runner})
	step(&run)
	gunner, bruiser, runner :=
		sim.slot_data(run.simulation, 0), sim.slot_data(run.simulation, 1), sim.slot_data(run.simulation, 2)
	testing.expect_value(t, gunner.role, g.Role.Gunner)
	testing.expect_value(t, gunner.fire_interval, g.FIRE_INTERVAL_TICKS - g.ROLE_FIRE_TICKS)
	testing.expect_value(t, bruiser.damage_bonus, g.ROLE_DAMAGE)
	testing.expect_value(t, runner.speed, g.PLAYER_SPEED + g.ROLE_SPEED)
	testing.expect_value(
		t,
		sim.player_profile(run.simulation, sim.player_in_slot(run.simulation, 2)).role,
		g.Role.Runner,
	)
	for _ in 0 ..< 60 do step(&run)
	scenarios.expect_synced(t, &run)
}
