// L2 netcode tests for the transport under the relay: the channel's reliable bursts and the network simulator.
package test_netcode

import "core:testing"

import "unified:netcode"

// A burst of reliable messages longer than one ack covers (a snapshot: 120 datagrams) arrives without a single
// resend on a link that loses nothing: the sender waits for acks instead of resending what arrived (N6, D8).
@(test)
a_reliable_burst_is_not_resent :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	sender := netcode.channel_make()
	defer netcode.channel_destroy(sender)
	receiver := netcode.channel_make()
	defer netcode.channel_destroy(receiver)
	to_receiver := netcode.channel_peer(sender, netcode.channel_add_link(sender, netcode.loopback_link(hub, 0)), 1)
	netcode.channel_add_link(receiver, netcode.loopback_link(hub, 1))
	chunk: [1000]u8
	now: i64 = 1_000_000
	for k in 0 ..< 120 {
		chunk[0] = u8(k)
		netcode.channel_send(sender, to_receiver, chunk[:], .Reliable, now)
	}
	got := 0
	for _ in 0 ..< 2000 {
		now += 500
		netcode.channel_flush(sender, now)
		netcode.channel_poll(sender, now)
		for event in netcode.channel_poll(receiver, now) {
			if event.kind == .Message {
				testing.expect_value(t, event.data[0], u8(got))
				got += 1
			}
		}
		netcode.channel_flush(receiver, now)
		if got == 120 && netcode.channel_idle(sender, to_receiver) {
			break
		}
	}
	testing.expect_value(t, got, 120)
	testing.expect_value(t, sender.stats.resends, 0)
}

// A profile with only jitter impairs the link (it used to come back unwrapped).
@(test)
a_jitter_only_profile_is_simulated :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	inner := netcode.loopback_link(hub, 1)
	data := inner.data
	link := netcode.netsim_wrap(inner, {name = "jitter", jitter = 5_000}, 7)
	defer netcode.link_close(&link)
	testing.expect(t, link.data != data)
	testing.expect(t, netcode.profile_is_ideal({name = "ideal"}))
	testing.expect(t, !netcode.profile_is_ideal({jitter = 1}))
}

// A peer that never answered gets FIRST_ANSWER_US (a transport like EOS sets up its path after the first hello);
// one that answered and then went silent gets DISCONNECT_US.
@(test)
a_silent_peer_times_out_by_whether_it_ever_answered :: proc(t: ^testing.T) {
	disconnected :: proc(channel: ^netcode.Channel, now: i64) -> bool {
		for event in netcode.channel_poll(channel, now) {
			if event.kind == .Disconnected do return true
		}
		return false
	}
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	sender := netcode.channel_make()
	defer netcode.channel_destroy(sender)
	to_peer := netcode.channel_peer(sender, netcode.channel_add_link(sender, netcode.loopback_link(hub, 0)), 1)
	hello := [1]u8{7}
	start: i64 = 1_000_000
	netcode.channel_send(sender, to_peer, hello[:], .Reliable, start)
	netcode.channel_flush(sender, start)
	testing.expect(
		t,
		!disconnected(sender, start + netcode.DISCONNECT_US + 1),
		"a peer that never answered waits longer",
	)
	testing.expect(t, disconnected(sender, start + netcode.FIRST_ANSWER_US + 1), "until FIRST_ANSWER_US")

	// The peer answers once, then goes silent: DISCONNECT_US.
	receiver := netcode.channel_make()
	defer netcode.channel_destroy(receiver)
	netcode.channel_add_link(receiver, netcode.loopback_link(hub, 1))
	now := start + netcode.FIRST_ANSWER_US + 2
	netcode.channel_send(sender, to_peer, hello[:], .Reliable, now)
	netcode.channel_flush(sender, now)
	netcode.channel_poll(receiver, now)
	netcode.channel_flush(receiver, now)
	testing.expect(t, !disconnected(sender, now), "the answer arrives")
	testing.expect(
		t,
		disconnected(sender, now + netcode.DISCONNECT_US + 1),
		"an answered peer's silence: DISCONNECT_US",
	)
}

// A connection channel_send opens raises Connected, which the next poll returns (not clears), once.
@(test)
a_connected_event_from_send_reaches_the_next_poll :: proc(t: ^testing.T) {
	connected :: proc(channel: ^netcode.Channel, now: i64) -> (count: int) {
		for event in netcode.channel_poll(channel, now) {
			if event.kind == .Connected do count += 1
		}
		return
	}
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	sender := netcode.channel_make()
	defer netcode.channel_destroy(sender)
	to_peer := netcode.channel_peer(sender, netcode.channel_add_link(sender, netcode.loopback_link(hub, 0)), 1)
	hello := [1]u8{7}
	netcode.channel_send(sender, to_peer, hello[:], .Reliable, 1_000)
	testing.expect_value(t, connected(sender, 1_000), 1)
	testing.expect_value(t, connected(sender, 2_000), 0)
}

