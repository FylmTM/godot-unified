// L2 netcode tests of a client catching up (Client_Config.catchup_ticks): a backlog of finalized ticks is verified a
// budget per client_step, with nothing predicted until it is back within it.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"

// What a catch-up looked like, step by step: the most ticks one client_step verified (from its first verified tick
// on), the predicted ticks stepped while final ticks still waited, the steps it took and how long until the client
// was back at the live tick; the client watched, and its figures after its last step.
Catchup :: struct {
	most_verified:   u32,
	predicted_early: int,
	steps:           int,
	took_us:         i64,
	client:          ^Client,
	verified:        u32,
	predicted:       int,
	until_live:      bool,
}

// Steps the session until remote client `index` is back within a prediction cap of the relay (`until_live`; else
// for all of `seconds`), watching every one of its steps.
catch_up :: proc(session: ^Net, index: int, seconds := 10.0, until_live := true) -> (result: Catchup) {
	client := session.clients[index]
	result = {
		client     = client,
		verified   = client.verified,
		predicted  = client.stats.steps[.Predicted],
		until_live = until_live,
	}
	watch_step :: proc(session: ^Net, user: rawptr) -> bool {
		result := (^Catchup)(user)
		client := result.client
		if result.verified != 0 do result.most_verified = max(result.most_verified, client.verified - result.verified)
		if client.fin_upto > client.verified do result.predicted_early += client.stats.steps[.Predicted] - result.predicted
		if client.verified != result.verified do result.steps += 1
		result.verified, result.predicted = client.verified, client.stats.steps[.Predicted]
		return result.until_live && client.verified + client.tm.prediction_cap >= session.relay.finalized
	}
	start := session.clock.now
	net_run(session, seconds, each = watch_step, user = &result)
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
	net_join(&session, config = Client_Config{slot = -1, player_name = "Linus", catchup_ticks = 3})
	net_run(&session, 2)
	net_run(&session, 3, hitched = 1)
	result := catch_up(&session, 1)
	testing.expectf(t, result.most_verified <= 3, "a step verified %d ticks (budget 3)", result.most_verified)
	testing.expect_value(t, result.predicted_early, 0)
	testing.expectf(t, result.took_us < 1_500_000, "caught up in %d ms", result.took_us / 1000)
	net_run(&session, 1)
	testing.expect(t, session.watch[2].in_order)
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
	most := catch_up(&session, 1, seconds = 6, until_live = false).most_verified
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
		net_make_relay(&session, 2, 0, game = &game)
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
