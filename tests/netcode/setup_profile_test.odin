// The session's Setup and the players' Profiles over the wire: Welcome carries the Setup, a Hello the Profile, the
// relay writes it beside the join record and seats one new player per tick.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"
import "unified:wire"

// Every client plays the host's Setup (a start client builds tick 0 with it, a joiner gets it in its snapshot), every
// peer sees each player's own Profile from their join tick, and the relay's log replays the session with both.
@(test)
the_setup_and_each_profile_reach_every_peer :: proc(t: ^testing.T) {
	session: Net
	setup := toy.Setup {
		life_bonus = 9,
	}
	net_make(&session, 0, 0, setup = setup)
	defer net_destroy(&session)
	net_run(&session, 1)
	joiners := [2]^Client{net_join(&session), net_join(&session)}
	net_run(&session, 6)
	host := session.host.client
	clients := [3]^Client{host, joiners[0], joiners[1]}
	firsts: [3]u32
	for client, i in clients {
		testing.expectf(t, client.status == .Connected && client.sim != nil, "client %d is %v", i, client.status)
		if client.sim == nil do return
		testing.expect_value(t, client.sim.setup, setup)
		testing.expect_value(t, client.setup, setup)
		firsts[i] = client.first_tick
	}
	testing.expect(t, firsts[0] == 1 && firsts[1] != firsts[2], "one new player per tick")
	want := [3]u8{HOST_COLOR, endpoint_color(1), endpoint_color(2)}
	for client in clients {
		for other, i in clients {
			player := sim.player_in_slot(client.sim, other.slot)
			testing.expect_value(t, sim.player_profile(client.sim, player).color, want[i])
			testing.expect_value(t, sim.player_data(client.sim, player).color, u32(want[i]))
		}
	}
	testing.expect_value(t, session.relay.desyncs, 0)
	netcode.host_stop(session.host, session.clock.now)
	net_run(&session, 1)
	recorded := net_log(&session)
	testing.expect_value(t, recorded.setup, setup)
	replay := sim.create(&toy.GAME, recorded.seed, recorded.setup)
	defer sim.destroy(replay)
	last := host.checksums[len(host.checksums) - 1] // the host's newest verified checksum tick
	for k in 0 ..< len(recorded.ticks) {
		inputs := sim.log_inputs(recorded, k)
		sim.step(replay, &inputs)
		if u64(replay.tick) == last[0] do break
	}
	testing.expect_value(t, u64(replay.tick), last[0])
	testing.expect_value(t, sim.checksum(replay), last[1])
}

// The start players become present on ticks 1, 2, 3 in slot order: a tick carries at most one join record and its
// Profile, so the widest tick holds one whatever the player count.
@(test)
start_players_join_one_per_tick :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 3, 0)
	defer net_destroy(&session)
	for slot in 0 ..< 3 do net_join(&session, slot)
	net_run(&session, 3)
	for client, slot in session.clients {
		testing.expect_value(t, client.status, netcode.Status.Connected)
		testing.expect_value(t, client.first_tick, u32(slot + 1))
	}
	for tick in u32(1) ..= 3 {
		inputs := netcode.relay_tick(session.relay, tick)
		testing.expect_value(t, sim.join_count(inputs.joins[:]), 1)
		testing.expect_value(t, inputs.profiles[tick - 1].color, endpoint_color(int(tick)))
	}
}

// A Hello whose Profile is not this build's size comes only from a modified client: it is refused as incompatible.
@(test)
a_profile_of_another_size_is_refused :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	evil: Evil
	evil.channel = netcode.channel_make()
	defer evil_destroy(&evil)
	link_index := netcode.channel_add_link(evil.channel, netcode.loopback_link(session.hub, 7))
	evil.peer = netcode.channel_peer(evil.channel, link_index, 0)
	evil.writer = wire.writer_make(64)
	hello := netcode.Hello {
		compat     = sim.compat_of(&toy.GAME),
		seat_count = 1,
	}
	hello.seats[0] = {
		slot = netcode.ANY_SLOT,
		profile = {len = size_of(toy.Profile) + 1},
	}
	netcode.write_hello(&evil.writer, &hello)
	evil_send(&evil, &session)
	reply := evil_run(&evil, &session, 0.5, .Reject)
	testing.expect(t, len(reply) == 3 && netcode.Reject_Reason(reply[1]) == .Incompatible, "rejected as incompatible")
	testing.expect(t, !session.relay.started, "nobody seated")
}
