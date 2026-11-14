// L2 netcode tests for what a real two-player online session runs into: outages, a peer that
// comes back on the same transport address, long round trips, catching up after a stall.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"

// A link wrapper that can black out either direction (an outage on one side of the path).
Gate :: struct {
	inner:     netcode.Link,
	block_out: bool, // client -> relay
	block_in:  bool, // relay -> client
}

gate_wrap :: proc(inner: netcode.Link) -> (netcode.Link, ^Gate) {
	gate := new(Gate)
	gate.inner = inner
	link := netcode.Link {
		data = gate,
		send = proc(data: rawptr, to: netcode.Peer, bytes: []u8) {
			gate := (^Gate)(data)
			if !gate.block_out {
				netcode.link_send(&gate.inner, to, bytes)
			}
		},
		recv = proc(data: rawptr, buf: []u8) -> (size: int, from: netcode.Peer, ok: bool) {
			gate := (^Gate)(data)
			for {
				size, from, ok = netcode.link_recv(&gate.inner, buf)
				if !ok || !gate.block_in {
					return
				}
			}
		},
		close = proc(data: rawptr) {
			gate := (^Gate)(data)
			netcode.link_close(&gate.inner)
			free(gate)
		},
	}
	return link, gate
}

// A remote client on hub endpoint `endpoint`, behind a gate and a network simulator.
gated_join :: proc(
	session: ^Net,
	endpoint: int,
	profile: netcode.Profile,
	watch: ^Watch,
	seed: u32 = 0,
) -> (
	^Client,
	^Gate,
) {
	inner := netcode.netsim_wrap(
		netcode.loopback_link(session.hub, netcode.Peer(endpoint)),
		profile,
		u32(endpoint) * 7919 + u32(len(session.clients)) + seed * 104_729,
		&session.clock,
	)
	link, gate := gate_wrap(inner)
	client := netcode.client_create(
		&toy.GAME,
		{player = -1, name = "remote", player_name = "Grace", quiet = true},
		link,
		hooks_for(watch),
	)
	append(&session.clients, client)
	return client, gate
}

// The relay gives up on a client whose packets stopped arriving, while the client still hears the
// relay. When the client's packets flow again, the client must learn that the relay forgot it
// (status Disconnected), not sit in a frozen "Connected" session forever.
@(test)
one_way_outage_ends_the_client_session :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, gate := gated_join(&session, 1, netcode.PROFILES[1], &session.watch[1])
	net_run(&session, 3)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	gate.block_out = true
	net_run(&session, 12) // the relay times the player out after 10 s
	testing.expect(t, !session.host.relay.connected[client.player])
	gate.block_out = false
	net_run(&session, 3)
	testing.expect_value(t, client.status, netcode.Status.Disconnected)
	testing.expect_value(t, client.detail, "connection lost")
}

// A client vanishes without saying goodbye (crash, killed process) and a new one comes back on the
// same link peer before the relay's timeout (EOS numbers peers by user ID, so a rejoining player
// gets the same peer). The relay must drop the old player and serve the new one.
@(test)
rejoin_on_the_same_link_peer :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	crashed, _ := gated_join(&session, 1, netcode.PROFILES[1], &session.watch[1])
	net_run(&session, 3)
	testing.expect_value(t, crashed.status, netcode.Status.Connected)
	player := crashed.player
	// Crash: no Leave, the client and its link are gone.
	netcode.client_destroy(crashed)
	ordered_remove(&session.clients, 0)
	net_run(&session, 1)
	rejoined, _ := gated_join(&session, 1, netcode.PROFILES[1], &session.watch[2])
	net_run(&session, 4)
	testing.expect_value(t, rejoined.status, netcode.Status.Connected)
	testing.expect_value(t, rejoined.player, player)
	testing.expect(t, rejoined.verified > rejoined.first_tick)
	expect_agree(t, &session)
}

// A long path (EOS relays across a continent): ~280 ms round trip. The client must keep up with
// the relay clock without stalling most ticks or losing its inputs to the relay's tolerance.
@(test)
long_round_trip_keeps_up :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, _ := gated_join(
		&session,
		1,
		{name = "far", latency = 140_000, jitter = 10_000, loss = 10},
		&session.watch[1],
	)
	net_run(&session, 20)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	ticks := int(client.verified - client.first_tick)
	testing.expectf(t, client.stall_ticks * 20 < ticks, "stalled %d of %d ticks", client.stall_ticks, ticks)
	testing.expect_value(t, session.host.relay.replaced, 0)
	expect_agree(t, &session)
}

// A player joining a running session from far away (240 to 300 ms round trip, the most a client plays
// smoothly at) gets its join tick half a second ahead of the relay clock. Its inputs must reach the
// relay within the tolerance from that tick on: none of them replaced, across network seeds.
@(test)
long_round_trip_join_keeps_its_first_inputs :: proc(t: ^testing.T) {
	for latency in ([?]i64{120_000, 140_000, 150_000}) {
		for seed in u32(0) ..< 6 {
			session: Net
			net_make(&session, 0, 0)
			profile := netcode.Profile {
				name    = "far",
				latency = latency,
				jitter  = 10_000,
				loss    = 10,
			}
			client, _ := gated_join(&session, 1, profile, &session.watch[1], seed)
			net_run(&session, 2, proc(session: ^Net) -> bool {
				client := session.clients[0]
				return client.first_tick != 0 && session.host.relay.finalized >= client.first_tick + 16
			})
			testing.expectf(t, client.first_tick != 0, "latency %d seed %d: never welcomed", latency, seed)
			testing.expectf(
				t,
				session.host.relay.replaced == 0,
				"latency %d seed %d: %d inputs replaced (join tick %d)",
				latency,
				seed,
				session.host.relay.replaced,
				client.first_tick,
			)
			net_destroy(&session)
		}
	}
}

// After a few seconds of outage both ways (Wi-Fi drop), a client ~200 ms away must get back to
// the live tick quickly: the relay streams the backlog faster than one window per round trip.
@(test)
catch_up_after_an_outage :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, gate := gated_join(
		&session,
		1,
		{name = "far", latency = 100_000, jitter = 10_000, loss = 10},
		&session.watch[1],
	)
	net_run(&session, 3)
	gate.block_out, gate.block_in = true, true
	net_run(&session, 8)
	gate.block_out, gate.block_in = false, false
	testing.expect_value(t, client.status, netcode.Status.Connected)
	start := session.clock.now
	net_run(&session, 30, proc(session: ^Net) -> bool {
		client := session.clients[0]
		return client.verified + 16 >= session.host.relay.finalized
	})
	took_ms := (session.clock.now - start) / 1000
	testing.expectf(t, took_ms < 1500, "caught up in %d ms", took_ms)
	expect_agree(t, &session)
}
