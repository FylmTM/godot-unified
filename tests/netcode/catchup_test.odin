// L2 netcode tests of a client catching up (Client_Config.catchup_ticks): a backlog of finalized ticks is verified a
// budget per client_step, with nothing predicted until it is back within it.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"

// What a catch-up looked like, step by step: the most ticks one client_step verified, the predicted ticks stepped
// while final ticks still waited, the steps it took and how long until the client was back at the live tick.
Catchup :: struct {
	most_verified:   u32,
	predicted_early: int,
	steps:           int,
	took_us:         i64,
}

// Steps the session until remote client `index` is back within a prediction cap of the relay, watching every one
// of its steps.
catch_up :: proc(session: ^Net, index: int) -> (result: Catchup) {
	client := session.clients[index]
	start := session.clock.now
	end := start + 10_000_000
	for session.clock.now < end && client.verified + client.tm.prediction_cap < session.relay.finalized {
		now := session.clock.now
		wake := session.host != nil ? netcode.host_step(session.host, now) : netcode.relay_step(session.relay, now)
		for other, i in session.clients {
			if i != index {
				wake = min(wake, netcode.client_step(other, now))
				continue
			}
			verified, predicted := client.verified, client.stats.steps[.Predicted]
			wake = min(wake, netcode.client_step(client, now))
			result.most_verified = max(result.most_verified, client.verified - verified)
			if client.fin_upto > client.verified do result.predicted_early += client.stats.steps[.Predicted] - predicted
			if client.verified != verified do result.steps += 1
		}
		session.clock.now = clamp(wake, now + 1, end)
	}
	result.took_us = session.clock.now - start
	return
}

// A remote client whose process hitched for 5 s (its socket kept what arrived) holds 320 finalized ticks it has not
// verified. It verifies at most the prediction cap per client_step, predicts nothing until it is back within it, and
// is at the live tick within 1.5 s; the checksums agree.
@(test)
a_hitched_client_catches_up_a_budget_per_step :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 2)
	defer net_destroy(&session)
	net_run(&session, 2)
	net_run(&session, 5, hitched = 0)
	client := session.clients[0]
	testing.expect(t, session.relay.finalized > client.verified + 300)
	result := catch_up(&session, 0)
	testing.expectf(
		t,
		result.most_verified <= client.tm.prediction_cap,
		"a step verified %d ticks (budget %d)",
		result.most_verified,
		client.tm.prediction_cap,
	)
	testing.expect_value(t, result.predicted_early, 0)
	testing.expectf(t, result.steps >= 15, "%d steps", result.steps)
	testing.expectf(t, result.took_us < 1_500_000, "caught up in %d ms", result.took_us / 1000)
	net_run(&session, 1)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	expect_agree(t, &session)
}

// A smaller budget (Client_Config.catchup_ticks) holds too, below the cap: a rollback while catching up stops at the
// budget instead of predicting the final ticks again.
@(test)
a_catchup_budget_below_the_cap_holds :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 1)
	defer net_destroy(&session)
	endpoint := len(session.clients) + 1
	link := netcode.netsim_wrap(
		netcode.loopback_link(session.hub, netcode.Peer(endpoint)),
		netcode.PROFILES[.Wan],
		u32(endpoint) * 7919,
		&session.clock,
	)
	client := netcode.client_create(
		&toy.GAME,
		{slot = -1, player_name = "Linus", catchup_ticks = 3},
		link,
		hooks_for(&session.watch[endpoint]),
	)
	append(&session.clients, client)
	net_run(&session, 2)
	net_run(&session, 3, hitched = 1)
	result := catch_up(&session, 1)
	testing.expectf(t, result.most_verified <= 3, "a step verified %d ticks (budget 3)", result.most_verified)
	testing.expect_value(t, result.predicted_early, 0)
	testing.expectf(t, result.took_us < 1_500_000, "caught up in %d ms", result.took_us / 1000)
	net_run(&session, 1)
	testing.expect(t, session.watch[endpoint].in_order)
	expect_agree(t, &session)
}

// A late joiner's backlog (the finalized ticks from its snapshot's on, streamed while its snapshot travels) is
// verified the same way after its check: no step verifies more than the cap.
@(test)
a_late_joiners_backlog_is_verified_a_budget_per_step :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 1)
	defer net_destroy(&session)
	net_run(&session, 2)
	joiner := net_join(&session, -1, .Bad)
	most: u32
	end := session.clock.now + 6_000_000
	for session.clock.now < end {
		now := session.clock.now
		wake := netcode.host_step(session.host, now)
		for client in session.clients {
			verified := client.verified
			wake = min(wake, netcode.client_step(client, now))
			if client == joiner && verified != 0 do most = max(most, client.verified - verified)
		}
		session.clock.now = clamp(wake, now + 1, end)
	}
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expectf(t, most <= joiner.tm.prediction_cap, "a step verified %d ticks", most)
	testing.expect(t, joiner.verified + joiner.tm.prediction_cap >= session.relay.finalized)
	expect_agree(t, &session)
}

// The budget is the prediction cap at every tick rate (8 ticks at 32 Hz, the ring's floor; 30 at 128 Hz).
@(test)
the_catchup_budget_follows_the_tick_rate :: proc(t: ^testing.T) {
	for tick_hz in ([]int{32, 128}) {
		game := toy.GAME
		game.tick_hz = tick_hz
		session: Net
		session.clock.now = 1_000_000
		session.hub = netcode.hub_create(8)
		session.relay = netcode.relay_create(&game, {seed = SEED, start_players = 2})
		netcode.relay_add_link(session.relay, netcode.loopback_link(session.hub, 0))
		net_join(&session, 0, .Wan, &game)
		client := net_join(&session, 1, .Wan, &game)
		net_run(&session, 2)
		net_run(&session, 4, hitched = 1)
		result := catch_up(&session, 1)
		testing.expectf(
			t,
			result.most_verified <= client.tm.prediction_cap && result.predicted_early == 0,
			"%d Hz: a step verified %d ticks (cap %d), %d predicted early",
			tick_hz,
			result.most_verified,
			client.tm.prediction_cap,
			result.predicted_early,
		)
		testing.expectf(t, result.took_us < 1_500_000, "%d Hz: caught up in %d ms", tick_hz, result.took_us / 1000)
		net_run(&session, 1)
		expect_agree(t, &session)
		net_destroy(&session)
	}
}