// No two connections of one process share an epoch, also across channels freed and made again at once (the same
// address, a few microseconds later). Epochs seeded per channel from the clock and the address repeated now and then:
// the remade joiner's Hello read as the old connection's (or an ended one's) and was never answered, so
// fuzz_joiner_snapshots hung in its join loop.
@(test)
connections_remade_at_once_get_new_epochs :: proc(t: ^testing.T) {
	REMADE :: 256
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	seen := make(map[u32]bool, REMADE, context.temp_allocator)
	hello := [1]u8{7}
	for _ in 0 ..< REMADE {
		channel := netcode.channel_make()
		to_peer := netcode.channel_peer(channel, netcode.channel_add_link(channel, netcode.loopback_link(hub, 0)), 1)
		netcode.channel_send(channel, to_peer, hello[:], .Reliable, 1_000)
		epoch := channel.conns[to_peer].epoch
		testing.expectf(t, epoch != 0 && !seen[epoch], "epoch %x again", epoch)
		seen[epoch] = true
		netcode.channel_destroy(channel)
	}
}

// Closing a netsim link sends what it still delays: a client that leaves right after acking the relay's End must not
// take the ack with it (#235: the relay waited 3 s for it in about half the net suite's runs).
@(test)
closing_a_netsim_sends_what_it_delays :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	receiver := netcode.loopback_link(hub, 0)
	defer netcode.link_close(&receiver)
	clock := netcode.Virtual_Clock {
		now = 1_000_000,
	}
	sender := netcode.netsim_wrap(netcode.loopback_link(hub, 1), {name = "slow", latency = 120_000}, 7, &clock)
	datagram := [3]u8{1, 2, 3}
	netcode.link_send(&sender, 0, datagram[:])
	buf: [netcode.MAX_DATAGRAM]u8
	_, _, early := netcode.link_recv(&receiver, buf[:])
	testing.expect(t, !early, "the datagram is delayed")
	netcode.link_close(&sender)
	size, from, ok := netcode.link_recv(&receiver, buf[:])
	testing.expect(t, ok, "closing the sender sent it")
	testing.expect_value(t, size, 3)
	testing.expect_value(t, from, netcode.Peer(1))
}

@(private = "file")
g_forgot: [dynamic]netcode.Peer // the peers the live netsim's inner link was told to forget

// A live netsim (the dev UI's Conditions panel): straight through while ideal (nothing queued, no copy), impaired once
// its profiles are set, drained after it is ideal again. `forget` reaches the inner link either way (EOS closes the
// peer's connection with it, UDP frees the peer number).
@(test)
a_live_netsim_passes_through_while_ideal :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	clock := netcode.Virtual_Clock {
		now = 1_000_000,
	}
	inner := netcode.loopback_link(hub, 0)
	inner.forget = proc(data: rawptr, peer: netcode.Peer) {append(&g_forgot, peer)}
	defer delete(g_forgot)
	link, netsim := netcode.netsim_live(inner, 5, &clock)
	other := netcode.loopback_link(hub, 1)
	defer netcode.link_close(&other)
	buf: [64]u8

	netcode.link_forget(&link, 1)
	netcode.link_send(&link, 1, {1, 2, 3})
	testing.expect_value(t, netcode.hub_queued(hub, 1), 1) // delivered at once
	netcode.link_send(&other, 0, {9})
	size, from, ok := netcode.link_recv(&link, buf[:])
	testing.expect(t, ok && size == 1 && buf[0] == 9 && from == 1)

	lag := netcode.Profile {
		name    = "lag",
		latency = 20_000,
	}
	netcode.netsim_set(netsim, lag, lag)
	netcode.link_forget(&link, 1) // with the netsim on
	netcode.link_send(&link, 1, {4})
	testing.expect_value(t, netcode.hub_queued(hub, 1), 1) // held for 20 ms
	clock.now += 30_000
	_, _, _ = netcode.link_recv(&link, buf[:]) // pumps the netsim
	testing.expect_value(t, netcode.hub_queued(hub, 1), 2)

	// Ideal again: a datagram received while impaired is still delivered (drained), then direct.
	netcode.link_send(&other, 0, {7})
	_, _, _ = netcode.link_recv(&link, buf[:]) // the netsim takes it in, due in 20 ms
	netcode.netsim_set(netsim, {}, {})
	clock.now += 30_000
	size, _, ok = netcode.link_recv(&link, buf[:])
	testing.expect(t, ok && size == 1 && buf[0] == 7, "drained after the switch")
	netcode.link_send(&link, 1, {5})
	testing.expect_value(t, netcode.hub_queued(hub, 1), 3) // direct again
	testing.expect_value(t, len(g_forgot), 2)
	netcode.link_close(&link)
}

