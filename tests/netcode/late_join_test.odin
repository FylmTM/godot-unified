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
	net_run(&session, 1, proc(session: ^Net) -> bool {return provider_slot(session.relay, 3) >= 0})
	testing.expect_value(t, provider_slot(session.relay, 3), 0) // asked first: the lowest that can provide
	net_run(&session, 4)
	testing.expect(t, refused_slot(session.relay, 3, 0))
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
	net_run(&session, 4, proc(session: ^Net) -> bool {return refused_slot(session.relay, 3, 0)})
	testing.expect(t, refused_slot(session.relay, 3, 0))
	netcode.client_stop(session.clients[1], session.clock.now)
	netcode.client_stop(session.clients[2], session.clock.now)
	net_run(&session, 2)
	testing.expect_value(t, joiner.status, netcode.Status.Failed)
	testing.expect_value(
		t,
		joiner.detail,
		"the snapshot differed from the other players' and nobody else could send one",
	)
	testing.expect(t, session.relay.seats[3].conn < 0)
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
	net_run(&session, 1, proc(session: ^Net) -> bool {return provider_slot(session.relay, 1) >= 0})
	testing.expect_value(t, provider_slot(session.relay, 1), 0)
	net_run(&session, 0.3)
	netcode.client_stop(first, session.clock.now)
	net_run(&session, 0.02)
	testing.expect(t, session.relay.seats[1].conn < 0)
	second := net_join(&session, -1, .Ideal)
	net_run(&session, 5)
	testing.expectf(t, second.status == .Connected, "the second joiner is %v (%s)", second.status, second.detail)
	testing.expect_value(t, len(session.clients[0].snap_reqs), 0)
}

// A provider's Snap_Begin for a checksum tick, then one for an older tick with that tick's genuine snapshot (a crafted
// client): the relay forwards no snapshot older than the one begun, so it refuses that provider and asks another,
// whose snapshot the joiner loads and plays from. The joiner is behind `wan`: its acks of the ticks streamed from the
// first Snap_Begin reach the relay after the second, and must not move its stream past ticks it lacks.
@(test)
an_older_snapshot_after_a_newer_begin_is_refused :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 2, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 0) // the lowest seat: the one asked for a snapshot
	defer evil_destroy(&evil)
	evil.acking = true
	honest := net_join(&session, 1, .Ideal)
	evil_run(&evil, &session, 1)
	joiner := net_join(&session, -1, .Wan)
	evil_run(&evil, &session, 0.3)
	testing.expect_value(t, provider_slot(session.relay, 2), 0)
	older := (conn_in(session.relay, 2).snap_min + 15) / 16 * 16 // the first checksum tick the joiner may start from
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
	evil_run(&evil, &session, 0.5)
	testing.expectf(
		t,
		joiner.fin_upto >= newer,
		"the joiner holds the stream from %d: fin_upto %d",
		newer,
		joiner.fin_upto,
	)
	evil_snapshot(&evil, &session, 2, older, snapshot)
	evil_run(&evil, &session, 6)
	testing.expect(t, refused_slot(session.relay, 2, 0))
	testing.expectf(
		t,
		joiner.status == .Connected && joiner.snap_tick >= newer && session.relay.finalized - joiner.verified < 64,
		"the joiner is %v (%s): snapshot of %d, verified %d, fin_upto %d; the relay finalized %d, its client_ack %d",
		joiner.status,
		joiner.detail,
		joiner.snap_tick,
		joiner.verified,
		joiner.fin_upto,
		session.relay.finalized,
		conn_in(session.relay, 2).client_ack,
	)
}

