// Sessions on the virtual clock at the tick rates and Input widths a game may choose, not only the toy's 64 Hz: the
// timing formulas (tests/netcode/delay_test.odin) give each rate its own windows in ticks, and a window that holds at
// 64 Hz may not at 128 (the client's own inputs: 32 of them are 500 ms at 64 Hz, 250 ms at 128).
package test_headless

import "core:fmt"
import "core:log"
import "core:strings"
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
	players: sim.Players(Plain_Data, sim.No_Profile, Plain_Input(B), PLAYERS),
}

Plain_2x8 :: sim.Game(
	Plain_State(8, 2),
	Plain_Input(8),
	sim.No_World,
	Wide_Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	2,
)
Plain_2x64 :: sim.Game(
	Plain_State(64, 2),
	Plain_Input(64),
	sim.No_World,
	Wide_Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	2,
)
Plain_4x8 :: sim.Game(
	Plain_State(8, 4),
	Plain_Input(8),
	sim.No_World,
	Wide_Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	4,
)
Plain_2x114 :: sim.Game(
	Plain_State(114, 2),
	Plain_Input(114),
	sim.No_World,
	Wide_Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	2,
)

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
	result = headless.session_run(&game, cfg)
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

// The ticks whose inputs the relay replaced, as tick:slot (the first 40).
replaced_ticks :: proc(result: ^headless.Session_Result($G)) -> string {
	out := strings.builder_make(context.temp_allocator)
	listed := 0
	for &tick, k in result.log.ticks {
		for slot in tick.replaced {
			if listed < 40 do fmt.sbprintf(&out, " %d:%d", k + 1, slot)
			listed += 1
		}
	}
	return strings.to_string(out)
}

// The widest Input at 2 players (114 bytes: a packet carries 8) at 128 Hz on round trips of 240 to 300 ms: the input
// delay (11 to 13 ticks) is longer than the window, so the clock's first step samples more inputs than a packet
// carries. The burst rides in messages of its own: none of a player's first inputs is replaced, on a lossless link as
// on `bad`.
@(test)
a_burst_of_inputs_longer_than_the_window_is_sent :: proc(t: ^testing.T) {
	profiles := []netcode.Profile {
		{name = "300 ms", latency = 150_000},
		{name = "240 ms +- 40", latency = 120_000, jitter = 40_000},
		netcode.PROFILES[.Bad],
	}
	for profile in profiles {
		cfg := headless.Session_Config {
			clients = 2,
			profile = profile,
			ticks   = 1280,
			seed    = 1,
		}
		result, stalls := plain_session(Plain_2x114, 4, 128, cfg)
		defer headless.session_result_destroy(&result)
		testing.expectf(t, result.ok, "%s: not ok", profile.name)
		testing.expectf(
			t,
			result.replaced == 0,
			"%s: %d of %d inputs replaced (tick:slot%s), %d stall ticks; the input delay %d",
			profile.name,
			result.replaced,
			2 * cfg.ticks,
			replaced_ticks(&result),
			stalls,
			result.clients[0].delay,
		)
	}
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
// verifies every tick, nobody desyncs, no input comes too late, the joiner is in within its join's budget, and stalls
// stay under 5% of the ticks (`bad`'s round trip is inside every rate's ceiling: the ring's floor gives 32 Hz the
// same 250 ms of prediction as the others).
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
				stalls * 20 < 4 * int(cfg.ticks),
				"%d Hz on %s: stall ticks %d of %d",
				tick_hz,
				cfg.profile.name,
				stalls,
				4 * int(cfg.ticks),
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

Plain_8x26 :: sim.Game(
	Plain_State(26, 8),
	Plain_Input(26),
	sim.No_World,
	Wide_Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	8,
)
Plain_32x4 :: sim.Game(
	Plain_State(4, 32),
	Plain_Input(4),
	sim.No_World,
	Wide_Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	32,
)

// The widest ticks the relay accepts (netcode.game_violation: TICKS_PER_MESSAGE_MIN of them per message), every Input
// byte changing every tick, on `bad`: everyone verifies every tick, and stalls stay a small share of the ticks.
@(test)
the_widest_accepted_ticks_play_on_a_bad_network :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, name: string, result: ^headless.Session_Result($G), stalls, players: int) {
		share := f64(stalls) / f64(players * 900)
		log.infof(
			"%s on bad: stall ticks %d (%.1f%%), %d B per client per tick, %d inputs replaced",
			name,
			stalls,
			100 * share,
			result.relay_net.bytes_sent / players / 900,
			result.replaced,
		)
		testing.expectf(t, result.ok, "%s: not ok", name)
		testing.expectf(t, share < 0.1, "%s: %d stall ticks of %d", name, stalls, players * 900)
	}
	cfg := headless.Session_Config {
		clients = 8,
		profile = netcode.PROFILES[.Bad],
		ticks   = 900,
		seed    = 1,
	}
	wide, wide_stalls := plain_session(Plain_8x26, 0, 64, cfg)
	defer headless.session_result_destroy(&wide)
	check(t, "8 x 26 B", &wide, wide_stalls, 8)
	testing.expectf(t, wide.replaced == 0, "8 x 26 B: %d inputs replaced", wide.replaced)
	cfg.clients = 2
	two, two_stalls := plain_session(Plain_2x114, 0, 64, cfg)
	defer headless.session_result_destroy(&two)
	check(t, "2 x 114 B", &two, two_stalls, 2)
	testing.expectf(t, two.replaced == 0, "2 x 114 B: %d inputs replaced", two.replaced)
	// (32 start players on `bad`: a Welcome lost and resent can come after the start lead, and a player's first
	// inputs with it (src/netcode/README.md, Relay). That is the start, not the stream: inputs are not checked here.)
	cfg.clients = 32
	many, many_stalls := plain_session(Plain_32x4, 0, 64, cfg)
	defer headless.session_result_destroy(&many)
	check(t, "32 x 4 B", &many, many_stalls, 32)
}
