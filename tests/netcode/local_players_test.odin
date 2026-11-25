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
	return netcode.client_add_player(client, 1, {player_name = "Second", profile = {color = local_color(1)}})
}

// A bump from local player 1 only, once: it lands in local 1's slot, exactly once.
Second_Sender :: struct {
	sent:  bool,
	calls: [netcode.LOCAL_MAX]int, // sample calls by local player
}

second_sender_hooks :: proc(sender: ^Second_Sender, watch: ^Watch) -> Hooks {
	hooks := hooks_for(watch)
	hooks.user = sender
	hooks.sample = proc(user: rawptr, local, slot: int, tick: u32, state: ^toy.State, setup: toy.Setup) -> toy.Input {
		(^Second_Sender)(user).calls[local] += 1
		return toy.scripted_input(SEED, slot, tick)
	}
	hooks.commands = proc(
		user: rawptr,
		local, slot: int,
		tick: u32,
		state: ^toy.State,
		setup: toy.Setup,
		out: ^sim.Command_Out(toy.Command),
	) {
		sender := (^Second_Sender)(user)
		if local == 1 && !sender.sent && tick > 40 {
			sender.sent = sim.send_command(out, toy.Command_Bump{1234})
		}
	}
	hooks.frame, hooks.verified, hooks.status, hooks.verified_state = nil, nil, nil, nil // they take user as a ^Watch
	return hooks
}

// Two local players in single player: one Hello seats both (slots 0 and 1, present on ticks 1 and 2), each samples its
// own input, and a command from the second lands in its slot once.
@(test)
two_local_players_in_single_player :: proc(t: ^testing.T) {
	session: Net
	sender: Second_Sender
	net_make(&session, 0, 0, record = false, hooks = second_sender_hooks(&sender, &session.watch[0]), linked = false)
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

// A local player's Seated reaches the client only after the finalized ticks past its join tick (the relay -> client
// path blacked out around the Join): the client still seats it, its first inputs replaced. Before, it stayed Asked
// while the relay seated it, and every tick then waited the full tolerance for its input.
@(test)
a_seated_after_its_join_tick_is_final_still_seats_the_player :: proc(t: ^testing.T) {
	for profile in ([]netcode.Network{.Ideal, .Wan}) {
		for outage in ([]f64{0.8, 1.2, 1.7}) {
			session: Net
			net_make(&session, 0, 0)
			couch, gate := gated_join(&session, 1, netcode.PROFILES[profile], &session.watch[1])
			net_run(&session, 3)
			testing.expect_value(t, couch.status, netcode.Status.Connected)
			gate.block_in = true
			testing.expect(t, add_second(couch))
			net_run(&session, outage)
			gate.block_in = false
			net_run(&session, 4)
			second := netcode.client_local(couch, 1)
			replaced_before := session.relay.replaced
			net_run(&session, 1)
			replaced := session.relay.replaced - replaced_before
			testing.expectf(
				t,
				second.state == .Seated && replaced == 0,
				"%v, outage %.1f s: local 1 is %v; %d inputs replaced in the last second",
				profile,
				outage,
				second.state,
				replaced,
			)
			expect_agree(t, &session)
			net_destroy(&session)
		}
	}
}

// A couch joins late with two local players; its local player 0 (its lowest slot, the one the snapshot request named
// it by) leaves while the snapshot is on its way. Local player 1 still gets in.
@(test)
the_lowest_seat_leaving_mid_join_keeps_the_snapshot_coming :: proc(t: ^testing.T) {
	for profile in ([]netcode.Network{.Ideal, .Wan}) {
		session: Net
		net_make(&session, 0, 0)
		net_run(&session, 2)
		couch := net_join(&session, profile = profile)
		testing.expect(t, add_second(couch))
		for _ in 0 ..< 2000 {
			net_run(&session, 0.005)
			if couch.welcomed do break
		}
		testing.expect(t, couch.status != .Connected, "still joining when local 0 leaves")
		netcode.client_remove_player(couch, 0, session.clock.now)
		net_run(&session, 15)
		second := netcode.client_local(couch, 1)
		testing.expectf(
			t,
			couch.status == .Connected && second.state == .Seated,
			"%v: couch %v %q, local 1 %v",
			profile,
			couch.status,
			couch.detail,
			second.state,
		)
		expect_agree(t, &session)
		net_destroy(&session)
	}
}

// ... and a new joiner takes the emptied slot while both wait for a snapshot from the same provider, whose answers
// carry that slot: both get in.
@(test)
a_new_occupant_of_a_joiners_emptied_lowest_seat_gets_in_beside_it :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	net_run(&session, 2)
	couch := net_join(&session, profile = .Ideal)
	testing.expect(t, add_second(couch))
	for _ in 0 ..< 2000 {
		net_run(&session, 0.005)
		if couch.welcomed do break
	}
	lowest := netcode.client_local(couch, 0).slot
	netcode.client_remove_player(couch, 0, session.clock.now)
	newcomer := net_join(&session, profile = .Ideal)
	for _ in 0 ..< 2000 {
		net_run(&session, 0.005)
		if newcomer.welcomed do break
	}
	testing.expect(t, couch.status != .Connected, "the couch still joins when the newcomer is seated")
	testing.expect_value(t, newcomer.slot, lowest)
	net_run(&session, 15)
	second := netcode.client_local(couch, 1)
	testing.expectf(
		t,
		couch.status == .Connected && second.state == .Seated && newcomer.status == .Connected,
		"couch %v %q (local 1 %v), newcomer %v %q",
		couch.status,
		couch.detail,
		second.state,
		newcomer.status,
		newcomer.detail,
	)
	testing.expect_value(t, session.relay.desyncs, 0)
	expect_agree(t, &session)
}

// A second local player asks for a seat the relay refuses (the host's slot: Slot_Taken) and is taken back before the
// Reject arrives: its Leave names a local player the relay never seated. The first local player plays on.
@(test)
a_refused_local_player_taken_back_keeps_the_connection :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 1)
	defer net_destroy(&session)
	client := session.clients[0]
	net_run(&session, 3)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	slot := client.slot
	testing.expect(t, netcode.client_add_player(client, 1, {slot = 0, player_name = "Second"}))
	netcode.client_step(client, session.clock.now) // its Join goes out
	netcode.client_remove_player(client, 1, session.clock.now) // ... and it is taken back at once
	net_run(&session, 3)
	testing.expectf(
		t,
		client.status == .Connected && session.relay.seats[slot].conn >= 0,
		"the first local player: status %v (%s), its seat's connection %d",
		client.status,
		client.detail,
		session.relay.seats[slot].conn,
	)
	testing.expect_value(t, netcode.client_local(client, 1).state, netcode.Local_State.None)
}