// An honest replacement: the first provider (a player whose game dies while it sends a large snapshot) sends its
// Snap_Begin, the joiner is streamed the ticks from it and acks them, then the provider leaves. The next provider
// hitches for ~10 ticks around that moment, so it takes the request and the ticks finalized meanwhile in one poll:
// the first checksum tick it verifies with the request in hand is one the relay already streamed to the joiner,
// whose acks of it are still in flight. The joiner keeps those ticks and plays.
@(test)
a_provider_replaced_mid_transfer_leaves_no_gap :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 3, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 0) // the lowest seat: asked first
	defer evil_destroy(&evil)
	evil.acking = true
	net_join(&session, 1, .Ideal)
	net_join(&session, 2)
	evil_run(&evil, &session, 2, round = 0.001)
	joiner := net_join(&session, 3)
	evil_run(&evil, &session, 0.2, round = 0.001)
	testing.expect_value(t, provider_slot(session.relay, 3), 0)
	first_tick := (conn_in(session.relay, 3).snap_min + 15) / 16 * 16
	for session.relay.finalized < first_tick do evil_run(&evil, &session, 0.001, round = 0.001)
	writer := evil_begin(&evil, .Snap_Begin)
	wire.w_u8(writer, 3)
	wire.w_u32(writer, first_tick)
	wire.w_u32(writer, 2_000_000) // a large world's snapshot, on its way
	evil_send(&evil, &session)
	// ... until just before the next checksum tick; then the second provider hitches across it.
	for session.relay.finalized % 16 != 13 do evil_run(&evil, &session, 0.001, round = 0.001)
	for session.relay.finalized % 16 != 3 do evil_run(&evil, &session, 0.001, round = 0.001, hitched = 0)
	evil.acking = false
	evil_begin(&evil, .Leave)
	evil_send(&evil, &session)
	evil_run(&evil, &session, 0.02, round = 0.001, hitched = 0)
	at_restart := session.relay.finalized
	testing.expect_value(t, provider_slot(session.relay, 3), 1)
	net_run(&session, 6)
	testing.expectf(
		t,
		joiner.status == .Connected && session.relay.finalized - joiner.verified < 64,
		"the joiner is %v (%s): verified %d, fin_upto %d; the relay finalized %d (%d when the first provider left), its client_ack for the joiner %d; the first snapshot was of tick %d, the second is of tick %d",
		joiner.status,
		joiner.detail,
		joiner.verified,
		joiner.fin_upto,
		session.relay.finalized,
		at_restart,
		conn_in(session.relay, 3).client_ack,
		first_tick,
		conn_in(session.relay, 3).snap_tick,
	)
	net_run(&session, 40)
	testing.expectf(t, joiner.status == .Connected, "40 s later the joiner is %v (%s)", joiner.status, joiner.detail)
}

// The honest restart after a failed check (player 0 has diverged; player 1 sends the next snapshot), at join moments
// two ticks apart across a whole checksum period on `wan`: the joiner always plays, and keeps up.
@(test)
a_restarted_snapshot_keeps_up_at_any_phase :: proc(t: ^testing.T) {
	for k in 0 ..< netcode.CHECKSUM_EVERY / 2 {
		session: Net
		defer net_destroy(&session)
		net_make_relay(&session, 3, 0)
		net_join(&session, 0, game = diverging_game())
		net_join(&session, 1)
		net_join(&session, 2)
		net_run(&session, 2 + f64(2 * k) / toy.HZ) // past tick 100, where player 0 parts
		joiner := net_join(&session, 3)
		net_run(&session, 6)
		testing.expectf(
			t,
			joiner.status == .Connected &&
			refused_slot(session.relay, 3, 0) &&
			session.relay.finalized - joiner.verified < 64,
			"phase %d: the joiner is %v (%s): verified %d, fin_upto %d; the relay finalized %d, its client_ack %d, refused %v",
			k,
			joiner.status,
			joiner.detail,
			joiner.verified,
			joiner.fin_upto,
			session.relay.finalized,
			conn_in(session.relay, 3).client_ack,
			conn_in(session.relay, 3).refused,
		)
	}
}

