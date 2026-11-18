// Sessions on the virtual clock that check the netcode's policies end to end: inputs keep counting past the
// round-trip ceiling, the input delay stays at its floor while the round trip fits the window. (Desync detection:
// tests/scenarios, the seeded-bug eval.)
package test_headless

import "../toy"
import "core:log"
import "core:testing"

import "unified:headless"
import "unified:netcode"
import "unified:sim"

// Past the round-trip ceiling (400 ms, 200 ms each way: the prediction needs ~26 ticks, the window allows 14) the
// sim stalls, but the inputs are sampled and sent on the clock, so they reach the relay in time.
@(test)
inputs_count_past_the_round_trip_ceiling :: proc(t: ^testing.T) {
	cfg := headless.Session_Config {
		clients = 2,
		profile = {name = "400 ms", latency = 200_000},
		ticks = 1200,
		seed = 1,
	}
	result := headless.session_run(&toy.GAME, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.ok)
	testing.expectf(t, result.replaced == 0, "%d of %d inputs replaced", result.replaced, 2 * cfg.ticks)
	for client in result.clients {
		testing.expectf(t, client.stats.stall_ticks > 0, "player %d never stalled: not past the ceiling", client.slot)
		testing.expect_value(t, client.delay, 7) // the most: 100 ms
	}
}

// Within the window the delay stays at its floor: 1 tick at 100 ms round trip.
@(test)
input_delay_stays_at_the_floor_within_the_window :: proc(t: ^testing.T) {
	cfg := headless.Session_Config {
		clients = 2,
		profile = {name = "100 ms", latency = 50_000},
		ticks = 640,
		seed = 1,
	}
	result := headless.session_run(&toy.GAME, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.ok)
	for client in result.clients {
		testing.expect_value(t, client.delay, 1)
		testing.expect_value(t, client.stats.stall_ticks, 0)
	}
}

// A game whose tick is wide: 4 players with a 16-byte Input, every byte changing every tick (an analog stick and an
// aim each, in full). A round trip of its ticks takes more than one Finalized message on `bad`.
Wide_Input :: struct {
	bytes: [16]u8,
}

Wide_Data :: struct {
	sum: u32,
}

Wide_State :: struct {
	players: sim.Players(Wide_Data, Wide_Input, 4),
}

Wide_Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}

Wide_Game :: sim.Game(Wide_State, Wide_Input, sim.No_World, Wide_Event, sim.No_Commands, 4)

WIDE_GAME := Wide_Game {
	name = "wide",
	version = "1",
	tick_hz = 64,
	tick = proc(t: ^sim.Tick(Wide_Game)) {
		players := sim.iterate_present(t)
		for data, player in sim.next(&players) {
			for b in sim.input(t, player).bytes do data.sum += u32(b)
		}
	},
	scripted_input = proc(seed: u64, slot: int, tick: u32, state: ^Wide_State) -> (input: Wide_Input) {
		for &b, i in input.bytes {
			b = u8((u32(seed) + u32(slot) * 977 + tick * 131 + u32(i) * 17) * 2654435761 >> 24)
		}
		return
	},
}

// Finalized ticks that don't fit one message still reach a client every tick, not one message of them per round
// trip: on `bad` (a round trip is ~16 ticks, 70 bytes each here) a client keeps up instead of stalling on most ticks.
@(test)
a_wide_tick_keeps_up_on_a_bad_network :: proc(t: ^testing.T) {
	cfg := headless.Session_Config {
		clients = 4,
		profile = netcode.PROFILES[.Bad],
		ticks   = 900,
		seed    = 1,
		churn   = true,
	}
	result := headless.session_run(&WIDE_GAME, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.ok)
	stalls := 0
	for client in result.clients do stalls += client.stall_ticks
	log.infof(
		"stall ticks: %d of %d client ticks; relay sent %d bytes",
		stalls,
		4 * cfg.ticks,
		result.relay_net.bytes_sent,
	)
	testing.expectf(t, stalls < 100, "%d stall ticks of %d client ticks", stalls, 4 * cfg.ticks)
}
