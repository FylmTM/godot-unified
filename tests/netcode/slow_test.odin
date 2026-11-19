// L2 netcode tests of the slow-link warning (Client_Stats.slow): a client whose round trip is past the game's ceiling
// says so within a second, one under it never does, and the flag doesn't flap at the ceiling.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"

// A remote client behind a live network simulator whose profile the test changes.
@(private = "file")
live_join :: proc(session: ^Net, latency: i64) -> (^Client, ^netcode.Net_Sim) {
	link, netsim := net_link(session, live = true)
	path := netcode.Profile {
		name    = "path",
		latency = latency,
	}
	netcode.netsim_set(netsim, path, path)
	return net_join(session, link = link), netsim
}

// The ceiling the clients judge against (64 Hz: 304.5 ms).
@(private = "file")
ceiling_ms :: proc() -> f64 {
	return netcode.round_trip_ceiling_us(netcode.timing_of(toy.GAME.tick_hz)) / 1000
}

// 340 ms of round trip (past the 304.5 ms ceiling) is slow within a second of the join; `wan` (about 100 ms, jittery)
// never is.
@(test)
a_round_trip_past_the_ceiling_is_slow :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	far, _ := live_join(&session, 170_000)
	near := net_join(&session)
	net_run(&session, 1.5)
	testing.expect_value(t, far.status, netcode.Status.Connected)
	stats := netcode.client_stats(far)
	testing.expectf(t, stats.slow, "340 ms: rtt %.0f ms, ceiling %.0f", stats.rtt_ms, stats.ceiling_ms)
	testing.expect_value(t, stats.slow_changes, 1)
	testing.expect_value(t, stats.ceiling_ms, ceiling_ms())
	net_run(&session, 10)
	testing.expect_value(t, netcode.client_stats(near).slow, false)
	testing.expect_value(t, netcode.client_stats(near).slow_changes, 0)
	testing.expect_value(t, netcode.client_stats(far).slow_changes, 1)
}

// A link that gets better clears the flag only after 2 s under 90% of the ceiling; one that hovers just under the
// ceiling keeps it (no flapping), and one that gets worse again sets it again.
@(test)
the_slow_flag_has_hysteresis :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, netsim := live_join(&session, 170_000)
	net_run(&session, 2)
	testing.expect(t, client.slow)
	hover := netcode.Profile {
		name    = "just under",
		latency = i64(ceiling_ms() * 1000 * 0.95 / 2),
	}
	netcode.netsim_set(netsim, hover, hover)
	net_run(&session, 6)
	testing.expectf(t, client.slow, "95%% of the ceiling: still slow (rtt %.0f ms)", client.rtt_us / 1000)
	fast := netcode.Profile {
		name    = "fast",
		latency = 50_000,
	}
	netcode.netsim_set(netsim, fast, fast)
	net_run(&session, 1)
	testing.expect(t, client.slow) // the average comes down, then 2 s must pass
	net_run(&session, 4)
	testing.expect(t, !client.slow)
	far := netcode.Profile {
		name    = "far again",
		latency = 200_000,
	}
	netcode.netsim_set(netsim, far, far)
	net_run(&session, 3)
	testing.expect(t, client.slow)
	testing.expect_value(t, client.stats.slow_changes, 3)
	expect_agree(t, &session)
}
