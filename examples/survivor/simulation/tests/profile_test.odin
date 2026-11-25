// What each system of a tick costs, holding the bench's 1000 enemies: `uni test survivor --long` logs it. A profile,
// not a check: it fails only if the run cannot hold its population.
package test_survivor

// Used only by the LONG build's profile.
@(require) import "core:log"
@(require) import "core:testing"
@(require) import "core:time"

@(require) import g "../survivor"
import "unified:headless/scenarios"
@(require) import "unified:physics"
@(require) import "unified:sim"

when scenarios.LONG {
	PROFILE_TICKS :: 600

	System :: enum {
		Players,
		Upgrades,
		Spawn,
		Steer,
		Contact,
		Fire,
		Projectiles,
		Barrels,
		Kills,
		Gems,
		Level_Up,
		Physics,
		Read_Back,
		Phase,
	}

	profile_spent: [System]time.Duration

	// g.tick, each system timed.
	profiled_tick :: proc(t: ^g.Tick) {
		timed :: proc(system: System, run: proc(t: ^g.Tick), t: ^g.Tick) {
			start := time.tick_now()
			run(t)
			profile_spent[system] += time.tick_since(start)
		}
		timed(.Players, g.update_players, t)
		timed(.Upgrades, g.pick_upgrades, t)
		timed(.Spawn, g.spawn_waves, t)
		timed(.Steer, g.steer_enemies, t)
		timed(.Contact, g.hurt_players, t)
		timed(.Fire, g.fire, t)
		timed(.Projectiles, g.move_projectiles, t)
		timed(.Barrels, g.explode_barrels, t)
		timed(.Kills, g.kill_enemies, t)
		timed(.Gems, g.collect_gems, t)
		timed(.Level_Up, g.level_up, t)
		timed(.Physics, proc(t: ^g.Tick) {physics.step(t.world.phys)}, t)
		timed(.Read_Back, g.read_back, t)
		timed(.Phase, g.advance_phase, t)
	}

	@(test)
	the_systems_profile :: proc(t: ^testing.T) {
		game := g.GAME_STRESS
		game.tick = profiled_tick
		simulation := sim.create_bench(&game, 1, game.setup, 1000)
		defer sim.destroy(simulation)
		inputs: g.Inputs
		for slot in 0 ..< g.PLAYERS do sim.seat(&inputs, simulation, slot, slot + 1)
		sim.step(simulation, &inputs) // the joins
		profile_spent = {}
		for _ in 0 ..< PROFILE_TICKS {
			inputs = {}
			inputs.present = {0, 1, 2, 3}
			sim.step(simulation, &inputs)
		}
		testing.expectf(t, simulation.state.enemies.count >= 900, "the population: %d", simulation.state.enemies.count)
		total: time.Duration
		for spent in profile_spent do total += spent
		log.infof("survivor's systems at %d enemies, mean per tick:", simulation.state.enemies.count)
		for spent, system in profile_spent {
			log.infof(
				"  %-12v %7.1f us  %4.1f%%",
				system,
				time.duration_microseconds(spent) / PROFILE_TICKS,
				100 * f64(spent) / f64(total),
			)
		}
	}
}
