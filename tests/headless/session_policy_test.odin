// Sessions on the virtual clock that check the netcode's policies end to end: a desync is detected and reported
// to everyone with a typed detail, inputs keep counting past the round-trip ceiling, the input delay stays at the
// game's floor while the round trip fits the window.
package test_headless

import "core:strings"
import "core:testing"

import "../toy"
import "unified:headless"
import "unified:netcode"

// The toy with a rule that reads the World (not rolled back, not hashed): player 0 scores a point on every 50th
// call of `tick`. A client that rolls back calls it more often, so the clients' states part.
@(private)
reads_world_game :: proc() -> toy.Game {
	game := toy.GAME
	game.tick = proc(tick: ^toy.Tick) {
		toy.tick(tick)
		if data := toy.in_slot(tick.state, 0); tick.world.ticks_run % 50 == 0 && data != nil do data.score += 1
	}
	return game
}

@(test)
a_desync_is_detected_and_reported :: proc(t: ^testing.T) {
	game := reads_world_game()
	reads_world := HEADLESS
	reads_world.game = &game
	cfg := headless.Session_Config {
		clients     = 3,
		transport   = "loopback",
		virtual     = true,
		profile     = netcode.PROFILES[1], // wan: rollbacks, so `tick` runs a different number of times
		ticks       = 640,
		seed        = 1,
		late_player = -1,
	}
	result := headless.session_run(&reads_world, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.desyncs > 0)
	testing.expect(t, !result.ok) // a desync fails the session
	testing.expectf(
		t,
		result.desync.tick > 0 && result.desync.tick % 16 == 0,
		"first desync at tick %d",
		result.desync.tick,
	)
	testing.expect(t, result.desync.diverged != {} && card(result.desync.diverged) < cfg.clients)
	// The typed report: two players' snapshots of that tick, diffed table by table.
	testing.expectf(
		t,
		strings.contains(result.desync.detail, "players.data[0].score"),
		"the detail names the field: %q",
		result.desync.detail,
	)
	for client in result.clients {
		testing.expectf(t, client.desyncs > 0, "player %d was not told", client.slot)
		testing.expect(t, !client.ok)
	}
	// The same rule on an ideal network: nobody rolls back, `tick` runs as often everywhere, no desync.
	cfg.profile = netcode.PROFILES[0]
	ideal := headless.session_run(&reads_world, cfg)
	defer headless.session_result_destroy(&ideal)
	testing.expect_value(t, ideal.desyncs, 0)
	testing.expect(t, ideal.ok)
}

// Past the round-trip ceiling (400 ms, 200 ms each way: the prediction needs ~26 ticks, the window allows 14) the
// sim stalls, but the inputs are sampled and sent on the clock, so they reach the relay in time. Before the #8
// sitting the clock stalled with the sim: 2,322 of these 2,400 inputs were replaced.
@(test)
inputs_count_past_the_round_trip_ceiling :: proc(t: ^testing.T) {
	cfg := headless.Session_Config {
		clients = 2,
		transport = "loopback",
		virtual = true,
		profile = {name = "400 ms", latency = 200_000},
		ticks = 1200,
		seed = 1,
		late_player = -1,
	}
	result := headless.session_run(&HEADLESS, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.ok)
	testing.expectf(t, result.replaced == 0, "%d of %d inputs replaced", result.replaced, 2 * cfg.ticks)
	for client in result.clients {
		testing.expectf(t, client.stall_ticks > 0, "player %d never stalled: not past the ceiling", client.slot)
		testing.expect_value(t, client.delay, 7) // the most: 100 ms
	}
}

// Within the window the delay stays at its floor: 1 tick at 100 ms round trip.
@(test)
input_delay_stays_at_the_floor_within_the_window :: proc(t: ^testing.T) {
	cfg := headless.Session_Config {
		clients = 2,
		transport = "loopback",
		virtual = true,
		profile = {name = "100 ms", latency = 50_000},
		ticks = 640,
		seed = 1,
		late_player = -1,
	}
	result := headless.session_run(&HEADLESS, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.ok)
	for client in result.clients {
		testing.expect_value(t, client.delay, 1)
		testing.expect_value(t, client.stall_ticks, 0)
	}
}
