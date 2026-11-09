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
	g := new(Gate)
	g.inner = inner
	l := netcode.Link {
		data = g,
		send = proc(data: rawptr, to: netcode.Peer, bytes: []u8) {
			g := (^Gate)(data)
			if !g.block_out {
				netcode.link_send(&g.inner, to, bytes)
			}
		},
		recv = proc(data: rawptr, buf: []u8) -> (n: int, from: netcode.Peer, ok: bool) {
			g := (^Gate)(data)
			for {
				n, from, ok = netcode.link_recv(&g.inner, buf)
				if !ok || !g.block_in {
					return
				}
			}
		},
		close = proc(data: rawptr) {
			g := (^Gate)(data)
			netcode.link_close(&g.inner)
			free(g)
		},
	}
	return l, g
}

// A remote client on hub endpoint `endpoint`, behind a gate and a network simulator.
gated_join :: proc(n: ^Net, endpoint: int, profile: netcode.Profile, watch: ^Watch) -> (^Client, ^Gate) {
	inner := netcode.netsim_wrap(
		netcode.loopback_link(n.hub, netcode.Peer(endpoint)),
		profile,
		u32(endpoint) * 7919 + u32(len(n.clients)),
		&n.clock,
	)
	link, g := gate_wrap(inner)
	c := netcode.client_create(
		&toy.GAME,
		{slot = -1, name = "remote", player = "Grace", quiet = true},
		link,
		hooks_for(watch),
	)
	append(&n.clients, c)
	return c, g
}

// The relay gives up on a client whose packets stopped arriving, while the client still hears the
// relay. When the client's packets flow again, the client must learn that the relay forgot it
// (status Disconnected), not sit in a frozen "Connected" session forever.
@(test)
one_way_outage_ends_the_client_session :: proc(t: ^testing.T) {
	n: Net
	net_make(&n, 0, 0)
	defer net_destroy(&n)
	c, g := gated_join(&n, 1, netcode.PROFILES[1], &n.watch[1])
	net_run(&n, 3)
	testing.expect_value(t, c.status, netcode.Status.Connected)
	g.block_out = true
	net_run(&n, 12) // the relay times the player out after 10 s
	testing.expect(t, !n.host.relay.connected[c.slot])
	g.block_out = false
	net_run(&n, 3)
	testing.expect_value(t, c.status, netcode.Status.Disconnected)
	testing.expect_value(t, c.detail, "connection lost")
}

// A client vanishes without saying goodbye (crash, killed process) and a new one comes back on the
// same link peer before the relay's timeout (EOS numbers peers by user ID, so a rejoining player
// gets the same peer). The relay must drop the old player and serve the new one.
@(test)
rejoin_on_the_same_link_peer :: proc(t: ^testing.T) {
	n: Net
	net_make(&n, 0, 0)
	defer net_destroy(&n)
	a, _ := gated_join(&n, 1, netcode.PROFILES[1], &n.watch[1])
	net_run(&n, 3)
	testing.expect_value(t, a.status, netcode.Status.Connected)
	slot := a.slot
	// Crash: no Leave, the client and its link are gone.
	netcode.client_destroy(a)
	ordered_remove(&n.clients, 0)
	net_run(&n, 1)
	b, _ := gated_join(&n, 1, netcode.PROFILES[1], &n.watch[2])
	net_run(&n, 4)
	testing.expect_value(t, b.status, netcode.Status.Connected)
	testing.expect_value(t, b.slot, slot)
	testing.expect(t, b.verified > b.first_tick)
	expect_agree(t, &n)
}

// A long path (EOS relays across a continent): ~280 ms round trip. The client must keep up with
// the relay clock without stalling most ticks or losing its inputs to the relay's tolerance.
@(test)
long_round_trip_keeps_up :: proc(t: ^testing.T) {
	n: Net
	net_make(&n, 0, 0)
	defer net_destroy(&n)
	c, _ := gated_join(&n, 1, {name = "far", latency = 140_000, jitter = 10_000, loss = 10}, &n.watch[1])
	net_run(&n, 20)
	testing.expect_value(t, c.status, netcode.Status.Connected)
	ticks := int(c.verified - c.first_tick)
	testing.expectf(t, c.stall_ticks * 20 < ticks, "stalled %d of %d ticks", c.stall_ticks, ticks)
	testing.expect_value(t, n.host.relay.replaced, 0)
	expect_agree(t, &n)
}

// After a few seconds of outage both ways (Wi-Fi drop), a client ~200 ms away must get back to
// the live tick quickly: the relay streams the backlog faster than one window per round trip.
@(test)
catch_up_after_an_outage :: proc(t: ^testing.T) {
	n: Net
	net_make(&n, 0, 0)
	defer net_destroy(&n)
	c, g := gated_join(&n, 1, {name = "far", latency = 100_000, jitter = 10_000, loss = 10}, &n.watch[1])
	net_run(&n, 3)
	g.block_out, g.block_in = true, true
	net_run(&n, 8)
	g.block_out, g.block_in = false, false
	testing.expect_value(t, c.status, netcode.Status.Connected)
	start := n.clock.now
	net_run(&n, 30, proc(n: ^Net) -> bool {
		c := n.clients[0]
		return c.verified + 16 >= n.host.relay.finalized
	})
	took_ms := (n.clock.now - start) / 1000
	testing.expectf(t, took_ms < 1500, "caught up in %d ms", took_ms)
	expect_agree(t, &n)
}
