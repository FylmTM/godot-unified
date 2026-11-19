// L2 netcode tests of the recovery ladder and the re-anchor (Status.Recovering): a client the checksums show as
// diverged, or one the relay's ring no longer reaches, is resynced in place from a majority player's kept snapshot and
// plays on in its seat; one that keeps needing it is dropped.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

@(private = "file")
GAME_SLIPS := toy.Game{}

// The toy with a one-off fault: at tick 100 player 0 scores once more than on every other build. The state differs from
// then on, and steps like everyone's again once it is put right.
@(private = "file")
slipping_game :: proc() -> ^toy.Game {
	GAME_SLIPS = toy.GAME
	GAME_SLIPS.tick = proc(tick: ^toy.Tick) {
		toy.tick(tick)
		if data := toy.in_slot(tick.state, 0); tick.number == 100 && data != nil do data.score += 1
	}
	return &GAME_SLIPS
}

// Every checksum `client` holds that the host's client holds too is the host's; how many were compared.
@(private = "file")
agrees_with_the_host :: proc(t: ^testing.T, session: ^Net, client: ^Client, after: u64) -> (compared: int) {
	for entry in client.checksums {
		if entry[0] <= after do continue
		for other in session.host.client.checksums {
			if entry[0] == other[0] {
				compared += 1
				testing.expectf(
					t,
					entry[1] == other[1],
					"slot %d: tick %d differs after the resync",
					client.slot,
					entry[0],
				)
			}
		}
	}
	return
}

// The join records of `slot` in the whole recording.
@(private = "file")
joins_of :: proc(session: ^Net, slot: int) -> (joins: int) {
	for &tick_inputs in net_log(session).ticks {
		if tick_inputs.joins[slot] != 0 do joins += 1
	}
	return
}

// One of three players diverges once. The relay reports it, resyncs that client from a majority player's kept
// snapshot, and every checksum agrees from then on: it kept its seat and member (one join record in the whole
// recording), its status went Recovering and back to Connected, and nobody else noticed but the report.
@(test)
a_desync_is_recovered_in_place :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 1)
	defer net_destroy(&session)
	slipped := net_join(&session, game = slipping_game())
	net_run(&session, 6)
	relay := session.relay
	testing.expect(t, relay.desyncs >= 1)
	testing.expect_value(t, relay.first_desync.diverged, sim.Slots{slipped.slot})
	testing.expect_value(t, relay.resynced, 1)
	testing.expect_value(t, slipped.stats.resyncs, 1)
	testing.expect_value(t, slipped.status, netcode.Status.Connected)
	testing.expect(t, relay.seats[slipped.slot].conn >= 0)
	testing.expect(t, slipped.verified + 32 >= relay.finalized)
	desyncs := relay.desyncs
	net_run(&session, 4)
	testing.expect_value(t, relay.desyncs, desyncs) // none since
	testing.expect(t, agrees_with_the_host(t, &session, slipped, 128) > 8)
	testing.expect_value(t, joins_of(&session, slipped.slot), 1)
	statuses := session.watch[2].statuses[:]
	recovering := false
	for status in statuses do recovering ||= status == .Recovering
	testing.expectf(t, recovering && statuses[len(statuses) - 1] == .Connected, "statuses %v", statuses)
}

// With two players the tie goes to the host: the other is resynced from the host's snapshot.
@(test)
a_desync_of_two_players_resyncs_the_other_from_the_host :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	slipped := net_join(&session, game = slipping_game())
	net_run(&session, 8)
	testing.expect_value(t, session.relay.resynced, 1)
	testing.expect_value(t, slipped.stats.resyncs, 1)
	testing.expect_value(t, session.host.client.stats.resyncs, 0)
	testing.expect_value(t, slipped.status, netcode.Status.Connected)
	testing.expect(t, agrees_with_the_host(t, &session, slipped, 128) > 8)
}

