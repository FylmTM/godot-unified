// L2 netcode tests of the client's timing policy on the toy: a game's least input delay, the round-trip ceiling.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"

// Players who tap Spawn for two ticks every 16 (each slot at its own phase) and never move: a wrong guess on every
// press and every release.
tap_hooks :: proc(watch: ^Watch) -> Hooks {
	hooks := hooks_for(watch)
	hooks.sample = proc(user: rawptr, local, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
		return {buttons = {.Spawn} if (tick + u32(slot) * 5) % 16 < 2 else {}}
	}
	hooks.commands = nil
	return hooks
}

// The figures of a tapping session: every client's rollbacks and re-simulated ticks summed, the least and the largest
// input delay any client had on any step, the first client's checksums and the relay's recording (tap_destroy).
Tap_Session :: struct {
	rollbacks, resim:     int,
	delay_min, delay_max: u32,
	checksums:            [dynamic][2]u64,
	recording:            [dynamic]u8,
}

// A session of three tapping clients on `wan` playing `game`, 1280 ticks, recorded; every client verifies every tick,
// none of its inputs replaced, and they agree.
tap_session :: proc(t: ^testing.T, game: ^toy.Game) -> (result: Tap_Session) {
	session: Net
	net_make_relay(&session, 3, 1280, record = true, game = game)
	defer net_destroy(&session)
	for endpoint in 1 ..= 3 {
		net_join(&session, game = game, config = Client_Config{}, hooks = tap_hooks(&session.watch[endpoint]))
	}
	result.delay_min = max(u32)
	delays := proc(session: ^Net, user: rawptr) -> bool {
		result := (^Tap_Session)(user)
		for client in session.clients {
			if !client.started do continue
			result.delay_min = min(result.delay_min, client.delay)
			result.delay_max = max(result.delay_max, client.delay)
		}
		return false
	}
	net_run(&session, 40, all_done, each = delays, user = &result)
	for client in session.clients {
		testing.expect_value(t, client.verified, u32(1280))
		testing.expect_value(t, client.stats.own_replaced, 0)
		result.rollbacks += client.stats.rollbacks
		result.resim += client.stats.resim_ticks
	}
	expect_agree(t, &session)
	netcode.relay_end_recording(session.relay)
	append(&result.checksums, ..session.clients[0].checksums[:])
	result.recording, session.recording = session.recording, {}
	return
}

// Frees a tapping session's checksums and recording.
tap_destroy :: proc(result: ^Tap_Session) {
	delete(result.checksums)
	delete(result.recording)
}

// A game's least input delay is the client's floor: the delay never goes below it. A tick or two more of it leaves as
// many wrong guesses (the inputs change as often) and makes each correction reach less far back.
@(test)
a_games_least_input_delay_is_the_floor :: proc(t: ^testing.T) {
	game := toy.GAME // each test its own copy: tests run in parallel
	default := tap_session(t, &game)
	defer tap_destroy(&default)
	testing.expect_value(t, default.delay_min, u32(1))
	game.input_delay_min_ticks = 3
	floor := tap_session(t, &game)
	defer tap_destroy(&floor)
	testing.expect_value(t, floor.delay_min, u32(3))
	// As many wrong guesses, up to the start players' joins: they become present one per tick, and a join the relay
	// finalized before a client predicted that tick is no guess at one floor and a wrong one at the other.
	testing.expectf(
		t,
		abs(int(floor.rollbacks) - int(default.rollbacks)) <= toy.PLAYERS,
		"rollbacks: %d at a floor of 3, %d at 1",
		floor.rollbacks,
		default.rollbacks,
	)
	testing.expectf(
		t,
		floor.resim * 10 <= default.resim * 8,
		"re-simulated ticks: %d at a floor of 3, %d at 1",
		floor.resim,
		default.resim,
	)
}

// The floor is checked against the delay ceiling: 0 (one tick) up to the ceiling plays, below or past it the netcode
// refuses the game (relay_create panics with the reason; the Godot host reports it).
@(test)
the_least_input_delay_is_bounded_by_the_ceiling :: proc(t: ^testing.T) {
	for tick_hz in ([]int{32, 64, 128}) {
		game := toy.GAME
		game.tick_hz = tick_hz
		ceiling := int(netcode.timing_of(tick_hz).max_delay)
		for floor in ([]int{0, 1, ceiling}) {
			game.input_delay_min_ticks = floor
			testing.expectf(t, netcode.game_violation(&game) == "", "%d Hz, floor %d", tick_hz, floor)
			timing := netcode.timing_of(tick_hz, floor)
			testing.expect_value(t, timing.min_delay, u32(max(floor, 1)))
			// the floor holds at every round trip, and the ceiling is still the ceiling
			testing.expect_value(t, netcode.want_delay(0, timing, timing.min_delay), timing.min_delay)
			testing.expect_value(t, netcode.want_delay(1e6, timing, timing.min_delay), timing.max_delay)
		}
		for floor in ([]int{-1, ceiling + 1}) {
			game.input_delay_min_ticks = floor
			testing.expectf(t, netcode.game_violation(&game) != "", "%d Hz, floor %d refused", tick_hz, floor)
		}
	}
}

// The round-trip ceiling is where the delay policy runs out: at it the delay is the ceiling's and the prediction stays
// inside the cap; a microsecond past it the policy would want one tick more than the ceiling. A floor changes neither.
@(test)
the_round_trip_ceiling_is_where_the_delay_runs_out :: proc(t: ^testing.T) {
	for tick_hz in ([]int{32, 64, 128}) {
		for floor in ([]int{0, 3}) {
			timing := netcode.timing_of(tick_hz, floor)
			ceiling := netcode.round_trip_ceiling_us(timing)
			needed := proc(rtt_us: f64, timing: netcode.Timing) -> i64 {
				return(
					i64(netcode.ceil_ticks(rtt_us + netcode.DELAY_MARGIN_US, timing.tick_us)) +
					1 -
					i64(timing.prediction_cap) \
				)
			}
			testing.expect_value(t, needed(ceiling, timing), i64(timing.max_delay))
			testing.expect_value(t, needed(ceiling + 1, timing), i64(timing.max_delay) + 1)
			testing.expectf(t, ceiling > 300_000 && ceiling < 340_000, "%d Hz: %.1f ms", tick_hz, ceiling / 1000)
			// the leads cover a round trip at the ceiling plus the tolerance; the stamp lead stays inside INPUT_RING
			lead_needed := ceiling + netcode.TOLERANCE_MS * 1000
			testing.expect(t, f64(netcode.START_LEAD_MS) * 1000 >= lead_needed)
			testing.expect(t, f64(netcode.JOIN_LEAD_MS) * 1000 >= lead_needed)
			testing.expect(t, netcode.stamp_ahead(ceiling, timing) * 4 <= netcode.INPUT_RING)
		}
	}
}