// A session of the provider (a raw channel in seat 0, acking), an honest client in seat 1 and a joiner in seat 2 whose
// snapshot of `tick` (what `game` computes from the relay's finalized inputs) takes `seconds` to arrive: a byte every
// 4 s (progress, so the provider is not replaced as stalled), then the rest. Stands in for a large world on a slow
// path. Returns the joiner and the snapshot's tick; the caller runs on.
slow_join :: proc(
	t: ^testing.T,
	session: ^Net,
	evil: ^Evil,
	game: ^toy.Game,
	seconds: int,
	joiner_link: netcode.Network,
) -> (
	joiner: ^Client,
	tick: u32,
) {
	net_make_relay(session, 2, 0)
	evil_seat(evil, session, 7, 0)
	evil.acking = true
	net_join(session, 1, .Ideal)
	evil_run(evil, session, 3, round = 0.001) // past tick 100, where the diverged build parts
	joiner = net_join(session, -1, joiner_link)
	evil_run(evil, session, 0.3, round = 0.001)
	testing.expect_value(t, provider_slot(session.relay, 2), 0)
	tick = (conn_in(session.relay, 2).snap_min + 15) / 16 * 16
	for session.relay.finalized < tick do evil_run(evil, session, 0.001, round = 0.001)
	simulation := sim.create(game, SEED)
	defer sim.destroy(simulation)
	for number in 1 ..= tick {
		inputs := netcode.relay_tick(session.relay, number)^
		sim.step(simulation, &inputs)
	}
	snapshot := sim.snapshot_encode(simulation, tick)
	defer delete(snapshot)
	writer := evil_begin(evil, .Snap_Begin)
	wire.w_u8(writer, 2)
	wire.w_u32(writer, tick)
	wire.w_u32(writer, u32(len(snapshot)))
	evil_send(evil, session)
	offset := 0
	for _ in 0 ..< seconds / 4 {
		writer = evil_begin(evil, .Snap_Chunk)
		wire.w_u8(writer, 2)
		wire.w_u32(writer, u32(offset))
		wire.w_bytes(writer, snapshot[offset:offset + 1])
		evil_send(evil, session)
		offset += 1
		evil_run(evil, session, 4, round = 0.001)
	}
	for offset < len(snapshot) {
		size := min(netcode.SNAP_CHUNK, len(snapshot) - offset)
		writer = evil_begin(evil, .Snap_Chunk)
		wire.w_u8(writer, 2)
		wire.w_u32(writer, u32(offset))
		wire.w_bytes(writer, snapshot[offset:offset + size])
		evil_send(evil, session)
		offset += size
	}
	return
}

// A genuine snapshot that takes 12, 20 or 60 s to arrive (inside the time FIN_RING gives a large world's snapshot):
// the joiner then verifies up to ~3900 finalized ticks in one client_step, more than 1024 (a checksum ring that
// short would lose some before they are reported), and the relay still compares its checksum with the honest
// player's report of its tick.
@(test)
a_snapshot_that_takes_a_minute_joins :: proc(t: ^testing.T) {
	for seconds in ([]int{12, 20, 60}) {
		session: Net
		evil: Evil
		joiner, tick := slow_join(t, &session, &evil, &toy.GAME, seconds, .Ideal)
		defer net_destroy(&session)
		defer evil_destroy(&evil)
		evil_run(&evil, &session, 4, round = 0.001)
		testing.expectf(
			t,
			joiner.status == .Connected && session.relay.finalized - joiner.verified < 64,
			"%d s: the joiner is %v (%s): its snapshot is of tick %d, it verified %d, the relay finalized %d",
			seconds,
			joiner.status,
			joiner.detail,
			tick,
			joiner.verified,
			session.relay.finalized,
		)
		testing.expect_value(t, session.relay.unchecked_snapshots, 0)
	}
}

// The same 20 s, the provider's snapshot of a diverged state: the honest player's checksum of its tick is still in
// the relay's check ring when the joiner's arrives, so the provider is refused and the honest player asked. (The
// joiner sits behind `wan` so the run can stop at the relay's verdict, before the joiner's catch-up.)
@(test)
a_slow_snapshot_is_still_checked :: proc(t: ^testing.T) {
	session: Net
	evil: Evil
	_, tick := slow_join(t, &session, &evil, diverging_game(), 20, .Wan)
	defer net_destroy(&session)
	defer evil_destroy(&evil)
	evil_run(&evil, &session, 4, round = 0.001, done = proc(session: ^Net) -> bool {
			return session.relay.unchecked_snapshots > 0 || conn_in(session.relay, 2).refused != {}
		})
	testing.expectf(
		t,
		session.relay.unchecked_snapshots == 0 && refused_slot(session.relay, 2, 0),
		"%d snapshot let in unchecked, %d ticks after its tick %d, though slot 1 reported that tick; providers refused: %v",
		session.relay.unchecked_snapshots,
		session.relay.finalized - tick,
		tick,
		conn_in(session.relay, 2).refused,
	)
}

