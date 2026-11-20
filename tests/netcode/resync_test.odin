// L2 netcode tests of the recovery ladder and the re-anchor (Status.Recovering): a client the checksums show as
// diverged, or one the relay's ring no longer reaches, is resynced in place from a majority player's kept snapshot and
// plays on in its seat; one that keeps needing it is dropped.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"
import "unified:wire"

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

// The toy at each tick rate the rate tests run (they outlive their sessions): [k][0] and [k][1] the ladder's plain and
// slipping ones, [k][2] the re-anchor's.
@(private = "file")
RATE_GAMES: [3][3]toy.Game

@(private = "file")
RATES :: [3]int{32, 64, 128}

// A client too slow to verify the session's ticks (stepped every third tick, one tick a step) falls behind until the
// relay's ring no longer reaches it. It is re-anchored in place: a majority player's recent snapshot, the stream from
// its tick, the same seat (one join record), and it plays on at the live tick. At every rate: it is no longer expected
// to report once the ring is past it, so the base is a tick its provider still keeps.
@(test)
a_client_past_the_relays_ring_is_reanchored_in_place :: proc(t: ^testing.T) {
	for tick_hz, index in RATES {
		game := &RATE_GAMES[index][2]
		game^ = toy.GAME
		game.tick_hz = tick_hz
		session: Net
		net_make(&session, 0, 0, game = game)
		defer net_destroy(&session)
		slow := net_join(
			&session,
			game = game,
			config = Client_Config{slot = -1, player_name = "Grace", catchup_ticks = 1},
		)
		net_run(&session, 3)
		testing.expect_value(t, slow.status, netcode.Status.Connected)
		slot := slow.slot
		for slow.stats.resyncs == 0 && !netcode.client_finished(slow) && session.clock.now < 400_000_000 {
			net_run(&session, 3 / f64(tick_hz), hitched = 0) // everyone but the slow client
			netcode.client_step(slow, session.clock.now)
		}
		slow.cfg.catchup_ticks = 0
		net_run(&session, 5)
		testing.expectf(
			t,
			slow.status == .Connected && slow.stats.resyncs == 1 && session.relay.resynced == 1,
			"%d Hz: the slow client ends %v (%s), resyncs %d, relay resynced %d",
			tick_hz,
			slow.status,
			slow.detail,
			slow.stats.resyncs,
			session.relay.resynced,
		)
		testing.expect_value(t, slow.slot, slot)
		testing.expect_value(t, slow.stats.reconnects, 0)
		testing.expect(t, slow.verified + 32 >= session.relay.finalized)
		testing.expect_value(t, session.relay.desyncs, 0)
		testing.expect_value(t, joins_of(&session, slot), 1)
		expect_agree(t, &session)
	}
}

// The ladder at every rate (one of three players diverges at tick 400; every report comes in at once, so the base is
// fresh): resynced once, Connected.
@(test)
a_desync_is_recovered_at_every_rate :: proc(t: ^testing.T) {
	for tick_hz, index in RATES {
		plain, slips := &RATE_GAMES[index][0], &RATE_GAMES[index][1]
		plain^ = toy.GAME
		plain.tick_hz = tick_hz
		slips^ = plain^
		slips.tick = proc(tick: ^toy.Tick) {
			toy.tick(tick)
			if data := toy.in_slot(tick.state, 0); tick.number == 400 && data != nil do data.score += 1
		}
		session: Net
		net_make(&session, 0, 0, game = plain)
		defer net_destroy(&session)
		net_join(&session, game = plain)
		slipped := net_join(&session, game = slips)
		net_run(&session, 400 / f64(tick_hz) + 8)
		testing.expectf(
			t,
			slipped.status == .Connected && slipped.stats.resyncs == 1 && session.relay.resynced == 1,
			"%d Hz: the slipped client ends %v (%s), resyncs %d, relay resynced %d",
			tick_hz,
			slipped.status,
			slipped.detail,
			slipped.stats.resyncs,
			session.relay.resynced,
		)
	}
}

// A command on every tick (the toy's script sends one tick in sixteen): a player who keeps issuing them.
@(private = "file")
send_every_tick :: proc(client: ^Client) {
	client.hooks.commands = proc(
		user: rawptr,
		local, slot: int,
		tick: u32,
		state: ^toy.State,
		out: ^sim.Command_Out(toy.Command),
	) {
		sim.send_command(out, toy.Command_Bump{i32(tick)})
	}
}

