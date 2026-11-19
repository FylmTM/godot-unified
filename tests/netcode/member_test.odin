// Players are session members (src/netcode/README.md, Members): the relay recognizes a person who comes back by the
// account their link vouches for, else by their client's token, and gives them the same member id in whatever slot
// is free; the newest connection of a person wins; the roster is kept by member; neither accounts nor tokens reach
// the recording.
package test_netcode

import "core:bytes"
import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

// A loopback link at the relay's end of a hub that vouches for an account per peer (a platform transport, as EOS
// does with the remote's product user id).
Vouching :: struct {
	inner:    netcode.Link,
	accounts: [8]string, // by peer (the client's hub endpoint); "": none
}

vouching_link :: proc(hub: ^netcode.Hub, vouching: ^Vouching) -> netcode.Link {
	vouching.inner = netcode.loopback_link(hub, 0)
	return {
		data = vouching,
		send = proc(data: rawptr, to: netcode.Peer, bytes: []u8) {
			netcode.link_send(&(^Vouching)(data).inner, to, bytes)
		},
		recv = proc(data: rawptr, buf: []u8) -> (int, netcode.Peer, bool) {
			return netcode.link_recv(&(^Vouching)(data).inner, buf)
		},
		close = proc(data: rawptr) {netcode.link_close(&(^Vouching)(data).inner)},
		account = proc(data: rawptr, peer: netcode.Peer) -> (netcode.Account, bool) {
			id := (^Vouching)(data).accounts[peer]
			return {platform = "eos", id = id}, id != ""
		},
	}
}

// A remote client on `hub` endpoint `endpoint` (with a token, or none).
member_join :: proc(
	session: ^Net,
	hub: ^netcode.Hub,
	endpoint: int,
	name: string,
	token := netcode.Token{},
) -> ^Client {
	link := netcode.netsim_wrap(
		netcode.loopback_link(hub, netcode.Peer(endpoint)),
		netcode.PROFILES[.Wan],
		u32(endpoint) * 7919 + u32(len(session.clients)),
		&session.clock,
	)
	client := netcode.client_create(&toy.GAME, {
			slot        = -1,
			player_name = name,
			token       = token,
		}, link, hooks_for(&session.watch[min(len(session.clients) + 1, 7)]))
	append(&session.clients, client)
	return client
}

// The host's view of who holds `slot` now (a handle, and its data).
host_player :: proc(session: ^Net, slot: int) -> (sim.Player, ^toy.Player_Data) {
	players := &session.host.client.sim.state.players
	player := sim.player_in_slot(players, slot)
	return player, sim.player_data(players, player)
}

net_leave :: proc(session: ^Net, client: ^Client) {
	netcode.client_stop(client, session.clock.now)
	net_run(session, 2)
}

// Whether `needle` appears in the session's recording.
recorded :: proc(session: ^Net, needle: []u8) -> bool {
	return bytes.index(session.recording[:], needle) >= 0
}

@(test)
a_token_brings_the_member_back_in_another_slot :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	token := netcode.Token{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	ann := member_join(&session, session.hub, 1, "Ann", token)
	net_run(&session, 3)
	testing.expect_value(t, ann.status, netcode.Status.Connected)
	ann_player, ann_data := host_player(&session, ann.slot)
	testing.expect(t, ann_player.id == ann.member && ann_data != nil)
	score := ann_data.score
	old_slot := ann.slot
	net_leave(&session, ann)
	// Bob takes Ann's old slot (the lowest free), then Ann comes back with her token on a new connection.
	bob := member_join(&session, session.hub, 2, "Bob")
	net_run(&session, 3)
	testing.expect_value(t, bob.slot, old_slot)
	testing.expect(t, bob.member != ann.member)
	bob_player, _ := host_player(&session, bob.slot)
	testing.expect(t, bob_player != ann_player)
	again := member_join(&session, session.hub, 3, "Ann", token)
	net_run(&session, 3)
	testing.expect_value(t, again.status, netcode.Status.Connected)
	testing.expect(t, again.slot != old_slot)
	testing.expect_value(t, again.member, ann.member)
	back_player, back_data := host_player(&session, again.slot)
	testing.expect_value(t, back_player, ann_player) // the same handle, in another slot
	testing.expect(t, back_data != nil && back_data.score >= score)
	// The roster by member: Ann's entry kept while she was away, a later joiner knows Bob and Ann.
	for client in ([]^Client{session.host.client, bob, again}) {
		entry := netcode.client_member(client, ann.member)
		if !testing.expect(t, entry != nil) do continue
		testing.expect_value(t, netcode.text_string(&entry.name), "Ann")
		testing.expect(t, entry.connected && int(entry.slot) == again.slot)
		testing.expect_value(t, netcode.text_string(&entry.platform), "") // a token is never forwarded
	}
	expect_agree(t, &session)
	testing.expect(t, !recorded(&session, token[:]), "the token is not in the recording")
}

