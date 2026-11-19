// Open to friends: a host alone (single player) gets its first remote link while it runs, and a closed session lets
// nobody new in while a player who was in comes back.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

// A single-player host that has played alone for a while opens to a friend: the friend joins late from the host's
// snapshot, both agree, and the relay's log replays from tick 1.
@(test)
a_single_player_session_opens_to_a_friend :: proc(t: ^testing.T) {
	session: Net
	session.clock.now = 1_000_000
	session.hub = netcode.hub_create(8)
	session.host = netcode.host_create(&toy.GAME, {
			seed = SEED,
			player_name = "Ada",
			profile = {color = HOST_COLOR},
			recording = sim.log_sink_memory(&session.recording),
		}, hooks_for(&session.watch[0]))
	session.relay = session.host.relay
	defer net_destroy(&session)
	net_run(&session, 5)
	testing.expect(t, netcode.host_solo(session.host), "alone so far")
	alone_until := session.host.client.verified
	testing.expect(t, alone_until > 300, "single player ran")
	netcode.host_add_link(session.host, netcode.loopback_link(session.hub, 0))
	testing.expect(t, !netcode.host_solo(session.host))
	friend := net_join(&session)
	net_run(&session, 5)
	testing.expect_value(t, friend.status, netcode.Status.Connected)
	testing.expect(t, friend.stats.snapshot_bytes > 0, "a late join from the host's snapshot")
	testing.expect(t, friend.first_tick > alone_until)
	testing.expect_value(t, session.relay.desyncs, 0)
	expect_agree(t, &session)
	netcode.host_stop(session.host, session.clock.now)
	net_run(&session, 1)
	recorded := net_log(&session)
	replay := sim.create(&toy.GAME, recorded.seed, recorded.setup)
	defer sim.destroy(replay)
	last := session.host.client.checksums[len(session.host.client.checksums) - 1]
	for k in 0 ..< len(recorded.ticks) {
		inputs := sim.log_inputs(recorded, k)
		sim.step(replay, &inputs)
		if u64(replay.tick) == last[0] do break
	}
	testing.expect_value(t, sim.checksum(replay), last[1])
}

// Closed to new players: a newcomer is refused (Closed), a player who was in comes back; opened again, a newcomer joins.
@(test)
a_closed_session_lets_only_its_players_back :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	net_run(&session, 1)
	friend := net_join(&session)
	friend.cfg.token = {7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7}
	net_run(&session, 4)
	testing.expect_value(t, friend.status, netcode.Status.Connected)
	member := friend.member
	netcode.client_stop(friend, session.clock.now)
	net_run(&session, 1)
	netcode.host_set_open(session.host, false)
	stranger := net_join(&session)
	stranger.cfg.token = {9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	net_run(&session, 2)
	testing.expect_value(t, stranger.status, netcode.Status.Failed)
	testing.expect_value(t, stranger.detail, "the session takes no new players")
	back := net_join(&session)
	back.cfg.token = friend.cfg.token
	net_run(&session, 4)
	testing.expect_value(t, back.status, netcode.Status.Connected)
	testing.expect_value(t, back.member, member) // the same person
	netcode.host_set_open(session.host, true)
	newcomer := net_join(&session)
	net_run(&session, 4)
	testing.expect_value(t, newcomer.status, netcode.Status.Connected)
	testing.expect_value(t, session.relay.desyncs, 0)
}

// The host's own player gets the account a lobby opened later knows it by: every client's roster shows it.
@(test)
the_hosts_account_reaches_every_roster :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 1)
	defer net_destroy(&session)
	net_run(&session, 4)
	netcode.host_set_account(session.host, {platform = "eos", id = "0002ada"}, session.clock.now)
	net_run(&session, 1)
	host_member := session.host.client.member
	for client in ([]^Client{session.host.client, session.clients[0]}) {
		entry := netcode.client_member(client, host_member)
		testing.expect(
			t,
			entry != nil && netcode.text_string(&entry.account) == "0002ada",
			"the host's account in the roster",
		)
	}
}