// How many commands of `slot` the relay's recording carries in ticks first..upto.
@(private = "file")
carried_commands :: proc(session: ^Net, slot: int, first, upto: u32) -> (count: int) {
	recording := net_log(session)
	for k in 0 ..< len(recording.ticks) {
		tick := u32(k + 1)
		if tick < first || tick > upto do continue
		inputs := sim.log_inputs(recording, k)
		count += len(sim.slot_commands(&inputs, slot))
	}
	return
}

// The invariant drop_verified_commands keeps on every client: own_cmds holds exactly the own commands no verified tick
// carries yet, so (seqs given) - (commands held) == (own commands in the ticks verified so far). A resync restores a
// tick behind the client's verified tick and the ticks after it are verified a second time: the commands they carry
// left own_cmds the first time, so they take none of the newer ones with them.
@(test)
a_resynced_client_keeps_the_own_commands_no_verified_tick_carries :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 1)
	defer net_destroy(&session)
	slipped := net_join(&session, game = slipping_game())
	other := session.clients[0]
	send_every_tick(slipped)
	send_every_tick(other)
	worst, worst_other := 0, 0
	first_bad_tick: u32
	for _ in 0 ..< 48 {
		net_run(&session, 0.25)
		for client in ([]^Client{slipped, other}) {
			if client.status != .Connected || client.sim == nil || client.checking do continue
			seat := &client.locals[0]
			carried := carried_commands(&session, client.slot, seat.first_tick, client.verified)
			off := int(seat.cmd_seq) - len(seat.own_cmds) - carried
			if client == slipped {
				if off != 0 && first_bad_tick == 0 do first_bad_tick = client.verified
				worst = max(worst, abs(off))
			} else {
				worst_other = max(worst_other, abs(off))
			}
		}
	}
	testing.expect_value(t, slipped.stats.resyncs, 1)
	testing.expect_value(t, worst_other, 0)
	testing.expectf(
		t,
		worst == 0,
		"the resynced client dropped %d own commands no verified tick carried (first at its verified tick %d); it holds %d of %d given",
		worst,
		first_bad_tick,
		len(slipped.locals[0].own_cmds),
		slipped.locals[0].cmd_seq,
	)
}

// The same on a lossy link: a command dropped from own_cmds before the relay acked it would never be sent again, the
// relay would wait for its seq for good (it never takes a gap), and every later command of that player would be lost.
@(test)
a_resync_on_a_lossy_link_loses_no_command :: proc(t: ^testing.T) {
	lost_sessions := 0
	for run in 0 ..< 6 {
		session: Net
		net_make(&session, 0, 1)
		slipped := net_join(&session, profile = .Bad, game = slipping_game())
		send_every_tick(slipped)
		net_run(&session, 4 + f64(run) * 0.37)
		net_run(&session, 30)
		testing.expectf(t, slipped.status == .Connected, "run %d: %v (%s)", run, slipped.status, slipped.detail)
		if slipped.status == .Connected && slipped.stats.resyncs >= 1 {
			seat := &slipped.locals[0]
			logged := carried_commands(&session, slipped.slot, seat.first_tick, session.relay.finalized)
			// one command per tick from its first tick on: all but the last seconds' are in the recording (a dead
			// stream fills own_cmds, send_command fails from then on and cmd_seq stops)
			if int(session.relay.finalized - seat.first_tick) - logged > 256 {
				lost_sessions += 1
				testing.expectf(
					t,
					false,
					"run %d: %d of %d given commands in the recording, the relay has seq %d",
					run,
					logged,
					seat.cmd_seq,
					session.relay.seats[slipped.slot].cmd_recv,
				)
			}
		}
		net_destroy(&session)
	}
	testing.expect_value(t, lost_sessions, 0)
}

// Three players on a plain relay (no typed reports: a shipped game's). The slipping client hitches just before its
// first diverged checksum tick; the others' checks of the ticks meanwhile are judged without it. Back, it acks the
// backlog at once and reports the diverged tick late. It waits to be resynced until it has reported a tick a provider
// keeps, at or after the one it diverged on (an older base would replay the fault): resynced once, whatever the hitch.
@(test)
a_desync_seen_after_a_hitch_is_resynced :: proc(t: ^testing.T) {
	for hitch in ([]f64{1.5, 2, 3, 4, 5}) {
		for catchup in ([]u32{0, 8}) {
			session: Net
			net_make_relay(&session, 3, 0)
			net_join(&session, 0)
			net_join(&session, 1)
			slipped := net_join(&session, 2, game = slipping_game())
			slipped.cfg.catchup_ticks = catchup
			net_run(&session, 30, proc(session: ^Net) -> bool {return session.clients[2].verified >= 96})
			before := slipped.verified
			net_run(&session, hitch, hitched = 2)
			net_run(&session, 10)
			testing.expectf(
				t,
				before < 112 &&
				session.relay.desyncs >= 1 &&
				slipped.status == .Connected &&
				slipped.stats.resyncs == 1,
				"hitch %.1f s, catch-up %d: verified %d before, %d desyncs, %v (%s), %d resyncs",
				hitch,
				catchup,
				before,
				session.relay.desyncs,
				slipped.status,
				slipped.detail,
				slipped.stats.resyncs,
			)
			net_destroy(&session)
		}
	}
}