// A provider that sends a genuine snapshot in six pieces 3.5 s apart (never stalling SNAP_STALL_US): the joiner holds
// more than 1024 streamed ticks when it lands, and verifies them all in its first step.
@(test)
a_snapshot_in_slow_pieces_catches_up_past_1024_ticks :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 0)
	defer evil_destroy(&evil)
	evil.acking = true
	evil_run(&evil, &session, 1)
	joiner := net_join(&session, -1, .Ideal)
	evil_run(&evil, &session, 0.1)
	tick := (conn_in(session.relay, 1).snap_min + 15) / 16 * 16
	for session.relay.finalized < tick {
		evil_run(&evil, &session, 0.01)
	}
	simulation := sim.create(&toy.GAME, SEED)
	defer sim.destroy(simulation)
	for number in 1 ..= tick {
		inputs := netcode.relay_tick(session.relay, number)^
		sim.step(simulation, &inputs)
	}
	snapshot := sim.snapshot_encode(simulation, tick)
	defer delete(snapshot)
	writer := evil_begin(&evil, .Snap_Begin)
	wire.w_u8(writer, 1)
	wire.w_u32(writer, tick)
	wire.w_u32(writer, u32(len(snapshot)))
	evil_send(&evil, &session)
	pieces := 6
	piece := (len(snapshot) + pieces - 1) / pieces
	for offset := 0; offset < len(snapshot); offset += piece {
		evil_run(&evil, &session, 3.5)
		writer = evil_begin(&evil, .Snap_Chunk)
		wire.w_u8(writer, 1)
		wire.w_u32(writer, u32(offset))
		wire.w_bytes(writer, snapshot[offset:min(offset + piece, len(snapshot))])
		evil_send(&evil, &session)
	}
	testing.expect(t, joiner.fin_upto > tick + 1024)
	evil_run(&evil, &session, 4)
	testing.expectf(
		t,
		joiner.status == .Connected && joiner.verified > tick + 1024,
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
	testing.expect_value(t, provider_slot(session.relay, 1), 0)
	tick := (conn_in(session.relay, 1).snap_min + 15) / 16 * 16
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

// A joiner leaves and another takes its seat while the only provider's answer to the first (its Snap_Begin) is on
// its way to the relay (the provider is behind `wan`): that answer is older than the new request allows, and is
// dropped, not taken as the provider's answer to it. The provider's answer to the new request follows, and the
// joiner plays.
@(test)
a_rejoin_while_the_providers_answer_is_on_its_way_gets_in :: proc(t: ^testing.T) {
	for k in 0 ..< 8 {
		session: Net
		net_make_relay(&session, 1, 0)
		net_join(&session, 0, .Wan)
		net_run(&session, 2)
		first := net_join(&session, -1, .Ideal)
		net_run(&session, 0.56 + f64(k) * 0.01)
		netcode.client_stop(first, session.clock.now)
		net_run(&session, 0.005)
		second := net_join(&session, -1, .Ideal)
		net_run(&session, 2.5)
		testing.expectf(
			t,
			second.status == .Connected,
			"the first left %d ms after its Hello: the second joiner is %v (%s)",
			560 + 10 * k,
			second.status,
			second.detail,
		)
		net_destroy(&session)
	}
}

// The same with a large world's snapshot (8 MB) still on its way when the seat changes hands: the provider answers
// the new request at once, behind the rest of the old snapshot (reliable, in order, at the reliable pace). Those
// chunks are dropped but are a sign of life, so the provider is not replaced as stalled before its answer comes.
@(test)
a_rejoin_while_a_large_snapshot_is_on_its_way_gets_in :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 0) // stands in for an honest provider: it queues a whole snapshot at once
	defer evil_destroy(&evil)
	evil.acking = true
	evil_run(&evil, &session, 1)
	first := net_join(&session, -1, .Ideal)
	evil_run(&evil, &session, 0.1)
	testing.expect_value(t, provider_slot(session.relay, 1), 0)
	tick := (conn_in(session.relay, 1).snap_min + 15) / 16 * 16
	for session.relay.finalized < tick do evil_run(&evil, &session, 0.01)
	big := make([]u8, 8 << 20)
	defer delete(big)
	evil_snapshot(&evil, &session, 1, tick, big)
	evil_run(&evil, &session, 1)
	netcode.client_stop(first, session.clock.now)
	evil_run(&evil, &session, 0.2)
	testing.expect(t, session.relay.seats[1].conn < 0)
	second := net_join(&session, -1, .Ideal)
	evil_run(&evil, &session, 0.1)
	testing.expect_value(t, provider_slot(session.relay, 1), 0)
	tick = (conn_in(session.relay, 1).snap_min + 15) / 16 * 16
	for session.relay.finalized < tick do evil_run(&evil, &session, 0.01)
	simulation := sim.create(&toy.GAME, SEED)
	defer sim.destroy(simulation)
	for number in 1 ..= tick {
		inputs := netcode.relay_tick(session.relay, number)^
		sim.step(simulation, &inputs)
	}
	snapshot := sim.snapshot_encode(simulation, tick)
	defer delete(snapshot)
	evil_snapshot(&evil, &session, 1, tick, snapshot) // the answer to the new request, behind the old chunks
	evil_run(&evil, &session, 14)
	testing.expectf(
		t,
		second.status == .Connected,
		"the second joiner is %v (%s); providers refused: %v",
		second.status,
		second.detail,
		conn_in(session.relay, 1).refused,
	)
}