// A client that diverges on every tick from 100 on is resynced RESYNCS_MAX times, then dropped (Desynced); the others
// play on.
@(test)
a_client_that_keeps_diverging_is_dropped :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 1)
	defer net_destroy(&session)
	broken := net_join(&session, game = diverging_game())
	net_run(&session, 20)
	testing.expect_value(t, broken.status, netcode.Status.Disconnected)
	testing.expect_value(t, broken.detail, "diverged from the other players and could not be resynced")
	testing.expect_value(t, broken.stats.resyncs, netcode.RESYNCS_MAX)
	testing.expect_value(t, session.clients[0].status, netcode.Status.Connected)
	testing.expect(t, session.clients[0].verified + 32 >= session.relay.finalized)
}

// The toy's commands (its scripted bursts) around a resync: each of the resynced player's commands lands exactly once
// (the relay's recording holds every one it sent, in order), and once it verified past them it predicts none of them.
@(test)
commands_around_a_resync_land_once :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 1)
	defer net_destroy(&session)
	slipped := net_join(&session, game = slipping_game())
	net_run(&session, 8)
	testing.expect_value(t, slipped.stats.resyncs, 1)
	commands, ticks := logged_commands(net_log(&session), slipped.slot)
	defer delete(commands)
	defer delete(ticks)
	sent := sent_commands(slipped.slot, slipped.first_tick, session.relay.finalized - 64)
	defer delete(sent)
	testing.expect(t, len(commands) >= len(sent))
	for command, i in sent {
		if i < len(commands) && !same_command(commands[i], command) {
			testing.expectf(t, false, "command %d differs (or was lost or doubled)", i)
			break
		}
	}
	testing.expect(t, len(slipped.locals[0].own_cmds) <= 16, "no command predicted forever")
	testing.expect(t, agrees_with_the_host(t, &session, slipped, 128) > 8)
}

// A client too slow to verify the session's ticks (stepped 20 times a second, one tick a step: under a third of the
// tick rate) falls behind until the relay's ring no longer reaches it. It is re-anchored in place: a majority player's
// recent snapshot, the stream from its tick, the same seat (one join record), and it plays on at the live tick.
@(test)
a_client_past_the_relays_ring_is_reanchored_in_place :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	link := netcode.netsim_wrap(netcode.loopback_link(session.hub, 1), netcode.PROFILES[.Wan], 7919, &session.clock)
	slow := netcode.client_create(
		&toy.GAME,
		{slot = -1, player_name = "Grace", catchup_ticks = 1},
		link,
		hooks_for(&session.watch[1]),
	)
	append(&session.clients, slow)
	net_run(&session, 3)
	testing.expect_value(t, slow.status, netcode.Status.Connected)
	slot := slow.slot
	for slow.stats.resyncs == 0 && !netcode.client_finished(slow) && session.clock.now < 200_000_000 {
		net_run(&session, 0.05, hitched = 0) // everyone but the slow client
		netcode.client_step(slow, session.clock.now)
	}
	testing.expect_value(t, slow.stats.resyncs, 1)
	slow.cfg.catchup_ticks = 0
	net_run(&session, 5)
	testing.expect_value(t, slow.status, netcode.Status.Connected)
	testing.expect_value(t, slow.slot, slot)
	testing.expect_value(t, slow.stats.reconnects, 0)
	testing.expect(t, slow.verified + 32 >= session.relay.finalized)
	testing.expect_value(t, session.relay.desyncs, 0)
	testing.expect_value(t, joins_of(&session, slot), 1)
	expect_agree(t, &session)
}

// A diverged client with two local players: the one connection is resynced once, both its seats stay (one join record
// each), each local player's commands up to the snapshot's tick are dropped and the rest land, and it agrees after.
@(test)
a_client_with_two_local_players_is_resynced_once :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 1)
	defer net_destroy(&session)
	slipped := net_join(&session, game = slipping_game())
	testing.expect(t, add_second(slipped))
	net_run(&session, 8)
	testing.expect_value(t, session.relay.resynced, 1)
	testing.expect_value(t, slipped.stats.resyncs, 1)
	testing.expect_value(t, slipped.status, netcode.Status.Connected)
	for local in 0 ..< 2 {
		info := netcode.client_local(slipped, local)
		testing.expect_value(t, info.state, netcode.Local_State.Seated)
		testing.expect_value(t, joins_of(&session, info.slot), 1)
		testing.expect(t, len(slipped.locals[local].own_cmds) <= 16, "no command predicted forever")
	}
	testing.expect(t, agrees_with_the_host(t, &session, slipped, 128) > 8)
}
