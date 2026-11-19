// Sweeps of the paths every review of the core found its bugs in: the join path (late joins, rejoins, a seat that
// flaps) and the input window against its neighbours (the tick rate, the round trip, the widest accepted Input), on
// the virtual clock. Long only (`uni test --long`): they keep those paths covered between reviews.
package test_headless

@(require) import "core:fmt" // used only by the sweeps, which build with --long
import "core:testing"

import "unified:headless"
import "unified:headless/scenarios"
import "unified:netcode"
import "unified:sim"

// The widest Input netcode.game_violation accepts at each player count (a tick of at most 274 bytes); 2 and 32 players
// are Plain_2x116 and Plain_32x4, 8 is Plain_8x26.
Plain_4x56 :: sim.Game(Plain_State(56, 4), Plain_Input(56), sim.No_World, Wide_Event, sim.No_Commands, 4)
Plain_16x11 :: sim.Game(Plain_State(11, 16), Plain_Input(11), sim.No_World, Wide_Event, sim.No_Commands, 16)

// A relay and clients of a plain game on the virtual clock that join and leave when the test says.
Sweep_Net :: struct($G: typeid) {
	game:     G,
	scripted: headless.Scripted_User(G),
	clock:    netcode.Virtual_Clock,
	hub:      ^netcode.Hub,
	relay:    ^netcode.Relay(G),
	clients:  [dynamic]^netcode.Client(G),
}

sweep_make :: proc(net: ^Sweep_Net($G), $CHANGING: int, tick_hz: int, start_players: int) {
	net.game = plain_game(G, CHANGING, tick_hz)
	net.scripted = {&net.game, 1, false}
	net.clock.now = 1_000_000
	net.hub = netcode.hub_create(64)
	net.relay = netcode.relay_create(&net.game, {seed = 1, start_players = start_players})
	netcode.relay_add_link(net.relay, netcode.loopback_link(net.hub, 0))
}

sweep_join :: proc(net: ^Sweep_Net($G), slot: int, network: netcode.Network) -> ^netcode.Client(G) {
	endpoint := len(net.clients) + 1
	link := netcode.netsim_wrap(
		netcode.loopback_link(net.hub, netcode.Peer(endpoint)),
		netcode.PROFILES[network],
		u32(endpoint) * 7919,
		&net.clock,
	)
	client := netcode.client_create(&net.game, {slot = slot}, link, headless.scripted_hooks(&net.scripted))
	append(&net.clients, client)
	return client
}

sweep_run :: proc(net: ^Sweep_Net($G), seconds: f64) {
	end := net.clock.now + i64(seconds * 1e6)
	for net.clock.now < end {
		now := net.clock.now
		wake := netcode.relay_step(net.relay, now)
		for client in net.clients {
			if netcode.client_finished(client) do continue
			wake = min(wake, netcode.client_step(client, now))
		}
		net.clock.now = clamp(wake, now + 1, end)
	}
}

// The client leaves; runs until the relay freed its seat (its Leave arrived), or it finished, 3 s at most.
sweep_leave :: proc(net: ^Sweep_Net($G), client: ^netcode.Client(G)) {
	slot := client.slot
	netcode.client_stop(client, net.clock.now)
	for _ in 0 ..< 1500 {
		if slot >= 0 && !net.relay.seats[slot].connected do break
		if slot < 0 && netcode.client_finished(client) do break
		sweep_run(net, 0.002)
	}
}

sweep_destroy :: proc(net: ^Sweep_Net($G)) {
	for client in net.clients do netcode.client_destroy(client)
	delete(net.clients)
	netcode.relay_destroy(net.relay)
	netcode.hub_destroy(net.hub)
}

// The joiner is Connected, a second behind the relay at most, with no desync.
sweep_expect_in :: proc(
	t: ^testing.T,
	net: ^Sweep_Net($G),
	what: string,
	joiner: ^netcode.Client(G),
	loc := #caller_location,
) -> bool {
	return testing.expectf(
		t,
		joiner.status == .Connected && net.relay.finalized - joiner.verified < u32(net.game.tick_hz),
		"%s: slot %d %v (%s), verified %d of %d, snapshot of %d, first tick %d, desyncs %d",
		what,
		joiner.slot,
		joiner.status,
		joiner.detail,
		joiner.verified,
		net.relay.finalized,
		joiner.snap_tick,
		joiner.first_tick,
		joiner.stats.desyncs,
		loc = loc,
	)
}