// A provider whose answer never comes, only stale chunks (as if of an earlier answer): they keep it asked only while
// the ticks from the joiner's snap_min on are in the relay's ring; then it is replaced as stalled, and with nobody
// else to ask the joiner is refused for want of a snapshot (none failed a check).
@(test)
stale_chunks_keep_a_provider_only_while_the_ring_holds_the_join :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 0)
	defer evil_destroy(&evil)
	evil.acking = true
	evil_run(&evil, &session, 1)
	joiner := net_join(&session, -1, .Ideal)
	evil_run(&evil, &session, 0.1)
	testing.expect_value(t, provider_slot(session.relay, 1), 0)
	snap_min := conn_in(session.relay, 1).snap_min
	chunk := [64]u8{}
	for session.relay.seats[1].conn >= 0 && session.relay.finalized < snap_min + 2 * netcode.RELAY_RING {
		writer := evil_begin(&evil, .Snap_Chunk)
		wire.w_u8(writer, 1)
		wire.w_u32(writer, 0)
		wire.w_bytes(writer, chunk[:])
		evil_send(&evil, &session)
		evil_run(&evil, &session, 1)
		if session.relay.finalized < snap_min + netcode.RELAY_RING - 64 {
			testing.expect_value(t, provider_slot(session.relay, 1), 0)
		}
	}
	evil_run(&evil, &session, 1)
	testing.expect_value(t, joiner.status, netcode.Status.Failed)
	testing.expect_value(t, joiner.detail, "no player can send this player a snapshot")
	testing.expectf(
		t,
		session.relay.finalized - snap_min < netcode.RELAY_RING + u32(f64(netcode.SNAP_STALL_US) / 1e6 + 2) * 64,
		"refused %d ticks past its snap_min",
		session.relay.finalized - snap_min,
	)
}