@(test)
a_vouched_account_brings_the_member_back :: proc(t: ^testing.T) {
	// The hub outlives the session: closing the clients' links still sends into it (a netsim flushes what it delays).
	hub := netcode.hub_create(8)
	defer netcode.hub_destroy(hub)
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	vouching: Vouching
	vouching.accounts = {
		1 = "0002aaaa",
		2 = "0002bbbb",
		3 = "0002aaaa",
	}
	netcode.host_add_link(session.host, vouching_link(hub, &vouching))
	net_run(&session, 0.5)
	ann := member_join(&session, hub, 1, "Ann")
	net_run(&session, 3)
	testing.expect_value(t, ann.status, netcode.Status.Connected)
	ann_player, _ := host_player(&session, ann.slot)
	old_slot := ann.slot
	net_leave(&session, ann)
	bob := member_join(&session, hub, 2, "Bob")
	net_run(&session, 3)
	testing.expect_value(t, bob.slot, old_slot)
	again := member_join(&session, hub, 3, "Ann (again)") // a new program, the same account
	net_run(&session, 3)
	testing.expect_value(t, again.status, netcode.Status.Connected)
	testing.expect(t, again.slot != old_slot)
	testing.expect_value(t, again.member, ann.member)
	back_player, _ := host_player(&session, again.slot)
	testing.expect_value(t, back_player, ann_player)
	entry := netcode.client_member(bob, ann.member)
	if testing.expect(t, entry != nil) {
		testing.expect_value(t, netcode.text_string(&entry.platform), "eos")
		testing.expect_value(t, netcode.text_string(&entry.account), "0002aaaa")
		testing.expect_value(t, netcode.text_string(&entry.name), "Ann (again)")
	}
	expect_agree(t, &session)
	testing.expect(t, !recorded(&session, transmute([]u8)string("0002aaaa")), "no account in the recording")
}

// A person whose game restarted connects again while still seated: the relay drops the old connection at once
// instead of waiting for its timeout (#173), and they are the same member.
@(test)
the_newest_connection_of_a_member_wins :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	token := netcode.Token{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1}
	crashed := member_join(&session, session.hub, 1, "Cy", token)
	net_run(&session, 3)
	testing.expect_value(t, crashed.status, netcode.Status.Connected)
	member := crashed.member
	player, _ := host_player(&session, crashed.slot)
	// Crash: no Leave, the client and its link are gone; the relay still has it seated.
	netcode.client_destroy(crashed)
	ordered_remove(&session.clients, 0)
	net_run(&session, 0.5)
	testing.expect(t, session.host.relay.seats[1].connected)
	restarted := member_join(&session, session.hub, 2, "Cy", token)
	net_run(&session, 3) // far below the channel's 10 s timeout
	testing.expect_value(t, restarted.status, netcode.Status.Connected)
	testing.expect_value(t, restarted.member, member)
	back, _ := host_player(&session, restarted.slot)
	testing.expect_value(t, back, player)
	connected := 0
	for slot in 0 ..< toy.PLAYERS do connected += int(session.host.relay.seats[slot].connected)
	testing.expect_value(t, connected, 2) // the host and Cy's new connection
	expect_agree(t, &session)
}