// Two start players on `wan` and `bad`, a joiner on `bad` and a second right behind it, a start player (the first
// provider) leaving mid-join in odd rounds, and in every third round the first joiner leaving and its seat taken
// again: every joiner still there ends Connected, close behind the relay, checked, with no desync.
sweep_joins :: proc(t: ^testing.T, $G: typeid, $CHANGING: int, name: string, rounds: int) {
	for tick_hz in ([]int{32, 64, 128}) {
		for k in 0 ..< rounds {
			what := fmt.tprintf("%s at %d Hz, round %d", name, tick_hz, k)
			net := new(Sweep_Net(G))
			defer free(net)
			sweep_make(net, CHANGING, tick_hz, 2)
			defer sweep_destroy(net)
			sweep_join(net, 0, k % 2 == 0 ? .Bad : .Wan)
			sweep_join(net, 1, k % 2 == 0 ? .Wan : .Bad)
			sweep_run(net, 2 + f64(k) * 0.037)
			first := sweep_join(net, -1, .Bad)
			sweep_run(net, 0.15 + f64(k) * 0.04)
			second := sweep_join(net, -1, k % 4 < 2 ? .Bad : .Wan)
			sweep_run(net, 0.05 + f64(k % 5) * 0.1)
			if k % 2 == 1 do netcode.client_stop(net.clients[0], net.clock.now)
			third: ^netcode.Client(G)
			if k % 3 == 2 {
				sweep_leave(net, first)
				sweep_run(net, 0.02 + f64(k) * 0.013)
				third = sweep_join(net, -1, k % 2 == 0 ? .Wan : .Bad)
			}
			sweep_run(net, 16)
			if third == nil do sweep_expect_in(t, net, what, first)
			sweep_expect_in(t, net, what, second)
			if third != nil do sweep_expect_in(t, net, what, third)
			testing.expectf(t, net.relay.desyncs == 0, "%s: %d desyncs", what, net.relay.desyncs)
			testing.expectf(
				t,
				net.relay.unchecked_snapshots == 0,
				"%s: %d joiners let in unchecked",
				what,
				net.relay.unchecked_snapshots,
			)
		}
	}
}

// One seat joined and left five times at short intervals (before its snapshot, during it, after Connected), then a
// last joiner that stays; one start player in even rounds (a 2-player session's only provider), two in odd ones.
sweep_flaps :: proc(t: ^testing.T, $G: typeid, $CHANGING: int, name: string, rounds: int) {
	for tick_hz in ([]int{32, 64, 128}) {
		for k in 0 ..< rounds {
			what := fmt.tprintf("%s at %d Hz, round %d", name, tick_hz, k)
			net := new(Sweep_Net(G))
			defer free(net)
			starters := sim.part(G, sim.GAME_PLAYERS) > 2 ? 1 + k % 2 : 1
			sweep_make(net, CHANGING, tick_hz, starters)
			defer sweep_destroy(net)
			sweep_join(net, 0, k % 4 < 2 ? .Wan : .Bad)
			if starters == 2 do sweep_join(net, 1, .Bad)
			sweep_run(net, 2)
			for flap in 0 ..< 5 {
				joiner := sweep_join(net, -1, flap % 2 == 0 ? .Wan : .Bad)
				sweep_run(net, 0.03 + f64((k * 7 + flap * 13) % 29) * 0.045)
				sweep_leave(net, joiner)
				sweep_run(net, 0.004 + f64((k + flap) % 4) * 0.03)
			}
			last := sweep_join(net, -1, k % 3 == 0 ? .Bad : .Wan)
			sweep_run(net, 12)
			sweep_expect_in(t, net, what, last)
			testing.expectf(t, net.relay.desyncs == 0, "%s: %d desyncs", what, net.relay.desyncs)
		}
	}
}

// The widest accepted Input at 2, 4, 8, 16 and 32 players, every byte changing every tick, at 32, 64 and 128 Hz on
// `wan` and `bad`, with a late joiner that joins as a player: everyone verifies every tick, nobody desyncs, the
// joiner is in, and stalls stay under 10% of the ticks.
sweep_widths :: proc(t: ^testing.T, $G: typeid, name: string, rates: []int) {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	for tick_hz in rates {
		for network in ([]netcode.Network{.Wan, .Bad}) {
			cfg := headless.Session_Config {
				clients        = PLAYERS,
				profile        = netcode.PROFILES[network],
				ticks          = u32(tick_hz * 8),
				seed           = 1,
				late_tick      = u32(tick_hz * 3),
				late_slot      = PLAYERS - 1,
				late_as_player = true,
			}
			result, stalls := plain_session(G, 0, tick_hz, cfg)
			defer headless.session_result_destroy(&result)
			what := fmt.tprintf("%s at %d Hz on %s", name, tick_hz, cfg.profile.name)
			testing.expectf(t, result.ok, "%s: not ok", what)
			testing.expectf(t, result.desyncs == 0, "%s: %d desyncs", what, result.desyncs)
			testing.expectf(t, result.join_us > 0, "%s: the joiner never got in", what)
			testing.expectf(
				t,
				stalls * 10 < PLAYERS * int(cfg.ticks),
				"%s: stall ticks %d of %d",
				what,
				stalls,
				PLAYERS * int(cfg.ticks),
			)
		}
	}
}

