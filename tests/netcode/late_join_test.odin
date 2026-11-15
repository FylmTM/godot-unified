// L2 netcode tests for late join's snapshot check: a joiner's restored snapshot is compared with the other
// players' checksum of its tick before it plays; a bad one is refused and another player asked.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

// The toy with a rule only one build has (same compat: the rule isn't in any layout): every tick from 100 on,
// player 0 scores. Its state parts from everyone else's at tick 100.
@(private)
GAME_DIVERGES := toy.Game{}

@(private)
diverging_game :: proc() -> ^toy.Game {
	GAME_DIVERGES = toy.GAME
	GAME_DIVERGES.tick = proc(tick: ^toy.Tick) {
		toy.tick(tick)
		if data := toy.in_slot(tick.state, 0); tick.number >= 100 && data != nil do data.score += 1
	}
	return &GAME_DIVERGES
}

// Player 0 (the lowest, so the one asked first) has diverged: its snapshot for a joiner restores to a checksum the
// majority (players 1 and 2) doesn't have. The relay asks player 1 instead, and the joiner plays from that one.
@(test)
a_bad_snapshot_is_refused_and_another_player_sends_one :: proc(t: ^testing.T) {
	session: Rnet
	rnet_make(&session, 3, 0)
	defer rnet_destroy(&session)
	rnet_join(&session, 0, diverging_game())
	rnet_join(&session, 1)
	rnet_join(&session, 2)
	rnet_run(&session, 3)
	testing.expect(t, session.relay.desyncs > 0) // player 0 parted from the others at tick 100
	testing.expect(t, sim.Slots{0} <= session.relay.first_desync.diverged)
	joiner := rnet_join(&session, 3)
	rnet_run(&session, 1, proc(session: ^Rnet) -> bool {return session.relay.provider[3] >= 0})
	testing.expect_value(t, session.relay.provider[3], 0) // asked first: the lowest that can provide
	rnet_run(&session, 4)
	testing.expect(t, 0 in session.relay.refused[3])
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect(t, joiner.verified > joiner.first_tick)
	// The joiner agrees with the honest players.
	for other in session.clients[1:3] {
		for entry in joiner.checksums {
			for other_entry in other.checksums {
				if entry[0] == other_entry[0] {
					testing.expectf(
						t,
						entry[1] == other_entry[1],
						"joiner and %d differ at tick %d",
						other.slot,
						entry[0],
					)
				}
			}
		}
	}
}

// ... and when the players who could send another leave, the joiner is refused: its snapshot was bad.
@(test)
a_bad_snapshot_with_nobody_else_refuses_the_joiner :: proc(t: ^testing.T) {
	session: Rnet
	rnet_make(&session, 3, 0)
	defer rnet_destroy(&session)
	rnet_join(&session, 0, diverging_game())
	rnet_join(&session, 1)
	rnet_join(&session, 2)
	rnet_run(&session, 3)
	joiner := rnet_join(&session, 3)
	rnet_run(&session, 4, proc(session: ^Rnet) -> bool {return 0 in session.relay.refused[3]})
	testing.expect(t, 0 in session.relay.refused[3])
	netcode.client_stop(session.clients[1], session.clock.now)
	netcode.client_stop(session.clients[2], session.clock.now)
	rnet_run(&session, 2)
	testing.expect_value(t, joiner.status, netcode.Status.Failed)
	testing.expect_value(
		t,
		joiner.detail,
		"the snapshot differed from the other players' and nobody else could send one",
	)
	testing.expect(t, !session.relay.connected[3])
}