// A token's text (the Godot host keeps it in user://) reads back as the same token: written any other way, every
// restart of the game was someone new to the relay.
@(test)
token_text_round_trips :: proc(t: ^testing.T) {
	token := netcode.Token {
		0x60,
		0x01,
		0x65,
		0x43,
		0x51,
		0x83,
		0x93,
		0x1d,
		0x04,
		0xc6,
		0xa3,
		0xb7,
		0x92,
		0xc1,
		0x14,
		0x60,
	}
	text := netcode.token_text(token)
	testing.expect_value(t, text, "600165435183931d04c6a3b792c11460")
	back, ok := netcode.token_parse(text)
	testing.expect(t, ok && back == token, "the text reads back as the token")
	upper, upper_ok := netcode.token_parse("600165435183931D04C6A3B792C11460")
	testing.expect(t, upper_ok && upper == token, "upper-case digits read too")
	_, ok = netcode.token_parse("[60, 1, 65, 43, 51, 83, 93, 1d, 4, c6, a3, b7, 92, c1, 14, 60]")
	testing.expect(t, !ok, "a slice's %x text is not a token")
	_, ok = netcode.token_parse("600165435183931d04c6a3b792c1146g")
	testing.expect(t, !ok, "a non-hex digit is not a token")
	_, ok = netcode.token_parse(netcode.token_text({}))
	testing.expect(t, !ok, "all zero is no token")
}

// A remote client asking for any slot behind a link of `latency_ms` each way and nothing else (no loss, jitter,
// duplicates or reordering), with `token` (zero: none).
far_join :: proc(session: ^Net, latency_ms: i64, token := netcode.Token{}) -> ^Client {
	endpoint := len(session.clients) + 1
	link := netcode.netsim_wrap(
		netcode.loopback_link(session.hub, netcode.Peer(endpoint)),
		{name = "slow", latency = latency_ms * 1000},
		u32(endpoint) * 7919,
		&session.clock,
	)
	client := netcode.client_create(
		&toy.GAME,
		{slot = -1, player_name = "Linus", token = token},
		link,
		hooks_for(&session.watch[min(endpoint, 7)]),
	)
	append(&session.clients, client)
	return client
}

// A client on a 240 ms round trip that leaves 120 ms after its Hello, before the relay's first datagram reached it:
// the relay seats it and takes its Leave; then the Hello the client resent meanwhile (165 ms after the first, before
// it heard from the relay) arrives. A connection that said goodbye never comes back: that Hello seats nobody (it was
// a member nobody is behind, holding the seat until the connection timed out).
@(test)
a_client_that_leaves_before_the_relay_answered_leaves_no_member_behind :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	host := net_join(&session, 0, .Ideal)
	net_run(&session, 1)
	first := far_join(&session, 120)
	net_run(&session, 0.12)
	netcode.client_stop(first, session.clock.now)
	net_run(&session, 3) // its Leave arrived 2.6 s ago
	testing.expect(t, netcode.client_finished(first))
	testing.expectf(
		t,
		!session.relay.seats[1].connected,
		"3 s after it left, slot 1 is held by member %d (the relay knows %d members: the host and one joiner make 2); the host's sim has %v present",
		session.relay.seats[1].member,
		len(session.relay.members),
		netcode.client_inputs(host, host.verified).present,
	)
	testing.expect_value(t, len(session.relay.members), 2)
	testing.expect_value(t, first.detail, "left")
}