// A snapshot-sized burst (400 datagrams) over a 50 ms path whose jitter reorders it: the older acks chunk describes
// the seqs more than 32 behind the newest, so nothing that arrived is resent, and the burst goes at the pace
// (REL_RATE) plus a few round trips (one ack covers REL_IN_FLIGHT datagrams), not one round trip per 32 datagrams.
@(test)
a_reordered_burst_is_acked_in_full :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	clock := netcode.Virtual_Clock {
		now = 1_000_000,
	}
	path := netcode.Profile {
		name    = "far",
		latency = 50_000,
		jitter  = 15_000,
	}
	sender := netcode.channel_make()
	defer netcode.channel_destroy(sender)
	receiver := netcode.channel_make()
	defer netcode.channel_destroy(receiver)
	// The receiver's link carries the path both ways (as a session's client link does).
	to_receiver := netcode.channel_peer(sender, netcode.channel_add_link(sender, netcode.loopback_link(hub, 0)), 1)
	netcode.channel_add_link(receiver, netcode.netsim_wrap(netcode.loopback_link(hub, 1), path, 13, &clock))
	MESSAGES :: 400
	chunk: [1000]u8
	for k in 0 ..< MESSAGES {
		chunk[0], chunk[1] = u8(k), u8(k >> 8)
		netcode.channel_send(sender, to_receiver, chunk[:], .Reliable, clock.now)
	}
	start := clock.now
	got := 0
	for clock.now - start < 5_000_000 {
		clock.now += 1000 // both sides flush every millisecond, as a session thread does
		netcode.channel_flush(sender, clock.now)
		netcode.channel_poll(sender, clock.now)
		for event in netcode.channel_poll(receiver, clock.now) {
			if event.kind == .Message {
				testing.expect_value(t, int(event.data[0]) | int(event.data[1]) << 8, got)
				got += 1
			}
		}
		netcode.channel_flush(receiver, clock.now)
		if got == MESSAGES && netcode.channel_idle(sender, to_receiver) {
			break
		}
	}
	testing.expect_value(t, got, MESSAGES)
	testing.expect_value(t, sender.stats.resends, 0)
	took := clock.now - start
	paced := i64(MESSAGES * len(chunk)) * 1_000_000 / netcode.REL_RATE
	testing.expectf(
		t,
		took < paced + 300_000,
		"the burst took %d ms (paced: %d ms, a 100 ms round trip)",
		took / 1000,
		paced / 1000,
	)
}

// Reliable bytes to a peer are paced even when its acks come at once: at most REL_BURST at first, then REL_RATE (a
// big snapshot never floods the uplink), and the whole burst still arrives without a resend.
@(test)
reliable_sends_are_paced :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	sender := netcode.channel_make()
	defer netcode.channel_destroy(sender)
	receiver := netcode.channel_make()
	defer netcode.channel_destroy(receiver)
	to_receiver := netcode.channel_peer(sender, netcode.channel_add_link(sender, netcode.loopback_link(hub, 0)), 1)
	netcode.channel_add_link(receiver, netcode.loopback_link(hub, 1))
	MESSAGES :: 300
	chunk: [1000]u8
	start: i64 = 1_000_000
	for _ in 0 ..< MESSAGES {
		netcode.channel_send(sender, to_receiver, chunk[:], .Reliable, start)
	}
	got := 0
	for now := start; now < start + 2_000_000 && got < MESSAGES; now += 1000 {
		netcode.channel_flush(sender, now)
		netcode.channel_poll(sender, now)
		for event in netcode.channel_poll(receiver, now) {
			if event.kind == .Message do got += 1
		}
		netcode.channel_flush(receiver, now)
		allowed := netcode.REL_BURST + (now - start) * netcode.REL_RATE / 1_000_000
		sent := i64(sender.stats.bytes_sent - sender.stats.datagrams_sent * netcode.HEADER_BYTES)
		if !testing.expectf(
			t,
			sent <= allowed,
			"%d bytes sent after %d ms (allowed %d)",
			sent,
			(now - start) / 1000,
			allowed,
		) {
			break
		}
	}
	testing.expect_value(t, got, MESSAGES)
	testing.expect_value(t, sender.stats.resends, 0)
}