// Two players on round trips of 120 to 400 ms, lossless and with loss, at every rate: a narrow Input and the widest
// (whose window is shorter than the input delay at 128 Hz): no input is replaced, but with loss in the first half
// second (a start player whose Welcome was lost: src/netcode/README.md, Relay).
sweep_round_trips :: proc(t: ^testing.T) {
	for tick_hz in ([]int{32, 64, 128}) {
		for latency in ([]i64{60_000, 125_000, 150_000, 200_000}) {
			for loss in ([]u32{0, 80}) {
				cfg := headless.Session_Config {
					clients = 2,
					profile = {
						name    = "round trip",
						latency = latency,
						jitter  = loss != 0 ? 20_000 : 0,
						loss    = loss,
						reorder = loss / 2,
					},
					ticks = u32(tick_hz * 10),
					seed = 1,
				}
				narrow, _ := plain_session(Plain_2x8, 4, tick_hz, cfg)
				defer headless.session_result_destroy(&narrow)
				wide, _ := plain_session(Plain_2x116, 0, tick_hz, cfg)
				defer headless.session_result_destroy(&wide)
				from := loss != 0 ? tick_hz / 2 : 0
				testing.expectf(
					t,
					narrow.ok && replaced_from(&narrow, from) == 0,
					"2 x 8 B at %d Hz, %d ms round trip, loss %d: ok %v, %d replaced",
					tick_hz,
					2 * latency / 1000,
					loss,
					narrow.ok,
					narrow.replaced,
				)
				testing.expectf(
					t,
					wide.ok && replaced_from(&wide, from) == 0,
					"2 x 116 B at %d Hz, %d ms round trip, loss %d: ok %v, %d replaced (tick:slot%s)",
					tick_hz,
					2 * latency / 1000,
					loss,
					wide.ok,
					wide.replaced,
					replaced_ticks(&wide),
				)
			}
		}
	}
}

// The inputs the relay replaced after the first `from` ticks.
replaced_from :: proc(result: ^headless.Session_Result($G), from: int) -> (count: int) {
	for &tick, k in result.log.ticks {
		if k >= from do count += card(tick.replaced)
	}
	return
}

when scenarios.LONG {
	@(test)
	sweep_joins_4x8 :: proc(t: ^testing.T) {sweep_joins(t, Plain_4x8, 4, "4 x 8 B", 6)}
	@(test)
	sweep_joins_4x56 :: proc(t: ^testing.T) {sweep_joins(t, Plain_4x56, 0, "4 x 56 B", 6)}
	@(test)
	sweep_joins_8x26 :: proc(t: ^testing.T) {sweep_joins(t, Plain_8x26, 0, "8 x 26 B", 6)}
	@(test)
	sweep_flaps_2x116 :: proc(t: ^testing.T) {sweep_flaps(t, Plain_2x116, 4, "2 x 116 B", 8)}
	@(test)
	sweep_flaps_4x8 :: proc(t: ^testing.T) {sweep_flaps(t, Plain_4x8, 4, "4 x 8 B", 8)}
	@(test)
	sweep_widths_2 :: proc(t: ^testing.T) {sweep_widths(t, Plain_2x116, "2 x 116 B", {32, 64, 128})}
	@(test)
	sweep_widths_4 :: proc(t: ^testing.T) {sweep_widths(t, Plain_4x56, "4 x 56 B", {32, 64, 128})}
	@(test)
	sweep_widths_8 :: proc(t: ^testing.T) {sweep_widths(t, Plain_8x26, "8 x 26 B", {32, 64, 128})}
	@(test)
	sweep_widths_16 :: proc(t: ^testing.T) {sweep_widths(t, Plain_16x11, "16 x 11 B", {32, 64, 128})}
	@(test)
	sweep_widths_32_at_32_and_64_hz :: proc(t: ^testing.T) {sweep_widths(t, Plain_32x4, "32 x 4 B", {32, 64})}
	@(test)
	sweep_widths_32_at_128_hz :: proc(t: ^testing.T) {sweep_widths(t, Plain_32x4, "32 x 4 B", {128})}
	@(test)
	sweep_input_round_trips :: proc(t: ^testing.T) {sweep_round_trips(t)}
}
