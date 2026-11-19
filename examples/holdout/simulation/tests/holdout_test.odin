// holdout's own rules, played offline by the scripted players (the sim alone, no sync-test: the suite has those).
package test_holdout

import "core:fmt"
import "core:testing"

import g "../holdout"
import "unified:sim"

// What a scripted run did, from its events and state.
Played :: struct {
	shots, shot_hits, headshots, kills, grenades, explosions, bolts, core_hits, downs, revives, respawns: int,
	waves_started, waves_cleared, victories, defeats, lobbies:                                            int,
	max_enemies:                                                                                          int,
	on_deck, in_trench:                                                                                   int, // enemy-ticks on the deck, in the trench
}

// `players` scripted players from tick 1 for `ticks` ticks (seed 7).
play :: proc(players: int, ticks: u32, each: proc(simulation: ^g.Sim, played: ^Played) = nil) -> (played: Played) {
	simulation := sim.create(&g.GAME, 7)
	defer sim.destroy(simulation)
	for tick in 1 ..= ticks {
		inputs: g.Inputs
		for slot in 0 ..< players {
			if tick == 1 do sim.join(&inputs, slot, slot + 1)
			inputs.input[slot] = sim.scripted_player_input(&g.GAME, 7, slot, tick, &simulation.state)
		}
		sim.step(simulation, &inputs)
		for &raw in sim.events_at(simulation, tick) {
			switch event in sim.event_value(&raw, g.Event) {
			case g.Event_Shot:
				played.shots += 1
				played.shot_hits += int(event.hit)
			case g.Event_Enemy_Hit:
				played.headshots += int(event.headshot)
			case g.Event_Enemy_Died:
				played.kills += 1
			case g.Event_Grenade_Thrown:
				played.grenades += 1
			case g.Event_Explosion:
				played.explosions += 1
			case g.Event_Bolt_Fired:
				played.bolts += 1
			case g.Event_Core_Hit:
				played.core_hits += 1
			case g.Event_Player_Downed:
				played.downs += 1
			case g.Event_Player_Revived:
				played.revives += 1
			case g.Event_Player_Respawned:
				played.respawns += 1
			case g.Event_Wave_Started:
				played.waves_started += 1
			case g.Event_Wave_Cleared:
				played.waves_cleared += 1
			case g.Event_Victory:
				played.victories += 1
			case g.Event_Core_Destroyed:
				played.defeats += 1
			case g.Event_Lobby:
				played.lobbies += 1
			case sim.Event_Player_Joined, sim.Event_Player_Left, g.Event_Player_Hurt, g.Event_Countdown:
			}
		}
		played.max_enemies = max(played.max_enemies, int(simulation.state.enemies.count))
		enemies := sim.iterate(&simulation.state.enemies)
		for enemy in sim.next(&enemies) {
			played.on_deck += int(enemy.pos.y > 3)
			played.in_trench += int(enemy.pos.y < -2)
		}
		if each != nil do each(simulation, &played)
	}
	return
}

@(test)
diag :: proc(t: ^testing.T) {
	played := play(4, 64 * 240, proc(simulation: ^g.Sim, played: ^Played) {
		if simulation.tick % 1024 == 0 {
			fmt.println(
				simulation.tick,
				simulation.state.phase,
				simulation.state.wave,
				simulation.state.enemies.count,
				simulation.state.core_hp,
				simulation.state.kills,
			)
		}
	})
	fmt.printf("%#v\n", played)
}