// The same when the player tries again at once with the same token (a double click on Join; the Godot host keeps
// one): the first try's resent Hello, arriving after the second's, must not replace the second as "the newest
// connection" of that member, whichever of the first's Leave and the second's Hello comes first.
@(test)
a_second_try_is_not_replaced_by_the_first_trys_hello :: proc(t: ^testing.T) {
	for second_ahead in ([]bool{false, true}) {
		session: Net
		net_make_relay(&session, 1, 0)
		net_join(&session, 0, .Ideal)
		net_run(&session, 1)
		token := netcode.Token {
			0 = 7,
			5 = 9,
		}
		first := far_join(&session, 120, token)
		second: ^Client
		if second_ahead {
			// the second's Hello reaches the relay before the first's Leave: it replaces the first connection
			net_run(&session, 0.1)
			second = far_join(&session, 120, token)
			net_run(&session, 0.02)
			netcode.client_stop(first, session.clock.now)
		} else {
			net_run(&session, 0.12)
			netcode.client_stop(first, session.clock.now)
			second = far_join(&session, 120, token)
		}
		net_run(&session, 6)
		testing.expectf(
			t,
			second.status == .Connected,
			"second ahead %v: the second try is %v (%s); the relay knows %d members, slot 1 connected %v",
			second_ahead,
			second.status,
			second.detail,
			len(session.relay.members),
			session.relay.seats[1].connected,
		)
		testing.expect(t, netcode.client_finished(first))
		net_destroy(&session)
	}
}

// When a client leaves, every 40 ms from 20 to 300 ms after its Hello, on round trips of 100, 240 and 400 ms: no
// member is left behind, and the client finishes "left" within its linger.
@(test)
a_leave_inside_the_first_round_trip_leaves_no_member_behind :: proc(t: ^testing.T) {
	for latency in ([]i64{50, 120, 200}) {
		for leave_ms := 20; leave_ms <= 300; leave_ms += 40 {
			session: Net
			net_make_relay(&session, 1, 0)
			net_join(&session, 0, .Ideal)
			net_run(&session, 1)
			first := far_join(&session, latency)
			net_run(&session, f64(leave_ms) / 1000)
			netcode.client_stop(first, session.clock.now)
			stopped := session.clock.now
			net_run(&session, 3, proc(session: ^Net) -> bool {return netcode.client_finished(session.clients[1])})
			finished_ms := (session.clock.now - stopped) / 1000
			net_run(&session, 3)
			testing.expectf(
				t,
				!session.relay.seats[1].connected && len(session.relay.members) == 2,
				"round trip %d ms, left %d ms after its Hello: slot 1 connected %v, %d members",
				2 * latency,
				leave_ms,
				session.relay.seats[1].connected,
				len(session.relay.members),
			)
			testing.expectf(
				t,
				first.detail == "left" && finished_ms <= 2 * latency + 200,
				"round trip %d ms, left %d ms after its Hello: finished %d ms later (%s)",
				2 * latency,
				leave_ms,
				finished_ms,
				first.detail,
			)
			net_destroy(&session)
		}
	}
}

// A client stopped while a Connected was still on its way (a joiner between its checksum and the relay's Snap_Ok; a
// start player before its Welcome) never reports Connected after client_stop, and finishes "left".
@(test)
a_leaving_client_never_reports_connected :: proc(t: ^testing.T) {
	{
		session: Net
		net_make_relay(&session, 1, 0)
		defer net_destroy(&session)
		net_join(&session, 0, .Ideal)
		net_run(&session, 1)
		joiner := far_join(&session, 60)
		// the relay checked its snapshot and sent Snap_Ok, which is on its way
		net_run(&session, 5, proc(session: ^Net) -> bool {
			return session.clients[1].checking && !session.relay.seats[1].checking
		})
		testing.expect(t, joiner.checking && session.relay.seats[1].connected)
		netcode.client_stop(joiner, session.clock.now)
		net_run(&session, 3)
		statuses := session.watch[2].statuses[:]
		testing.expectf(
			t,
			joiner.status == .Disconnected && joiner.detail == "left" && !slice_has(statuses, .Connected),
			"a joiner stopped while checking: %v (%s), statuses %v",
			joiner.status,
			joiner.detail,
			statuses,
		)
	}
	{
		session: Net
		net_make_relay(&session, 1, 0)
		defer net_destroy(&session)
		start := far_join(&session, 120)
		net_run(&session, 0.05) // its Hello is on its way: the relay starts the clock and welcomes it
		netcode.client_stop(start, session.clock.now)
		net_run(&session, 3)
		statuses := session.watch[1].statuses[:]
		testing.expectf(
			t,
			start.status == .Disconnected && start.detail == "left" && !slice_has(statuses, .Connected),
			"a start player stopped before its Welcome: %v (%s), statuses %v, welcomed %v",
			start.status,
			start.detail,
			statuses,
			start.welcomed,
		)
	}
}

