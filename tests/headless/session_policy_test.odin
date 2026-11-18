// Sessions on the virtual clock that check the netcode's policies end to end: inputs keep counting past the
// round-trip ceiling, the input delay stays at its floor while the round trip fits the window. (Desync detection:
// tests/scenarios, the seeded-bug eval.)
package test_headless

import "core:testing"

import "unified:headless"

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
	result := headless.session_run(&HEADLESS, cfg)
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
	result := headless.session_run(&HEADLESS, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.ok)
	for client in result.clients {
		testing.expect_value(t, client.delay, 1)
		testing.expect_value(t, client.stats.stall_ticks, 0)
	}
}