// Joiners on `bad` links, a second joiner right behind the first, the first provider leaving mid-join in odd rounds:
// every joiner ends Connected, close behind the relay, checked, with no desync.
@(test)
late_joins_on_bad_links_with_a_provider_leaving :: proc(t: ^testing.T) {
	for k in 0 ..< 16 {
		session: Net
		net_make_relay(&session, 2, 0)
		net_join(&session, 0, .Bad)
		net_join(&session, 1, .Wan)
		net_run(&session, 2 + f64(k) * 0.037)
		first := net_join(&session, -1, .Bad)
		net_run(&session, 0.15 + f64(k) * 0.04)
		second := net_join(&session, -1, k % 4 < 2 ? .Bad : .Wan)
		net_run(&session, 0.05 + f64(k % 5) * 0.1)
		if k % 2 == 1 do netcode.client_stop(session.clients[0], session.clock.now)
		net_run(&session, 14)
		for joiner, i in ([]^Client{first, second}) {
			testing.expectf(
				t,
				joiner.status == .Connected && session.relay.finalized - joiner.verified < 64,
				"round %d joiner %d: %v (%s), verified %d of %d, snapshot of %d, first tick %d",
				k,
				i,
				joiner.status,
				joiner.detail,
				joiner.verified,
				session.relay.finalized,
				joiner.snap_tick,
				joiner.first_tick,
			)
		}
		testing.expectf(t, session.relay.desyncs == 0, "round %d: %d desyncs", k, session.relay.desyncs)
		testing.expectf(
			t,
			session.relay.unchecked_snapshots == 0,
			"round %d: %d joiners let in unchecked",
			k,
			session.relay.unchecked_snapshots,
		)
		net_destroy(&session)
	}
}

// One seat joined and left again and again at short intervals (before its snapshot, during it, after Connected),
// then a last joiner that stays and plays.
@(test)
a_seat_joined_and_left_again_and_again :: proc(t: ^testing.T) {
	for k in 0 ..< 8 {
		session: Net
		net_make_relay(&session, 2, 0)
		net_join(&session, 0, .Wan)
		net_join(&session, 1, .Bad)
		net_run(&session, 2)
		for round in 0 ..< 4 {
			joiner := net_join(&session, -1, round % 2 == 0 ? .Wan : .Bad)
			net_run(&session, 0.05 + f64((k * 7 + round * 13) % 23) * 0.04)
			netcode.client_stop(joiner, session.clock.now)
			net_run(&session, 0.02 + f64(k) * 0.03)
		}
		last := net_join(&session, -1, .Wan)
		net_run(&session, 10)
		testing.expectf(
			t,
			last.status == .Connected && session.relay.finalized - last.verified < 64,
			"round %d: %v (%s), verified %d of %d",
			k,
			last.status,
			last.detail,
			last.verified,
			session.relay.finalized,
		)
		testing.expectf(t, session.relay.desyncs == 0, "round %d: %d desyncs", k, session.relay.desyncs)
		net_destroy(&session)
	}
}

// The toy with a tick that reads nothing of the seed (no roll): a sim given another seed computes the same states.
@(private)
GAME_SEEDLESS := toy.Game{}

// Player 0 sends a snapshot of another session: its header's seed differs from the Welcome's, its state (all the
// checksum covers) is honest. The joiner fails it on purpose, the relay asks player 1, and the joiner plays with the
// session's seed.
@(test)
a_snapshot_of_another_seed_is_refused_and_another_player_sends_one :: proc(t: ^testing.T) {
	GAME_SEEDLESS = toy.GAME
	GAME_SEEDLESS.tick = proc(tick: ^toy.Tick) {}
	session: Net
	net_make_relay(&session, 3, 0)
	defer net_destroy(&session)
	for slot in 0 ..< 3 do net_join(&session, slot, game = &GAME_SEEDLESS)
	net_run(&session, 2)
	session.clients[0].sim.seed ~= 0xFF // what its snapshots' headers carry; the checksum doesn't cover it
	joiner := net_join(&session, 3, game = &GAME_SEEDLESS)
	net_run(&session, 1, proc(session: ^Net) -> bool {return provider_slot(session.relay, 3) >= 0})
	testing.expect_value(t, provider_slot(session.relay, 3), 0)
	net_run(&session, 4)
	testing.expect_value(t, session.relay.desyncs, 0) // player 0's states are honest
	testing.expect(t, refused_slot(session.relay, 3, 0))
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect(t, joiner.sim != nil && joiner.sim.seed == SEED, "the joiner plays with the session's seed")
}