// A client stopped while the relay's refusal is on its way (here: another build; the session is full) finishes "left"
// instead of failing with the refusal's reason: no error for a join the player cancelled.
@(test)
a_leaving_client_never_reports_failed :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0, .Ideal)
	net_run(&session, 1)
	link := netcode.netsim_wrap(
		netcode.loopback_link(session.hub, 2),
		{name = "slow", latency = 120_000},
		7,
		&session.clock,
	)
	client := netcode.client_create(&toy.GAME, {slot = -1, compat = 12345}, link, hooks_for(&session.watch[2]))
	append(&session.clients, client)
	net_run(&session, 0.05)
	netcode.client_stop(client, session.clock.now)
	net_run(&session, 3)
	statuses := session.watch[2].statuses[:]
	testing.expectf(
		t,
		client.status == .Disconnected && client.detail == "left" && !slice_has(statuses, .Failed),
		"a client stopped before the relay's Reject arrived: %v (%s), statuses %v",
		client.status,
		client.detail,
		statuses,
	)
	// Its Leave came after the refusal: the relay frees the connection at once, not DISCONNECT_US later (a full
	// session keeps only netcode.PEERS_SPARE connections for peers it seats nowhere).
	open := 0
	for peer in 0 ..< netcode.MAX_PEERS do open += int(netcode.channel_connected(session.relay.ch, netcode.Peer(peer)))
	testing.expectf(t, open == 1, "3 s later the relay holds %d connections (the host's: 1)", open)
}

// A client stopped before its first step (a player who cancels at once; the Godot driver checks for a stop before it
// steps the client) never told the relay anything: it sends nothing, its Hello included, and is finished at once,
// "left". It used to send its Hello on the next step anyway and leave a member nobody is behind for DISCONNECT_US.
@(test)
a_client_stopped_before_its_first_step_seats_nobody :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0, .Ideal)
	net_run(&session, 1)
	early := far_join(&session, 30)
	netcode.client_stop(early, session.clock.now)
	testing.expectf(
		t,
		netcode.client_finished(early) && early.detail == "left",
		"stopped before its first step: %v (%s)",
		early.status,
		early.detail,
	)
	net_run(&session, 2)
	testing.expectf(
		t,
		!session.relay.seats[1].connected && len(session.relay.members) == 1,
		"2 s after a client stopped before its first step, slot 1 connected %v (member %d), %d members",
		session.relay.seats[1].connected,
		session.relay.seats[1].member,
		len(session.relay.members),
	)
}

// The same with a retry at once on a nearer path, same token: the stopped client's Hello, arriving after the retry's,
// used to replace the retry as the member's newest connection.
@(test)
a_retry_is_not_replaced_by_a_client_stopped_before_its_first_step :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0, .Ideal)
	net_run(&session, 1)
	early := far_join(&session, 80, RETRY_TOKEN)
	netcode.client_stop(early, session.clock.now)
	again := far_join(&session, 20, RETRY_TOKEN)
	net_run(&session, 4)
	testing.expectf(
		t,
		again.status == .Connected && session.relay.seats[1].connected && !session.relay.seats[2].connected,
		"the retry is %v (%s); seats 1 and 2 connected %v %v",
		again.status,
		again.detail,
		session.relay.seats[1].connected,
		session.relay.seats[2].connected,
	)
}

RETRY_TOKEN :: netcode.Token {
	0 = 7,
	5 = 9,
}

