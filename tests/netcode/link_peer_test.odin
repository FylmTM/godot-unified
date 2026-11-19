// A link that numbers a person, not a socket (EOS numbers a remote by its product user id; a fixed-port LAN
// transport): a program that left and the next one on the same link peer share one channel Peer, so the channel's
// "the peer started over" and its ended epochs decide which connection a datagram belongs to.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"

// The relay's end of a hub on which hub endpoints 1 and 2 are one link peer (1). What the relay sends to peer 1
// reaches both endpoints; each client's channel ignores what echoes another epoch.
Same_Peer :: struct {
	inner: netcode.Link,
}

same_peer_link :: proc(hub: ^netcode.Hub, same: ^Same_Peer) -> netcode.Link {
	same.inner = netcode.loopback_link(hub, 0)
	return {
		data = same,
		send = proc(data: rawptr, to: netcode.Peer, bytes: []u8) {
			inner := &(^Same_Peer)(data).inner
			netcode.link_send(inner, to, bytes)
			if to == 1 do netcode.link_send(inner, 2, bytes)
		},
		recv = proc(data: rawptr, buf: []u8) -> (int, netcode.Peer, bool) {
			size, from, ok := netcode.link_recv(&(^Same_Peer)(data).inner, buf)
			return size, from == 2 ? 1 : from, ok
		},
		close = proc(data: rawptr) {netcode.link_close(&(^Same_Peer)(data).inner)},
	}
}

// A client leaves and the next program on the same link peer joins at once: the old one's Leave and the new one's
// Hello reach the relay in one poll (or in two). The Leave was handled after the channel had already given the
// Peer to the new connection, so the relay dropped the new connection (and, remembering its epoch as ended and
// acking its Hello, never let it in: "no answer from the relay"). The new one ends Connected either way, the old one
// "left".
@(test)
a_leave_and_the_next_hello_in_one_poll_on_one_link_peer :: proc(t: ^testing.T) {
	for both_in_one_poll in ([]bool{false, true}) {
		hub := netcode.hub_create(8)
		session: Net
		net_make(&session, 0, 0)
		same: Same_Peer
		netcode.host_add_link(session.host, same_peer_link(hub, &same))
		net_run(&session, 0.5)
		old := netcode.client_create(
			&toy.GAME,
			{slot = -1, player_name = "Old"},
			netcode.loopback_link(hub, 1),
			hooks_for(&session.watch[1]),
		)
		append(&session.clients, old)
		net_run(&session, 2)
		testing.expect_value(t, old.status, netcode.Status.Connected)
		now := session.clock.now
		netcode.client_stop(old, now)
		netcode.client_step(old, now) // the Leave goes out
		if !both_in_one_poll {
			netcode.host_step(session.host, now) // the relay reads it alone
		}
		new_client := netcode.client_create(
			&toy.GAME,
			{slot = -1, player_name = "New"},
			netcode.loopback_link(hub, 2),
			hooks_for(&session.watch[2]),
		)
		append(&session.clients, new_client)
		netcode.client_step(new_client, now) // its Hello goes out
		net_run(&session, 6)
		connected := 0
		for seat in session.relay.seats do connected += int(seat.conn >= 0)
		testing.expectf(
			t,
			new_client.status == .Connected && connected == 2,
			"one poll %v: the new client is %v (%s), statuses %v; seats connected %d (host + new = 2)",
			both_in_one_poll,
			new_client.status,
			new_client.detail,
			session.watch[2].statuses[:],
			connected,
		)
		testing.expectf(
			t,
			netcode.client_finished(old) && old.detail == "left",
			"one poll %v: the old client %v (%s)",
			both_in_one_poll,
			old.status,
			old.detail,
		)
		net_destroy(&session)
		netcode.hub_destroy(hub)
	}
}

// A link that keeps what its client sends instead of sending it (the test puts those datagrams on the wire when it
// wants); the client hears nothing.
Capture :: struct {
	sent: [dynamic][]u8,
}

capture_link :: proc(capture: ^Capture) -> netcode.Link {
	return {
		data = capture,
		send = proc(data: rawptr, to: netcode.Peer, bytes: []u8) {
			capture := (^Capture)(data)
			copied := make([]u8, len(bytes))
			copy(copied, bytes)
			append(&capture.sent, copied)
		},
		recv = proc(data: rawptr, buf: []u8) -> (int, netcode.Peer, bool) {
			return 0, 0, false
		},
		close = proc(data: rawptr) {},
	}
}

capture_destroy :: proc(capture: ^Capture) {
	for bytes in capture.sent do delete(bytes)
	delete(capture.sent)
}

// The link peer's first connection is seated, then the peer starts over (a new connection, seated in its place), and
// then a duplicate of the first connection's Hello arrives: a connection the peer replaced never comes back. It used
// to read as the peer starting over once more, ending the live connection and seating a member nobody is behind.
@(test)
a_duplicate_hello_of_a_replaced_connection_on_one_link_peer :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0, .Ideal)
	net_run(&session, 1)
	ENDPOINT :: 5
	capture: Capture
	defer capture_destroy(&capture)
	first := netcode.client_create(&toy.GAME, {slot = -1, player_name = "Linus"}, capture_link(&capture), {})
	defer netcode.client_destroy(first)
	wire_from_5 := netcode.loopback_link(session.hub, ENDPOINT) // sends only
	defer netcode.link_close(&wire_from_5)
	netcode.client_step(first, session.clock.now)
	netcode.link_send(&wire_from_5, 0, capture.sent[0])
	net_run(&session, 0.05)
	testing.expect(t, session.relay.seats[1].conn >= 0, "the first connection is seated")
	second := netcode.client_create(
		&toy.GAME,
		{slot = -1, player_name = "Linus"},
		netcode.loopback_link(session.hub, ENDPOINT),
		hooks_for(&session.watch[2]),
	)
	append(&session.clients, second)
	net_run(&session, 2)
	testing.expect_value(t, second.status, netcode.Status.Connected)
	members := len(session.relay.members)
	netcode.link_send(&wire_from_5, 0, capture.sent[0]) // the duplicate
	net_run(&session, 3)
	testing.expectf(
		t,
		second.status == .Connected &&
		len(session.relay.members) == members &&
		session.relay.seats[1].member == second.member,
		"after a duplicate of the replaced connection's Hello: the live one is %v (%s), member %d; slot 1 connected %v, member %d; %d members (were %d)",
		second.status,
		second.detail,
		second.member,
		session.relay.seats[1].conn >= 0,
		session.relay.seats[1].member,
		len(session.relay.members),
		members,
	)
}
