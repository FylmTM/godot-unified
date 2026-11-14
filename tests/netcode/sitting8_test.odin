// L2 netcode tests for what the #8 sitting decided: a joiner's snapshot is checked against the other players'
// checksum before it plays (D11 b), desync reports reach the `desync` hook (D5), a reliable burst is not resent
// though it arrived (D8), a jitter-only profile is simulated (N9).
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
		if tick.number >= 100 do tick.state.score[0] += 1
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
	testing.expect(t, sim.Players{0} <= session.relay.first_desync.diverged)
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
						other.player,
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

// The relay's desync reports reach the `desync` hook, with the tick, who diverged and the detail.
@(test)
desync_report_reaches_the_hook :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	fake: Fake_Relay
	fake_make(&fake, hub)
	defer fake_destroy(&fake)
	Seen :: struct {
		count:    int,
		tick:     u32,
		diverged: sim.Players,
		detail:   [64]u8,
		len:      int,
	}
	seen: Seen
	hooks := Hooks {
		user = &seen,
		desync = proc(user: rawptr, report: netcode.Desync_Report) {
			seen := (^Seen)(user)
			seen.count += 1
			seen.tick, seen.diverged = report.tick, report.diverged
			seen.len = copy(seen.detail[:], report.detail)
		},
	}
	client := netcode.client_create(
		&toy.GAME,
		{player = -1, name = "c", quiet = true},
		netcode.loopback_link(hub, 1),
		hooks,
	)
	defer netcode.client_destroy(client)
	fake_welcome(&fake, client)
	writer := fake_begin(&fake, .Desync)
	wire.w_u32(writer, 4160)
	wire.w_u32(writer, transmute(u32)sim.Players{2})
	detail := "tick 4160: score[2] 3 vs 4"
	wire.w_u16(writer, u16(len(detail)))
	wire.w_bytes(writer, transmute([]u8)detail)
	fake_send(&fake)
	for _ in 0 ..< 4 {
		fake_step(&fake, client)
	}
	testing.expect_value(t, seen.count, 1)
	testing.expect_value(t, seen.tick, 4160)
	testing.expect_value(t, seen.diverged, sim.Players{2})
	testing.expect_value(t, string(seen.detail[:seen.len]), detail)
	testing.expect_value(t, client.desyncs, 1)
	testing.expect(t, !netcode.client_result(client, context.temp_allocator).ok)
}

// A burst of reliable messages longer than one ack covers (a snapshot: 120 datagrams) arrives without a single
// resend on a link that loses nothing: the sender waits for acks instead of resending what arrived (N6, D8).
@(test)
a_reliable_burst_is_not_resent :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	sender := netcode.channel_make()
	defer netcode.channel_destroy(sender)
	receiver := netcode.channel_make()
	defer netcode.channel_destroy(receiver)
	to_receiver := netcode.channel_peer(sender, netcode.channel_add_link(sender, netcode.loopback_link(hub, 0)), 1)
	netcode.channel_add_link(receiver, netcode.loopback_link(hub, 1))
	chunk: [1000]u8
	now: i64 = 1_000_000
	for k in 0 ..< 120 {
		chunk[0] = u8(k)
		netcode.channel_send(sender, to_receiver, chunk[:], .Reliable, now)
	}
	got := 0
	for _ in 0 ..< 2000 {
		now += 500
		netcode.channel_flush(sender, now)
		netcode.channel_poll(sender, now)
		for event in netcode.channel_poll(receiver, now) {
			if event.kind == .Message {
				testing.expect_value(t, event.data[0], u8(got))
				got += 1
			}
		}
		netcode.channel_flush(receiver, now)
		if got == 120 && netcode.channel_idle(sender, to_receiver) {
			break
		}
	}
	testing.expect_value(t, got, 120)
	testing.expect_value(t, sender.stats.resends, 0)
}

// A profile with only jitter impairs the link (it used to come back unwrapped).
@(test)
a_jitter_only_profile_is_simulated :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	inner := netcode.loopback_link(hub, 1)
	data := inner.data
	link := netcode.netsim_wrap(inner, {name = "jitter", jitter = 5_000}, 7)
	defer netcode.link_close(&link)
	testing.expect(t, link.data != data)
	testing.expect(t, netcode.profile_is_ideal({name = "ideal"}))
	testing.expect(t, !netcode.profile_is_ideal({jitter = 1}))
}