// A remote client asking for any slot behind a live netsim (the test changes its profiles), with `token`.
retry_join :: proc(session: ^Net, up, down: netcode.Profile, token := RETRY_TOKEN) -> (^Client, ^netcode.Net_Sim) {
	endpoint := len(session.clients) + 1
	link, netsim := netcode.netsim_live(
		netcode.loopback_link(session.hub, netcode.Peer(endpoint)),
		u32(endpoint) * 7919,
		&session.clock,
	)
	netcode.netsim_set(netsim, up, down)
	client := netcode.client_create(
		&toy.GAME,
		{slot = -1, player_name = "Linus", token = token},
		link,
		hooks_for(&session.watch[min(endpoint, 7)]),
	)
	append(&session.clients, client)
	return client, netsim
}

// Newest wins by when each try's Hello went out, not by which arrives last. The first try's first Hello is lost (one
// datagram; 8% of them on `bad`); the player cancels 120 ms later and tries again at once with the same token. The
// second try's Hello arrives and is seated; then the first try's resent Hello arrives, its Leave behind it. It used
// to replace the second try, whose connection the Leave then dropped: the player's real connection ended by their
// own cancelled one.
@(test)
a_retry_is_not_replaced_when_the_first_trys_hello_was_lost :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0, .Ideal)
	net_run(&session, 1)
	far := netcode.Profile {
		name    = "120 ms",
		latency = 120_000,
	}
	lost := netcode.Profile {
		name    = "lost",
		latency = 120_000,
		loss    = 1000,
	}
	first, first_net := retry_join(&session, lost, far)
	net_run(&session, 0.05) // its Hello went out and is lost
	netcode.netsim_set(first_net, far, far)
	net_run(&session, 0.07)
	netcode.client_stop(first, session.clock.now) // 120 ms after its Hello: cancel
	second, _ := retry_join(&session, far, far) // and try again
	net_run(&session, 3)
	testing.expectf(
		t,
		second.status == .Connected && session.relay.seats[1].connected && len(session.relay.members) == 2,
		"the second try is %v (%s), statuses %v; slot 1 connected %v; the first try %v (%s); the relay knows %d members",
		second.status,
		second.detail,
		session.watch[3].statuses[:],
		session.relay.seats[1].connected,
		first.status,
		first.detail,
		len(session.relay.members),
	)
	testing.expectf(t, first.detail == "left", "the first try finished %v (%s)", first.status, first.detail)
}

// The same with no loss: the first try's Hello is only slower than the second's (120 ms against 60 ms; the second try
// starts 30 ms after the first, the first is cancelled 10 ms later). The second's Hello arrives first.
@(test)
a_retry_is_not_replaced_when_the_first_trys_hello_was_slower :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0, .Ideal)
	net_run(&session, 1)
	slow := netcode.Profile {
		name    = "120 ms",
		latency = 120_000,
	}
	fast := netcode.Profile {
		name    = "60 ms",
		latency = 60_000,
	}
	first, _ := retry_join(&session, slow, slow)
	net_run(&session, 0.03)
	second, _ := retry_join(&session, fast, fast)
	net_run(&session, 0.01)
	netcode.client_stop(first, session.clock.now)
	net_run(&session, 3)
	testing.expectf(
		t,
		second.status == .Connected && session.relay.seats[1].connected && len(session.relay.members) == 2,
		"the second try is %v (%s), statuses %v; slot 1 connected %v; the first try %v (%s); the relay knows %d members",
		second.status,
		second.detail,
		session.watch[3].statuses[:],
		session.relay.seats[1].connected,
		first.status,
		first.detail,
		len(session.relay.members),
	)
	testing.expectf(t, first.detail == "left", "the first try finished %v (%s)", first.status, first.detail)
}