// A remote client in `slot` behind a gate (a plain relay's start player).
@(private = "file")
gated_slot :: proc(session: ^Net, slot: int, game: ^toy.Game = nil) -> (^Client, ^Gate) {
	inner, _ := net_link(session)
	link, gate := gate_wrap(inner)
	return net_join(session, slot, game = game, name = "Gated", link = link), gate
}

// Plain relay with typed reports. The slipping client freezes for 4 s right after its desync is judged: the typed
// report waits for its image, then the resync looks for a base. A tick the frozen target never acked would be one it
// can still report from its old state: waking while the snapshot is on its way (the provider's link stalls a second)
// and reporting it, that report would be taken as the checksum of what it restored, and it dropped as Desynced. A
// diverged target's base is a tick it reported: it waits, frozen, and is resynced once it reports again.
@(test)
an_old_report_of_the_base_is_not_the_restore :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 3, 0, desync_detail = true)
	defer net_destroy(&session)
	_, provider_gate := gated_slot(&session, 0)
	net_join(&session, 1)
	slipped := net_join(&session, 2, game = slipping_game())
	net_run(&session, 10, proc(session: ^Net) -> bool {return session.relay.desyncs >= 1})
	testing.expect(t, session.relay.desyncs >= 1)
	net_run(&session, 4, hitched = 2)
	testing.expect(t, !session.relay.resync.on, "no base before the frozen target reports one")
	provider_gate.block_out = true // the base's snapshot is slow to come
	net_run(&session, 1)
	held := conn_in(session.relay, 2)
	testing.expectf(
		t,
		!(held.snap_have && slipped.stats.resyncs == 0),
		"the relay holds a restore checksum (%x) of tick %d before the target was sent anything to restore",
		held.snap_value,
		held.snap_tick,
	)
	provider_gate.block_out = false
	net_run(&session, 6)
	testing.expectf(t, slipped.status == .Connected, "%v (%s)", slipped.status, slipped.detail)
	testing.expect_value(t, slipped.stats.resyncs, 1)
	testing.expect_value(t, session.relay.resynced, 1)
}

// A resync whose provider leaves mid-fetch asks another majority player that keeps a tick the target can take, as a
// joiner's snapshot does (restart_snapshot): the target is resynced, not dropped.
@(test)
a_resync_whose_provider_leaves_asks_another :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 3, 0)
	defer net_destroy(&session)
	provider := net_join(&session, 0)
	net_join(&session, 1)
	slipped := net_join(&session, 2, game = slipping_game())
	net_run(&session, 10, proc(session: ^Net) -> bool {return session.relay.resync.on})
	testing.expect(t, session.relay.resync.on, "a resync started")
	testing.expect_value(t, session.relay.resync.from, session.relay.seats[0].conn)
	netcode.client_stop(provider, session.clock.now)
	net_run(&session, 6)
	testing.expectf(t, slipped.status == .Connected, "%v (%s)", slipped.status, slipped.detail)
	testing.expect_value(t, slipped.stats.resyncs, 1)
}

