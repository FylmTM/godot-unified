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
scenario_tick :: proc(
	s: ^survivor.State,
	w: ^survivor.World,
	t: u32,
	inputs: ^survivor.Inputs,
	ev: ^[dynamic]sim.Event,
) {
	if s.phase == .Match {
		if t % 23 == 0 {
			it := &s.items[BARRELS[(t / 23) % 8]]
			if it.alive {
				it.hp = 0 // explodes this tick
			}
		}
		if t % 37 == 0 {
			survivor.damage_player(s, w, int(t / 37) % survivor.MAX_PLAYERS, 1000, ev)
		}
		if t % 500 == 0 {
			for p in 0 ..< survivor.MAX_PLAYERS {
				survivor.damage_player(s, w, p, 1000, ev) // everyone: match over, then a reset
			}
		}
	}
	survivor.tick(s, w, t, inputs, ev)
}

SCENARIO := survivor.Game {
	name          = "survivor-scenario",
	tick_hz       = survivor.TICK_HZ,
	world_create  = survivor.world_create,
	world_destroy = survivor.world_destroy,
	extras        = survivor.GAME.extras,
	init          = survivor.GAME_STRESS.init, // the dense stress spawner
	tick          = scenario_tick,
	event_names   = survivor.EVENT_NAMES,
}

Counts :: struct {
	explosions, deaths, respawns, overs, starts: int,
}

count :: proc(c: ^Counts, events: []sim.Event) {
	for e in events {
		#partial switch survivor.Event_Kind(e.kind) {
		case .Barrel_Exploded:
			c.explosions += 1
		case .Player_Died:
			c.deaths += 1
		case .Player_Respawned:
			c.respawns += 1
		case .Match_Over:
			c.overs += 1
		case .Match_Started:
			c.starts += 1
		}
	}
}

scripted :: proc(s: ^survivor.Sim, t: u32) -> (in_: survivor.Inputs) {
	in_.present = {0, 1, 2, 3}
	for p in 0 ..< survivor.MAX_PLAYERS {
		in_.input[p] = survivor.script(s.seed, p, t, &s.state)
	}
	return
}

@(test)
scenario_synctest :: proc(t: ^testing.T) {
	TICKS :: 1600
	for window in ([]u32{8, 13}) {
		s := sim.create(&SCENARIO, 11)
		defer sim.destroy(s)
		recorded := make([]survivor.Inputs, TICKS + 1)
		forward := make([]u64, TICKS + 1)
		defer delete(recorded)
		defer delete(forward)
		c: Counts
		mismatches := 0
		for tt in 1 ..= u32(TICKS) {
			recorded[tt] = scripted(s, tt)
			sim.step(s, &recorded[tt])
			forward[tt] = sim.checksum(s)
			count(&c, sim.events_at(s, tt))
			if tt < window {
				continue
			}
			if !sim.restore(s, tt - window) {
				mismatches += 1
				continue
			}
			for u in tt - window + 1 ..= tt {
				sim.step(s, &recorded[u])
				if sim.checksum(s) != forward[u] {
					mismatches += 1
				}
			}
		}
		testing.expectf(t, mismatches == 0, "window %d: %d mismatches", window, mismatches)
		testing.expectf(t, c.explosions >= 20, "explosions %d", c.explosions)
		testing.expectf(t, c.deaths >= 12 && c.respawns >= 10, "deaths %d, respawns %d", c.deaths, c.respawns)
		testing.expectf(t, c.overs >= 2 && c.starts >= 3, "overs %d, starts %d", c.overs, c.starts)
	}
}

Client :: netcode.Client(survivor.State, survivor.Input, survivor.World, survivor.MAX_PLAYERS)

@(test)
scenario_networked :: proc(t: ^testing.T) {
	TICKS :: 900
	hooks := netcode.Hooks(survivor.State, survivor.Input, survivor.World, survivor.MAX_PLAYERS) {
		sample = proc(user: rawptr, slot: int, tick: u32, state: ^survivor.State) -> survivor.Input {
			return survivor.script(13, slot, tick, state)
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
	for &c, i in clients {
		link := netcode.netsim_wrap(
			netcode.loopback_link(hub, netcode.Peer(i + 1)),
			netcode.PROFILES[2],
			u32(i + 1) * 7919,
			&clock,
		)
		c = netcode.client_create(&SCENARIO, {slot = -1, quiet = true}, link, hooks)
	}
	defer for c in clients {
		netcode.client_destroy(c)
	}
	for clock.now < 1_000_000 + 60_000_000 {
		clock.now += 500
		netcode.host_step(host, clock.now)
		done := netcode.host_finished(host)
		for c in clients {
			netcode.client_step(c, clock.now)
			done &&= c.status == .Disconnected
		}
		if done {
			break
		}
	}
	testing.expect_value(t, host.client.verified, TICKS)
	testing.expect_value(t, host.relay.desyncs, 0)
	rollbacks := 0
	for c in clients {
		testing.expect_value(t, c.verified, TICKS)
		rollbacks += c.rollbacks
		for e in c.checksums {
			for r in host.client.checksums {
				if r[0] == e[0] {
					testing.expectf(t, r[1] == e[1], "slot %d disagrees at tick %d", c.slot, e[0])
				}
			}
		}
	}
	testing.expect(t, rollbacks > 0)
	testing.expect(t, host.relay.log.ticks[TICKS - 1].present == {0, 1, 2, 3})
}
