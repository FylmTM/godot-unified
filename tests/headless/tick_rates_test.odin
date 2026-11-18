// Sessions on the virtual clock at the tick rates and Input widths a game may choose, not only the toy's 64 Hz: the
// timing formulas (tests/netcode/delay_test.odin) give each rate its own windows in ticks, and a window that holds at
// 64 Hz may not at 128 (the client's own inputs: 32 of them are 500 ms at 64 Hz, 250 ms at 128).
package test_headless

import "core:log"
import "core:testing"

import "unified:headless"
import "unified:netcode"
import "unified:sim"

// A game of plain Inputs: `B` bytes, of which the script changes `CHANGING` every tick (0: all of them), the rest
// holding a value per slot; the tick sums them.
Plain_Input :: struct($B: int) {
	bytes: [B]u8,
}

Plain_Data :: struct {
	sum: u32,
}

Plain_State :: struct($B: int, $PLAYERS: int) {
	players: sim.Players(Plain_Data, Plain_Input(B), PLAYERS),
}

Plain_2x8 :: sim.Game(Plain_State(8, 2), Plain_Input(8), sim.No_World, Wide_Event, sim.No_Commands, 2)
Plain_2x64 :: sim.Game(Plain_State(64, 2), Plain_Input(64), sim.No_World, Wide_Event, sim.No_Commands, 2)
Plain_4x8 :: sim.Game(Plain_State(8, 4), Plain_Input(8), sim.No_World, Wide_Event, sim.No_Commands, 4)

plain_game :: proc($G: typeid, $CHANGING: int, tick_hz: int) -> G {
	return G {
		name = "plain",
		version = "1",
		tick_hz = tick_hz,
		tick = proc(t: ^sim.Tick(G)) {
			players := sim.iterate_present(t)
			for data, player in sim.next(&players) {
				for b in sim.input(t, player).bytes do data.sum += u32(b)
			}
		},
		scripted_input = proc(
			seed: u64,
			slot: int,
			tick: u32,
			state: ^sim.part(G, sim.GAME_STATE),
		) -> (
			input: sim.part(G, sim.GAME_INPUT),
		) {
			for &b, i in input.bytes {
				changing := CHANGING == 0 || i < CHANGING
				b = u8((u32(seed) + u32(slot) * 977 + (changing ? tick : 0) * 131 + u32(i) * 17) * 2654435761 >> 24)
			}
			return
		},
	}
}

// A session of `G` at `tick_hz`; the caller destroys the result. Stall ticks summed over the clients.
plain_session :: proc(
	$G: typeid,
	$CHANGING: int,
	tick_hz: int,
	cfg: headless.Session_Config,
) -> (
	result: headless.Session_Result(G),
	stalls: int,
) {
	game := plain_game(G, CHANGING, tick_hz)
	plain := headless.Headless(G) {
		game = &game,
	}
	result = headless.session_run(&plain, cfg)
	for client in result.clients do stalls += client.stall_ticks
	return
}

// 128 Hz and a 300 ms round trip (no loss, no jitter): inside what the input delay and the prediction cap play at
// (30 ticks of cap, 13 of delay), but more of the client's own inputs are unacked (38 ticks) than a packet carries
// (32). Each still rides in a window of packets, so none comes too late.
@(test)
inputs_arrive_in_time_at_128_hz_past_the_input_window :: proc(t: ^testing.T) {
	cfg := headless.Session_Config {
		clients = 2,
		profile = {name = "300 ms", latency = 150_000},
		ticks = 1800,
		seed = 1,
	}
	result, stalls := plain_session(Plain_2x8, 4, 128, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.ok)
	testing.expectf(t, result.replaced == 0, "%d of %d inputs replaced", result.replaced, 2 * cfg.ticks)
	testing.expectf(t, stalls < 100, "%d stall ticks of %d client ticks", stalls, 2 * cfg.ticks)
}

// A 64-byte Input on `bad` at 64 Hz: a packet carries 14 of them (218 ms of ticks, worst case), less than a round
// trip. Four bytes change a tick.
@(test)
wide_inputs_arrive_in_time_on_a_bad_network :: proc(t: ^testing.T) {
	cfg := headless.Session_Config {
		clients = 2,
		profile = netcode.PROFILES[.Bad],
		ticks   = 900,
		seed    = 1,
	}
	result, stalls := plain_session(Plain_2x64, 4, 64, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.ok)
	testing.expectf(t, result.replaced == 0, "%d of %d inputs replaced", result.replaced, 2 * cfg.ticks)
	testing.expectf(t, stalls < 100, "%d stall ticks of %d client ticks", stalls, 2 * cfg.ticks)
}

// 4 players at 32, 64 and 128 Hz on `wan` and `bad`, with a late joiner that joins as a player does: everyone
// verifies every tick, nobody desyncs, no input comes too late, and the joiner is in within its join's budget.
@(test)
sessions_play_at_32_64_and_128_hz :: proc(t: ^testing.T) {
	for tick_hz in ([]int{32, 64, 128}) {
		for network in ([]netcode.Network{.Wan, .Bad}) {
			cfg := headless.Session_Config {
				clients        = 4,
				profile        = netcode.PROFILES[network],
				ticks          = u32(tick_hz * 14),
				seed           = 1,
				late_tick      = u32(tick_hz * 6),
				late_slot      = 3,
				late_as_player = true,
			}
			result, stalls := plain_session(Plain_4x8, 4, tick_hz, cfg)
			defer headless.session_result_destroy(&result)
			log.infof(
				"%d Hz on %s: ok %v, replaced %d, stall ticks %d of %d, the joiner in after %d ms",
				tick_hz,
				cfg.profile.name,
				result.ok,
				result.replaced,
				stalls,
				4 * int(cfg.ticks),
				result.join_us / 1000,
			)
			testing.expectf(t, result.ok, "%d Hz on %s: not ok", tick_hz, cfg.profile.name)
			testing.expectf(
				t,
				result.desyncs == 0,
				"%d Hz on %s: %d desyncs",
				tick_hz,
				cfg.profile.name,
				result.desyncs,
			)
			testing.expectf(
				t,
				result.replaced == 0,
				"%d Hz on %s: %d inputs replaced",
				tick_hz,
				cfg.profile.name,
				result.replaced,
			)
			testing.expectf(
				t,
				result.join_us > 0 && result.join_us < 3_000_000,
				"%d Hz on %s: the joiner in after %d ms",
				tick_hz,
				cfg.profile.name,
				result.join_us / 1000,
			)
		}
	}
}
