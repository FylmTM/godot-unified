// The rollback scenario: a seeded run that forces barrel explosions, player deaths and respawns,
// and whole-match resets (all bodies destroyed and rebuilt) every few ticks, so they land inside
// rollback windows. Checked by sync-test at two window sizes and by a networked session (host +
// remote clients under the `bad` profile, virtual clock) whose checksums must agree.
package test_survivor

import "core:testing"

import "../survivor"
import "unified:netcode"
import "unified:sim"

BARRELS := [8]int{2, 7, 12, 17, 22, 27, 32, 37}

// survivor.tick with forced events by tick number (deterministic: same ticks on every peer).
scenario_tick :: proc(tick: ^survivor.Tick) {
	state, now := tick.state, tick.number
	if state.phase == .Match {
		if now % 23 == 0 {
			item := &state.items[BARRELS[(now / 23) % 8]]
			if item.alive {
				item.hp = 0 // explodes this tick
			}
		}
		if now % 37 == 0 {
			survivor.damage_player(tick, int(now / 37) % survivor.PLAYERS, 1000)
		}
		if now % 500 == 0 {
			for player in 0 ..< survivor.PLAYERS {
				survivor.damage_player(tick, player, 1000) // everyone: match over, then a reset
			}
		}
	}
	survivor.tick(tick)
}

SCENARIO := survivor.Game {
	name          = "survivor-scenario",
	version       = survivor.SIM_VERSION,
	tick_hz       = survivor.TICK_HZ,
	world_create  = survivor.world_create,
	world_destroy = survivor.world_destroy,
	extras        = survivor.GAME.extras,
	init          = survivor.GAME_STRESS.init, // the dense stress spawner
	tick          = scenario_tick,
	events        = survivor.Event,
	commands      = survivor.Command,
}

Counts :: struct {
	explosions, deaths, respawns, overs, starts: int,
}

count :: proc(counts: ^Counts, events: []sim.Raw_Event) {
	for &raw in events {
		#partial switch _ in sim.event_value(&raw, survivor.Event) {
		case survivor.Barrel_Exploded:
			counts.explosions += 1
		case survivor.Player_Died:
			counts.deaths += 1
		case survivor.Player_Respawned:
			counts.respawns += 1
		case survivor.Match_Over:
			counts.overs += 1
		case survivor.Match_Started:
			counts.starts += 1
		}
	}
}

// Scripted inputs and level-up picks of a tick.
scripted :: proc(simulation: ^survivor.Sim, tick: u32) -> (inputs: survivor.Inputs) {
	inputs.present = {0, 1, 2, 3}
	out := sim.Command_Out {
		commands = survivor.Command,
		cap      = sim.COMMANDS_PER_PLAYER,
	}
	defer delete(out.list)
	for player in 0 ..< survivor.PLAYERS {
		inputs.input[player] = survivor.scripted_input(simulation.seed, player, tick, &simulation.state)
		out.player = player
		clear(&out.list)
		survivor.scripted_commands(simulation.seed, player, tick, &simulation.state, &out)
		for raw in out.list {
			sim.add_command(&inputs, raw)
		}
	}
	return
}

@(test)
scenario_synctest :: proc(t: ^testing.T) {
	TICKS :: 1600
	for window in ([]u32{8, 13}) {
		simulation := sim.create(&SCENARIO, 11)
		defer sim.destroy(simulation)
		recorded := make([]survivor.Inputs, TICKS + 1)
		forward := make([]u64, TICKS + 1)
		defer delete(recorded)
		defer delete(forward)
		counts: Counts
		mismatches := 0
		for tick in 1 ..= u32(TICKS) {
			recorded[tick] = scripted(simulation, tick)
			sim.step(simulation, &recorded[tick])
			forward[tick] = sim.checksum(simulation)
			count(&counts, sim.events_at(simulation, tick))
			if tick < window {
				continue
			}
			if !sim.restore(simulation, tick - window) {
				mismatches += 1
				continue
			}
			for resim in tick - window + 1 ..= tick {
				sim.step(simulation, &recorded[resim])
				if sim.checksum(simulation) != forward[resim] {
					mismatches += 1
				}
			}
		}
		testing.expectf(t, mismatches == 0, "window %d: %d mismatches", window, mismatches)
		testing.expectf(t, counts.explosions >= 20, "explosions %d", counts.explosions)
		testing.expectf(
			t,
			counts.deaths >= 12 && counts.respawns >= 10,
			"deaths %d, respawns %d",
			counts.deaths,
			counts.respawns,
		)
		testing.expectf(t, counts.overs >= 2 && counts.starts >= 3, "overs %d, starts %d", counts.overs, counts.starts)
	}
}

Client :: netcode.Client(survivor.State, survivor.Input, survivor.World, survivor.PLAYERS)

@(test)
scenario_networked :: proc(t: ^testing.T) {
	TICKS :: 900
	hooks := netcode.Hooks(survivor.State, survivor.Input, survivor.World, survivor.PLAYERS) {
		sample = proc(user: rawptr, player: int, tick: u32, state: ^survivor.State) -> survivor.Input {
			return survivor.scripted_input(13, player, tick, state)
		},
		commands = proc(user: rawptr, player: int, tick: u32, state: ^survivor.State, out: ^sim.Command_Out) {
			survivor.scripted_commands(13, player, tick, state, out)
		},
	}
	clock := netcode.Virtual_Clock {
		now = 1_000_000,
	}
	hub := netcode.hub_create(4)
	defer netcode.hub_destroy(hub)
	host := netcode.host_create(&SCENARIO, {seed = 13, ticks = TICKS, quiet = true}, hooks)
	defer netcode.host_destroy(host)
	netcode.host_add_link(host, netcode.loopback_link(hub, 0))
	clients: [3]^Client
	for &client, i in clients {
		link := netcode.netsim_wrap(
			netcode.loopback_link(hub, netcode.Peer(i + 1)),
			netcode.PROFILES[2],
			u32(i + 1) * 7919,
			&clock,
		)
		client = netcode.client_create(&SCENARIO, {player = -1, quiet = true}, link, hooks)
	}
	defer for client in clients {
		netcode.client_destroy(client)
	}
	for clock.now < 1_000_000 + 60_000_000 {
		clock.now += 500
		netcode.host_step(host, clock.now)
		done := netcode.host_finished(host)
		for client in clients {
			netcode.client_step(client, clock.now)
			done &&= client.status == .Disconnected
		}
		if done {
			break
		}
	}
	testing.expect_value(t, host.client.verified, TICKS)
	testing.expect_value(t, host.relay.desyncs, 0)
	rollbacks := 0
	for client in clients {
		testing.expect_value(t, client.verified, TICKS)
		rollbacks += client.rollbacks
		for entry in client.checksums {
			for host_entry in host.client.checksums {
				if host_entry[0] == entry[0] {
					testing.expectf(
						t,
						host_entry[1] == entry[1],
						"player %d disagrees at tick %d",
						client.player,
						entry[0],
					)
				}
			}
		}
	}
	testing.expect(t, rollbacks > 0)
	testing.expect(t, host.relay.log.ticks[TICKS - 1].present == {0, 1, 2, 3})
}