// A provider that sends the resync's snapshot a byte every 2 s (each one progress, under IMAGE_WAIT_MS) holds the
// fetch IMAGE_GIVE_UP_MS at most: then it fails whatever its progress, so it blocks no later resync, and its target is
// dropped (its own give-up has passed) instead of left frozen in its seat. The provider is a raw channel in slot 0
// that reports the honest checksums (copied from slot 1's client), so it is the majority player asked first.
@(test)
a_trickling_resync_snapshot_is_given_up :: proc(t: ^testing.T) {
	session: Net
	evil: Evil
	net_make_relay(&session, 3, 0)
	defer net_destroy(&session)
	defer evil_destroy(&evil)
	evil_seat(&evil, &session, 7, 0)
	evil.acking = true
	honest := net_join(&session, 1)
	slipped := net_join(&session, 2, game = slipping_game())
	sent_upto: u32
	request: []u8
	for _ in 0 ..< 1000 {
		// report every checksum tick the honest client verified, with its value
		for tick := sent_upto + netcode.CHECKSUM_EVERY; tick <= honest.verified; tick += netcode.CHECKSUM_EVERY {
			entry := honest.chk[(tick / netcode.CHECKSUM_EVERY) % netcode.CHK_RING]
			if entry.tick != tick do continue
			writer := evil_begin(&evil, .Checksum)
			wire.w_u32(writer, tick)
			wire.w_u64(writer, entry.value)
			evil_send(&evil, &session)
			sent_upto = tick
		}
		request = evil_run(&evil, &session, 0.02, .Snap_Request)
		if request != nil do break
	}
	if !testing.expect(t, request != nil && session.relay.resync.on, "the raw provider was asked for a snapshot") do return
	asked_us := session.clock.now
	reader := wire.reader_make(request[1:])
	testing.expect_value(t, wire.r_u8(&reader), netcode.RELAY_TARGET)
	tick := wire.r_u32(&reader)
	writer := evil_begin(&evil, .Snap_Begin)
	wire.w_u8(writer, netcode.RELAY_TARGET)
	wire.w_u32(writer, tick)
	wire.w_u32(writer, 1 << 20)
	evil_send(&evil, &session)
	for offset := u32(0); session.relay.resync.on && session.clock.now - asked_us < 40_000_000; offset += 1 {
		writer = evil_begin(&evil, .Snap_Chunk)
		wire.w_u8(writer, netcode.RELAY_TARGET)
		wire.w_u32(writer, offset)
		wire.w_u8(writer, 0)
		evil_send(&evil, &session)
		evil_run(&evil, &session, 2, round = 0.05)
	}
	given_up_ms := (session.clock.now - asked_us) / 1000
	testing.expectf(
		t,
		!session.relay.resync.on && given_up_ms <= netcode.IMAGE_GIVE_UP_MS + 2500,
		"the fetch is still on %d ms after it was asked",
		given_up_ms,
	)
	evil_run(&evil, &session, 1, round = 0.05)
	testing.expectf(t, slipped.status == .Disconnected, "the target is %v (%s)", slipped.status, slipped.detail)
}

// The slow-fetch test's games (128 Hz): plain, and slipping at tick 200.
@(private = "file")
SLOW_FETCH_GAMES: [2]toy.Game

// At 128 Hz Seat.placed's ring (PLACED_RING ticks) spans 2 s: a resync snapshot from a remote provider whose link
// stalls 2.2 s (under IMAGE_WAIT_MS) comes after a newer tick wrote over the base's ring slot. The placed seqs the
// target is told were copied when the base was chosen: it keeps exactly the own commands no verified tick carries.
@(test)
a_slow_resync_snapshot_tells_the_commands_of_its_base :: proc(t: ^testing.T) {
	plain, slips := &SLOW_FETCH_GAMES[0], &SLOW_FETCH_GAMES[1]
	plain^ = toy.GAME
	plain.tick_hz = 128
	slips^ = plain^
	slips.tick = proc(tick: ^toy.Tick) {
		toy.tick(tick)
		if data := toy.in_slot(tick.state, 0); tick.number == 200 && data != nil do data.score += 1
	}
	session: Net
	net_make_relay(&session, 3, 0, record = true, game = plain)
	defer net_destroy(&session)
	_, provider_gate := gated_slot(&session, 0, plain)
	net_join(&session, 1, game = plain)
	slipped := net_join(&session, 2, game = slips)
	send_every_tick(slipped)
	net_run(&session, 20, proc(session: ^Net) -> bool {return session.relay.resync.on})
	if !testing.expect(t, session.relay.resync.on, "a resync started") do return
	testing.expect_value(t, session.relay.resync.from, session.relay.seats[0].conn)
	provider_gate.block_out = true
	net_run(&session, 2.2)
	provider_gate.block_out = false
	net_run(&session, 4)
	testing.expectf(
		t,
		slipped.status == .Connected && slipped.stats.resyncs == 1,
		"%v (%s), resyncs %d",
		slipped.status,
		slipped.detail,
		slipped.stats.resyncs,
	)
	seat := &slipped.locals[0]
	carried := carried_commands(&session, slipped.slot, seat.first_tick, slipped.verified)
	testing.expectf(
		t,
		int(seat.cmd_seq) - len(seat.own_cmds) == carried,
		"%d given, %d held, %d in the verified ticks",
		seat.cmd_seq,
		len(seat.own_cmds),
		carried,
	)
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