// The order's bound: an earlier try's Hello is refused only while the seated connection is live (heard within
// netcode.SEATED_LIVE_US). A seated connection gone silent (a crashed game; another machine, whose clock says nothing
// about this one's) is replaced by any try of the same person. And an earlier try that is not leaving is told why.
@(test)
an_earlier_try_replaces_a_silent_connection_and_is_told_otherwise :: proc(t: ^testing.T) {
	for seated_silent in ([]bool{false, true}) {
		session: Net
		net_make_relay(&session, 1, 0)
		net_join(&session, 0, .Ideal)
		net_run(&session, 1)
		slow := netcode.Profile {
			name    = "1.5 s",
			latency = 1_500_000,
		}
		fast := netcode.Profile {
			name    = "20 ms",
			latency = 20_000,
		}
		earlier, _ := retry_join(&session, slow, slow)
		net_run(&session, 0.01)
		later, later_net := retry_join(&session, fast, fast)
		net_run(&session, 0.2) // the later try is seated, the earlier one's Hello is on its way
		testing.expect(t, session.relay.seats[1].connected)
		if seated_silent {
			// the later try's game hangs: nothing of it reaches the relay any more
			netcode.netsim_set(later_net, {name = "gone", loss = 1000}, fast)
		}
		net_run(&session, 10)
		if seated_silent {
			testing.expectf(
				t,
				earlier.status == .Connected && session.relay.seats[1].connected,
				"a silent seated connection: the earlier try is %v (%s), slot 1 connected %v",
				earlier.status,
				earlier.detail,
				session.relay.seats[1].connected,
			)
		} else {
			testing.expectf(
				t,
				later.status == .Connected &&
				earlier.status == .Failed &&
				earlier.detail == "this player is in the session on a newer connection",
				"a live seated connection: the later try %v (%s), the earlier %v (%s)",
				later.status,
				later.detail,
				earlier.status,
				earlier.detail,
			)
		}
		net_destroy(&session)
	}
}

LONG :: #config(UNIFIED_LONG_TESTS, false) // `uni test --long`

// How often a retry is lost, over seeds (long only): the player cancels `cancel_ms` after the first try's Hello and
// retries at once, both tries on `wan` or `bad` with the same token. The retry is Connected 4 s later in every round.
when LONG {
	retries_are_never_replaced :: proc(t: ^testing.T, network: netcode.Network) {
		for cancel_ms in ([]int{30, 80, 120}) {
			failed, rounds := 0, 30
			for seed in 0 ..< rounds {
				session: Net
				net_make_relay(&session, 1, 0)
				net_join(&session, 0, .Ideal)
				net_run(&session, 1 + f64(seed) * 0.0137)
				try_join :: proc(session: ^Net, profile: netcode.Profile, seed: u32) -> ^Client {
					endpoint := len(session.clients) + 1
					link := netcode.netsim_wrap(
						netcode.loopback_link(session.hub, netcode.Peer(endpoint)),
						profile,
						seed,
						&session.clock,
					)
					client := netcode.client_create(
						&toy.GAME,
						{slot = -1, player_name = "Linus", token = RETRY_TOKEN},
						link,
						hooks_for(&session.watch[min(endpoint, 7)]),
					)
					append(&session.clients, client)
					return client
				}
				profile := netcode.PROFILES[network]
				first := try_join(&session, profile, 2 * 7919 + u32(seed) * 104729 + 1)
				net_run(&session, f64(cancel_ms) / 1000)
				netcode.client_stop(first, session.clock.now)
				second := try_join(&session, profile, 3 * 15485863 + u32(seed) * 31337 + 7)
				net_run(&session, 4)
				if second.status != .Connected || !session.relay.seats[1].connected {
					failed += 1
				}
				net_destroy(&session)
			}
			testing.expectf(
				t,
				failed == 0,
				"%v, cancelled %d ms after the Hello and retried at once: the retry is not Connected in %d of %d rounds",
				network,
				cancel_ms,
				failed,
				rounds,
			)
		}
	}
	@(test)
	retries_on_wan_are_never_replaced :: proc(t: ^testing.T) {retries_are_never_replaced(t, .Wan)}
	@(test)
	retries_on_bad_are_never_replaced :: proc(t: ^testing.T) {retries_are_never_replaced(t, .Bad)}
}

slice_has :: proc(statuses: []netcode.Status, wanted: netcode.Status) -> bool {
	for status in statuses do if status == wanted do return true
	return false
}
