// The relay and the client against peers that only look busy, forge their source, share one identity or send what
// does not restore: each is bounded, and the honest players get in.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:wire"

// A snapshot provider that answers and then only looks busy is replaced by another player: one that sends empty
// chunks or begins its answer again is as silent (SNAP_STALL_US), one that trickles bytes holds the joiner until its
// snapshot's deadline at most.
@(test)
a_provider_that_only_looks_busy_is_replaced :: proc(t: ^testing.T) {
	Busy :: enum {
		Empty_Chunks,
		Begins_Again,
		Trickles,
	}
	for busy in Busy {
		session: Net
		net_make_relay(&session, 2, 0)
		defer net_destroy(&session)
		evil: Evil
		evil_seat(&evil, &session, 7, 0) // the lowest seat: the first one asked for a snapshot
		defer evil_destroy(&evil)
		evil.acking = true
		net_join(&session, 1)
		evil_run(&evil, &session, 1)
		joiner := net_join(&session)
		evil_run(&evil, &session, 0.1)
		testing.expect_value(t, provider_slot(session.relay, 2), 0)
		tick := (conn_in(session.relay, 2).snap_min + 15) / 16 * 16
		for session.relay.finalized < tick do evil_run(&evil, &session, 0.01)
		seconds := busy == .Trickles ? netcode.IMAGE_GIVE_UP_MS / 1000 + 4 : int(netcode.SNAP_STALL_US / 1_000_000) + 3
		for k in 0 ..= seconds {
			if k == 0 || busy == .Begins_Again {
				writer := evil_begin(&evil, .Snap_Begin)
				wire.w_u8(writer, 2)
				wire.w_u32(writer, tick)
				wire.w_u32(writer, 1000)
			} else {
				writer := evil_begin(&evil, .Snap_Chunk)
				wire.w_u8(writer, 2)
				wire.w_u32(writer, busy == .Trickles ? u32(k - 1) : 0)
				if busy == .Trickles do wire.w_u8(writer, 0x55) // a byte a second: progress, slowly
			}
			evil_send(&evil, &session)
			evil_run(&evil, &session, 1)
			if refused_slot(session.relay, 2, 0) do break
		}
		testing.expectf(t, refused_slot(session.relay, 2, 0), "%v: the provider is still asked", busy)
		evil_run(&evil, &session, 3)
		testing.expectf(
			t,
			joiner.status == .Connected,
			"%v: the joiner is %v (%s)",
			busy,
			joiner.status,
			joiner.detail,
		)
	}
}

// A Join past the member cap (a member id is a u16) is refused for that local player alone: no member id wraps.
@(test)
a_join_past_the_member_cap_is_refused :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client := net_join(&session, profile = .Ideal)
	net_run(&session, 1)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	resize(&session.relay.members, int(max(u16))) // as many people as a session can tell apart
	testing.expect(t, netcode.client_add_player(client, 1, {player_name = "Second"}))
	net_run(&session, 1)
	testing.expect_value(t, netcode.client_local(client, 1).state, netcode.Local_State.None)
	testing.expect_value(t, len(session.relay.members), int(max(u16)))
	testing.expect_value(t, client.status, netcode.Status.Connected)
}

// Datagrams from 40 forged sources (more than the relay has connections) hold no connection for long, and each
// source is sent a few datagrams at most, not keepalives: an honest client gets in within 3 s.
@(test)
forged_sources_hold_no_connection_for_long :: proc(t: ^testing.T) {
	FORGED :: 40
	hub := netcode.hub_create(FORGED + 2)
	defer netcode.hub_destroy(hub)
	relay := netcode.relay_create(&toy.GAME, {seed = SEED, start_players = 1})
	defer netcode.relay_destroy(relay)
	netcode.relay_add_link(relay, netcode.loopback_link(hub, 0))
	forged: [FORGED]netcode.Link
	header := wire.writer_make(netcode.HEADER_BYTES)
	defer delete(header.buf)
	for &link, i in forged {
		link = netcode.loopback_link(hub, netcode.Peer(i + 1))
		clear(&header.buf)
		wire.w_u8(&header, netcode.DGRAM_TAG)
		wire.w_u32(&header, netcode.EPOCH_BIT | u32(i + 1)) // its epoch
		wire.w_u32(&header, 0) // opened: no epoch of ours echoed
		wire.w_u32(&header, 1) // seq
		wire.w_u32(&header, 0) // ack
		wire.w_u32(&header, 0) // ack bits
		wire.w_u8(&header, 0)
		wire.w_u16(&header, max(u16)) // no round-trip sample
		wire.w_u8(&header, 0) // no chunks
		netcode.link_send(&link, 0, header.buf[:])
	}
	defer for &link in forged do netcode.link_close(&link)
	watch: Watch
	defer delete(watch.statuses)
	now: i64 = 1_000_000
	netcode.relay_step(relay, now) // every peer number taken
	client := netcode.client_create(&toy.GAME, {}, netcode.loopback_link(hub, FORGED + 1), hooks_for(&watch))
	defer netcode.client_destroy(client)
	start := now
	for now - start < 3_000_000 && client.status != .Connected {
		now += 1000
		netcode.relay_step(relay, now)
		netcode.client_step(client, now)
	}
	testing.expectf(t, client.status == .Connected, "the honest client is %v after 3 s", client.status)
	for _ in 0 ..< 10_000 { 	// 10 s more: what a forged source is sent in all
		now += 1000
		netcode.relay_step(relay, now)
		netcode.client_step(client, now)
	}
	for i in 1 ..= FORGED {
		testing.expectf(
			t,
			netcode.hub_queued(hub, netcode.Peer(i)) <= 4,
			"source %d was sent %d",
			i,
			netcode.hub_queued(hub, netcode.Peer(i)),
		)
	}
}

