// L2 netcode tests for late join's snapshot check: a joiner's restored snapshot is compared with the other
// players' checksum of its tick before it plays; a bad one is refused and another player asked.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"
import "unified:wire"

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
	session: Net
	net_make_relay(&session, 3, 0)
	defer net_destroy(&session)
	net_join(&session, 0, game = diverging_game())
	net_join(&session, 1)
	net_join(&session, 2)
	net_run(&session, 3)
	testing.expect(t, session.relay.desyncs > 0) // player 0 parted from the others at tick 100
	testing.expect(t, sim.Slots{0} <= session.relay.first_desync.diverged)
	joiner := net_join(&session, 3)
	net_run(&session, 1, proc(session: ^Net) -> bool {return session.relay.seats[3].provider >= 0})
	testing.expect_value(t, session.relay.seats[3].provider, 0) // asked first: the lowest that can provide
	net_run(&session, 4)
	testing.expect(t, 0 in session.relay.seats[3].refused)
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
	session: Net
	net_make_relay(&session, 3, 0)
	defer net_destroy(&session)
	net_join(&session, 0, game = diverging_game())
	net_join(&session, 1)
	net_join(&session, 2)
	net_run(&session, 3)
	joiner := net_join(&session, 3)
	net_run(&session, 4, proc(session: ^Net) -> bool {return 0 in session.relay.seats[3].refused})
	testing.expect(t, 0 in session.relay.seats[3].refused)
	netcode.client_stop(session.clients[1], session.clock.now)
	netcode.client_stop(session.clients[2], session.clock.now)
	net_run(&session, 2)
	testing.expect_value(t, joiner.status, netcode.Status.Failed)
	testing.expect_value(
		t,
		joiner.detail,
		"the snapshot differed from the other players' and nobody else could send one",
	)
	testing.expect(t, !session.relay.seats[3].connected)
}

// A joiner that leaves before its provider sent the snapshot, and another one in the same seat right after: the
// provider holds one request per joiner's seat, so it answers the newer one (a snapshot the new joiner may take),
// not the stale one (whose tick the relay would call unusable, refusing the only provider).
@(test)
a_quick_rejoin_is_sent_a_fresh_snapshot :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0, .Ideal)
	net_run(&session, 2)
	first := net_join(&session, -1, .Ideal)
	net_run(&session, 1, proc(session: ^Net) -> bool {return session.relay.seats[1].provider >= 0})
	testing.expect_value(t, session.relay.seats[1].provider, 0)
	net_run(&session, 0.3)
	netcode.client_stop(first, session.clock.now)
	net_run(&session, 0.02)
	testing.expect(t, !session.relay.seats[1].connected)
	second := net_join(&session, -1, .Ideal)
	net_run(&session, 5)
	testing.expectf(t, second.status == .Connected, "the second joiner is %v (%s)", second.status, second.detail)
	testing.expect_value(t, len(session.clients[0].snap_reqs), 0)
}

// A provider's Snap_Begin for a checksum tick, then one for an older tick with that tick's genuine snapshot: the
// joiner starts its finalized ticks over from the second (the relay streams from there), loads it and plays. (A
// crafted snapshot can do no more than fail to load.)
@(test)
an_older_snapshot_after_a_newer_begin_loads :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 2, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 0) // the lowest seat: the one asked for a snapshot
	defer evil_destroy(&evil)
	evil.acking = true
	honest := net_join(&session, 1, .Ideal)
	evil_run(&evil, &session, 1)
	joiner := net_join(&session, -1, .Ideal)
	evil_run(&evil, &session, 0.1)
	testing.expect_value(t, session.relay.seats[2].provider, 0)
	older := (session.relay.seats[2].snap_min + 15) / 16 * 16 // the first checksum tick the joiner may start from
	newer := older + 16
	for honest.verified < older {
		evil_run(&evil, &session, 0.01)
	}
	if !testing.expect(t, sim.state_at(honest.sim, older) != nil, "the honest client's ring lost the tick") {
		return
	}
	snapshot := sim.snapshot_encode(honest.sim, older)
	defer delete(snapshot)
	for session.relay.finalized < newer {
		evil_run(&evil, &session, 0.01)
	}
	writer := evil_begin(&evil, .Snap_Begin)
	wire.w_u8(writer, 2)
	wire.w_u32(writer, newer)
	wire.w_u32(writer, 100)
	evil_send(&evil, &session)
	evil_run(&evil, &session, 0.2)
	testing.expectf(
		t,
		joiner.fin_upto >= newer,
		"the joiner holds the stream from %d: fin_upto %d",
		newer,
		joiner.fin_upto,
	)
	evil_snapshot(&evil, &session, 2, older, snapshot)
	evil_run(&evil, &session, 4)
	testing.expectf(
		t,
		joiner.status == .Connected && joiner.verified > newer,
		"the joiner is %v (%s), verified %d",
		joiner.status,
		joiner.detail,
		joiner.verified,
	)
}

// The snapshot's tick is one no other player reports (its provider never sends that checksum, or leaves): with
// nothing to compare it with, the relay lets the joiner in unchecked after twice CHECK_WAIT_MS, and counts it.
@(test)
a_snapshot_nobody_else_reports_is_let_in_unchecked :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 0) // the only player: the provider, which never reports a checksum
	defer evil_destroy(&evil)
	evil.acking = true
	evil_run(&evil, &session, 1)
	joiner := net_join(&session, -1, .Ideal)
	evil_run(&evil, &session, 0.1)
	testing.expect_value(t, session.relay.seats[1].provider, 0)
	tick := (session.relay.seats[1].snap_min + 15) / 16 * 16
	for session.relay.finalized < tick {
		evil_run(&evil, &session, 0.01)
	}
	// The genuine state of `tick`, computed from the relay's finalized inputs.
	simulation := sim.create(&toy.GAME, SEED)
	defer sim.destroy(simulation)
	for number in 1 ..= tick {
		inputs := netcode.relay_tick(session.relay, number)^
		sim.step(simulation, &inputs)
	}
	snapshot := sim.snapshot_encode(simulation, tick)
	defer delete(snapshot)
	evil_snapshot(&evil, &session, 1, tick, snapshot)
	evil_run(&evil, &session, 1)
	testing.expect_value(t, joiner.status, netcode.Status.Connecting) // waiting for a checksum to compare with
	evil_run(&evil, &session, 3)
	testing.expectf(t, joiner.status == .Connected, "the joiner is %v (%s)", joiner.status, joiner.detail)
	testing.expect(t, joiner.verified > tick)
	testing.expect_value(t, session.relay.unchecked_snapshots, 1)
}
