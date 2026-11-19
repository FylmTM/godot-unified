// Several local players on one client: one connection, one sim, up to LOCAL_MAX seats, each its own member that
// joins, leaves and comes back on its own.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

// Local player `local`'s Profile colour in these tests.
local_color :: proc(local: int) -> u8 {
	return u8(40 + local)
}

// Adds local player 1 to `client` (before its first step: in its Hello; later: a Join).
add_second :: proc(client: ^Client) -> bool {
	return netcode.client_add_player(
		client,
		1,
		{slot = -1, player_name = "Second", profile = {color = local_color(1)}},
	)
}

// A bump from local player 1 only, once: it lands in local 1's slot, exactly once.
Second_Sender :: struct {
	sent:  bool,
	calls: [netcode.LOCAL_MAX]int, // sample calls by local player
}

second_sender_hooks :: proc(sender: ^Second_Sender, watch: ^Watch) -> Hooks {
	hooks := hooks_for(watch)
	hooks.user = sender
	hooks.sample = proc(user: rawptr, local, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
		(^Second_Sender)(user).calls[local] += 1
		return toy.scripted_input(SEED, slot, tick)
	}
	hooks.commands = proc(
		user: rawptr,
		local, slot: int,
		tick: u32,
		state: ^toy.State,
		out: ^sim.Command_Out(toy.Cmd),
	) {
		sender := (^Second_Sender)(user)
		if local == 1 && !sender.sent && tick > 40 {
			sender.sent = sim.send_command(out, toy.Cmd_Bump{1234})
		}
	}
	hooks.frame, hooks.verified, hooks.status = nil, nil, nil
	return hooks
}

// Two local players in single player: one Hello seats both (slots 0 and 1, present on ticks 1 and 2), each samples its
// own input, and a command from the second lands in its slot once.
@(test)
two_local_players_in_single_player :: proc(t: ^testing.T) {
	session: Net
	sender: Second_Sender
	session.clock.now = 1_000_000
	session.hub = netcode.hub_create(8)
	session.host = netcode.host_create(
		&toy.GAME,
		{seed = SEED, player_name = "Ada", profile = {color = HOST_COLOR}},
		second_sender_hooks(&sender, &session.watch[0]),
	)
	session.relay = session.host.relay
	defer net_destroy(&session)
	host := session.host.client
	testing.expect(t, add_second(host))
	net_run(&session, 3)
	first, second := netcode.client_local(host, 0), netcode.client_local(host, 1)
	testing.expect_value(t, first.state, netcode.Local_State.Seated)
	testing.expect_value(t, second.state, netcode.Local_State.Seated)
	testing.expect_value(t, first.slot, 0)
	testing.expect_value(t, second.slot, 1)
	testing.expect_value(t, first.first_tick, 1)
	testing.expect_value(t, second.first_tick, 2)
	testing.expect(t, sender.calls[0] > 100 && sender.calls[1] > 100, "both local players sampled")
	testing.expect(t, sender.sent, "local 1 sent its command")
	bumps := sim.slot_data(host.sim, 1).bumps
	testing.expect_value(t, bumps, 1)
	testing.expect_value(t, sim.slot_data(host.sim, 1).bump_sum, 1234)
	testing.expect_value(t, sim.slot_data(host.sim, 0).bumps, 0)
	player := sim.player_in_slot(host.sim, 1)
	testing.expect_value(t, sim.player_profile(host.sim, player).color, local_color(1))
	entry := netcode.client_member(host, player.id)
	testing.expect(t, entry != nil && entry.local == 1, "the roster names local player 1")
}

// Two local players joined to a host with a third remote one: the couch's connection is one sim and one stream,
// every peer agrees, nobody desyncs, and the relay's log replays.
@(test)
two_local_players_join_a_host_beside_a_remote_one :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	net_run(&session, 1)
	couch := net_join(&session)
	testing.expect(t, add_second(couch))
	remote := net_join(&session)
	net_run(&session, 8)
	testing.expect_value(t, couch.status, netcode.Status.Connected)
	testing.expect_value(t, remote.status, netcode.Status.Connected)
	testing.expect_value(t, netcode.client_local(couch, 1).state, netcode.Local_State.Seated)
	testing.expect_value(t, session.relay.desyncs, 0)
	slots: sim.Slots
	for client in ([]^Client{session.host.client, couch, remote}) {
		testing.expect_value(t, sim.present_count(client.sim), 4)
		testing.expect_value(t, client.stats.desyncs, 0)
	}
	slots += {netcode.client_local(couch, 0).slot, netcode.client_local(couch, 1).slot}
	testing.expect_value(t, card(slots), 2)
	expect_agree(t, &session)
}

// One local player leaves and comes back while the other plays: the same member returns (its data kept), no
// snapshot is sent again, and every peer agrees across the leave and the join.
@(test)
a_local_player_leaves_and_returns_while_the_other_plays :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	net_run(&session, 1)
	couch := net_join(&session)
	couch.cfg.token = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} // what its players are recognized by
	testing.expect(t, add_second(couch))
	net_run(&session, 4)
	second := netcode.client_local(couch, 1)
	testing.expect_value(t, second.state, netcode.Local_State.Seated)
	snapshot_bytes := couch.stats.snapshot_bytes
	member := second.member
	netcode.client_remove_player(couch, 1, session.clock.now)
	net_run(&session, 2)
	testing.expect_value(t, session.relay.seats[second.slot].conn, netcode.Peer(-1))
	testing.expect_value(t, couch.status, netcode.Status.Connected)
	testing.expect(t, add_second(couch))
	net_run(&session, 4)
	back := netcode.client_local(couch, 1)
	testing.expect_value(t, back.state, netcode.Local_State.Seated)
	testing.expect_value(t, back.member, member) // the same person: its key is the connection's plus #1
	testing.expect_value(t, couch.stats.snapshot_bytes, snapshot_bytes) // a Join needs no snapshot
	testing.expect_value(t, session.relay.desyncs, 0)
	expect_agree(t, &session)
}

// A Hello for two seats when one is free is refused whole: nobody of it is seated.
@(test)
a_hello_for_more_seats_than_are_free_is_refused_whole :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	for _ in 0 ..< 3 do net_join(&session)
	net_run(&session, 3)
	couch := net_join(&session)
	testing.expect(t, add_second(couch))
	net_run(&session, 3)
	testing.expect_value(t, couch.status, netcode.Status.Failed)
	testing.expect_value(t, couch.detail, "the session is full")
	testing.expect_value(t, session.relay.seats[3].conn, netcode.Peer(-1))
}
