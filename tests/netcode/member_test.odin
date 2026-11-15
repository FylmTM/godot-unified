// Players are session members (src/netcode/SPEC.md, Members): the relay recognizes a person who comes back by the
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
		netcode.PROFILES[1],
		u32(endpoint) * 7919 + u32(len(session.clients)),
		&session.clock,
	)
	client := netcode.client_create(&toy.GAME, {
			slot        = -1,
			name        = name,
			player_name = name,
			token       = token,
			quiet       = true,
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
		testing.expect_value(t, netcode.name_string(&entry.name), "Ann")
		testing.expect(t, entry.connected && int(entry.slot) == again.slot)
		testing.expect_value(t, netcode.text_string(&entry.platform), "") // a token is never forwarded
	}
	expect_agree(t, &session)
	testing.expect(t, !recorded(&session, token[:]), "the token is not in the recording")
}

@(test)
a_vouched_account_brings_the_member_back :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	hub := netcode.hub_create(8)
	defer netcode.hub_destroy(hub)
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
		testing.expect_value(t, netcode.name_string(&entry.name), "Ann (again)")
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
	testing.expect(t, session.host.relay.connected[1])
	restarted := member_join(&session, session.hub, 2, "Cy", token)
	net_run(&session, 3) // far below the channel's 10 s timeout
	testing.expect_value(t, restarted.status, netcode.Status.Connected)
	testing.expect_value(t, restarted.member, member)
	back, _ := host_player(&session, restarted.slot)
	testing.expect_value(t, back, player)
	connected := 0
	for slot in 0 ..< toy.PLAYERS do connected += int(session.host.relay.connected[slot])
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
