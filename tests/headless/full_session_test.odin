// A full session of 32 (sim.MAX_PLAYERS): the relay's channel keeps netcode.PEERS_SPARE connections beyond its seats,
// for a peer being refused and for one opened only to tell a peer its connection ended. Without them the 33rd player
// was never answered (30 s, then "no answer from the relay") and a freed seat was joined 10 s late after 20 to 55% of
// leaves.
package test_headless

import "core:testing"

import "unified:headless/scenarios"
import "unified:netcode"

// As many players beyond a full session as there are spare connections, all at once: each is told the session is
// full, at once.
@(test)
players_beyond_a_full_session_are_told_it_is_full :: proc(t: ^testing.T) {
	net := new(Sweep_Net(Plain_32x4))
	defer free(net)
	sweep_make(net, 0, 64, 32)
	defer sweep_destroy(net)
	for slot in 0 ..< 32 do sweep_join(net, slot, .Ideal)
	sweep_run(net, 2)
	extras: [netcode.PEERS_SPARE]^netcode.Client(Plain_32x4)
	for &extra in extras do extra = sweep_join(net, -1, .Wan)
	from := net.clock.now
	sweep_run(net, 2)
	for extra, k in extras {
		testing.expectf(
			t,
			extra.status == .Failed && extra.detail == "the session is full",
			"player %d beyond a full session: %v (%s) %d ms later",
			33 + k,
			extra.status,
			extra.detail,
			(net.clock.now - from) / 1000,
		)
	}
}

// One player of a full session leaves and somebody joins the freed seat `gap_ms` later. A datagram of the leaver
// arriving after its connection was dropped (one sent a tick before its Leave, reordered by jitter) opens a connection
// only to tell it so, which holds a connection for DISCONNECT_US: the joiner gets a spare one and is in at once.
freed_seat :: proc(t: ^testing.T, network: netcode.Network, gap_ms: int, settle: f64) -> (waited_ms: i64) {
	net := new(Sweep_Net(Plain_32x4))
	defer free(net)
	sweep_make(net, 0, 64, 32)
	defer sweep_destroy(net)
	for slot in 0 ..< 31 do sweep_join(net, slot, .Ideal)
	leaver := sweep_join(net, 31, network)
	sweep_run(net, settle)
	testing.expect(t, leaver.status == .Connected)
	sweep_leave(net, leaver)
	sweep_run(net, f64(gap_ms) / 1000)
	joiner := sweep_join(net, -1, .Wan)
	from := net.clock.now
	for _ in 0 ..< 16_000 {
		if joiner.status == .Connected || netcode.client_finished(joiner) do break
		sweep_run(net, 0.001)
	}
	waited_ms = (net.clock.now - from) / 1000
	testing.expectf(
		t,
		joiner.status == .Connected && waited_ms < 4000,
		"the leaver on %v, a joiner %d ms after its seat was freed: %v (%s) after %d ms",
		network,
		gap_ms,
		joiner.status,
		joiner.detail,
		waited_ms,
	)
	return
}

@(test)
a_freed_seat_of_a_full_session_is_joined_at_once :: proc(t: ^testing.T) {
	freed_seat(t, .Bad, 0, 3)
}

when scenarios.LONG {
	// Gaps of 0 to 400 ms before the joiner, and 10 more leave moments (the leaver's last datagrams get other delays).
	sweep_freed_seats :: proc(t: ^testing.T, network: netcode.Network) {
		for gap_ms in ([]int{0, 100, 400}) do freed_seat(t, network, gap_ms, 3)
		for k in 0 ..< 10 do freed_seat(t, network, 500, 2 + f64(k) * 0.0371)
	}
	@(test)
	sweep_freed_seats_wan :: proc(t: ^testing.T) {sweep_freed_seats(t, .Wan)}
	@(test)
	sweep_freed_seats_bad :: proc(t: ^testing.T) {sweep_freed_seats(t, .Bad)}
}