// One identity in two programs at once (one token copied to another machine): the newer program's Hello replaces the
// older's connection, and the older one's resuming Hello is refused while the newer is live, so they do not replace
// each other without end: the older ends Failed, saying why.
@(test)
one_identity_in_two_programs_ends_the_older :: proc(t: ^testing.T) {
	TOKEN :: netcode.Token {
		0 = 1,
		1 = 2,
		2 = 3,
	}
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	older := net_join(&session, profile = .Ideal, token = TOKEN)
	net_run(&session, 2)
	testing.expect_value(t, older.status, netcode.Status.Connected)
	newer := net_join(&session, profile = .Ideal, token = TOKEN)
	net_run(&session, 3)
	testing.expect_value(t, older.status, netcode.Status.Failed)
	testing.expect_value(t, older.detail, "this player is in the session on a newer connection")
	testing.expectf(t, older.stats.reconnects <= 1, "the older reconnected %d times", older.stats.reconnects)
	testing.expect_value(t, newer.status, netcode.Status.Connected)
	testing.expect_value(t, newer.stats.reconnects, 0)
}

// A late report of a checksum tick nobody voted on is its first vote, never judged against a majority of nothing: one
// connection waiting for a resync reports first (no vote), the only voter reports more than CHECK_WAIT_MS later, and
// their states agree. Nobody is reported diverged.
@(test)
a_late_report_of_an_unvoted_tick_is_its_first_vote :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 2, 0)
	defer net_destroy(&session)
	waiting := net_join(&session, 0, .Ideal)
	voter := net_join(&session, 1, .Ideal)
	net_run(&session, 3)
	// By fiat: slot 0 waits for a resync with no usable base yet (its state is in fact the session's).
	peer := session.relay.seats[0].conn
	session.relay.resync_wanted += {int(peer)}
	session.relay.conns[peer].resync_since = session.clock.now
	session.relay.conns[peer].resync_diverged = true
	session.relay.conns[peer].resync_floor = max(u32) - 64
	net_run(&session, 2, hitched = 1) // the voter hitches 2 s
	net_run(&session, 3)
	testing.expect_value(t, session.relay.desyncs, 0)
	testing.expect_value(t, voter.status, netcode.Status.Connected)
	testing.expect_value(t, voter.stats.desyncs, 0)
	testing.expect_value(t, waiting.stats.desyncs, 0)
}

// A snapshot that does not restore (a crafted provider's) is refused like one that differs: the joiner asks for
// another and plays from an honest player's; with nobody else to send one, the relay takes it unchecked and the joiner
// fails, saying why.
@(test)
a_snapshot_that_does_not_restore_asks_another_player :: proc(t: ^testing.T) {
	planted: Planted // the fault this test plants warns by design: counted here, not printed
	context.logger = planted_logger(&planted)
	for alone in ([]bool{false, true}) {
		session: Net
		net_make_relay(&session, alone ? 1 : 2, 0)
		defer net_destroy(&session)
		evil: Evil
		evil_seat(&evil, &session, 7, 0) // the lowest seat: the first one asked for a snapshot
		defer evil_destroy(&evil)
		evil.acking = true
		if !alone do net_join(&session, 1)
		evil_run(&evil, &session, 1)
		joiner := net_join(&session)
		evil_run(&evil, &session, 0.1)
		target := u8(alone ? 1 : 2)
		testing.expect_value(t, provider_slot(session.relay, int(target)), 0)
		tick := (conn_in(session.relay, int(target)).snap_min + 15) / 16 * 16
		for session.relay.finalized < tick do evil_run(&evil, &session, 0.01)
		garbage: [100]u8
		for &b in garbage do b = 0x55
		evil_snapshot(&evil, &session, target, tick, garbage[:])
		evil_run(&evil, &session, 4)
		if alone {
			testing.expect_value(t, joiner.status, netcode.Status.Failed)
			testing.expect_value(t, joiner.detail, "received snapshot does not restore: Bad_Header")
		} else {
			testing.expect(t, refused_slot(session.relay, 2, 0))
			testing.expectf(t, joiner.status == .Connected, "the joiner is %v (%s)", joiner.status, joiner.detail)
		}
	}
	testing.expectf(t, planted.warnings > 0, "the planted fault warned of nothing")
}

// The game's sample and commands hooks never get a state no peer vouched for: while a joiner's restored snapshot (or a
// resync's) waits for the relay's check, they get nil, as before the sim exists.
@(test)
the_hooks_never_read_an_unchecked_state :: proc(t: ^testing.T) {
	Probe :: struct {
		using watch:    Watch, // hooks_for's hooks read it through the same pointer
		client:         ^Client,
		unchecked:      int, // samples handed a state while it waited for the check
		nil_beside_sim: int, // samples handed nil while the sim was there (the check pending)
	}
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	probe: Probe
	defer delete(probe.statuses)
	hooks := hooks_for(&probe.watch)
	hooks.user = &probe
	hooks.sample = proc(user: rawptr, local, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
		probe := (^Probe)(user)
		if state != nil && probe.client.checking do probe.unchecked += 1
		if state == nil && probe.client.sim != nil do probe.nil_beside_sim += 1
		return toy.scripted_input(SEED, slot, tick)
	}
	net_run(&session, 1)
	probe.client = net_join(&session, profile = .Wan, hooks = hooks)
	net_run(&session, 4)
	testing.expect_value(t, probe.client.status, netcode.Status.Connected)
	testing.expect_value(t, probe.unchecked, 0)
	testing.expectf(t, probe.nil_beside_sim > 0, "the joiner sampled nothing while its snapshot was checked")
}
