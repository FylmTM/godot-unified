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
