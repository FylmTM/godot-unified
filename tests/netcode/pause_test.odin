// The single-player pause (netcode.host_set_paused): exact because nobody else waits.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

PAUSE_TICKS :: 400

// Steps a host on a virtual clock for `seconds`, or until its session is over.
pause_run :: proc(host: ^Host, clock: ^netcode.Virtual_Clock, seconds: i64) {
	end := clock.now + seconds * 1_000_000
	for clock.now < end && !netcode.host_finished(host) {
		wake := netcode.host_step(host, clock.now)
		clock.now = max(wake, clock.now + 1)
	}
}

// A paused single-player session resumes byte-identical to one never paused: two hosts with the same scripted
// inputs, one paused for 3 s in the middle (its tick standing still throughout), record the same input log and verify
// every tick with no rollback and no catch-up burst.
@(test)
a_paused_single_player_session_resumes_byte_identical :: proc(t: ^testing.T) {
	recordings: [2][dynamic]u8
	defer for &recording in recordings do delete(recording)
	watches: [2]Watch
	defer for &watch in watches do delete(watch.statuses)
	for &recording, i in recordings {
		host := netcode.host_create(
			&toy.GAME,
			{seed = SEED, ticks = PAUSE_TICKS, recording = sim.log_sink_memory(&recording)},
			hooks_for(&watches[i]),
		)
		defer netcode.host_destroy(host)
		clock := netcode.Virtual_Clock {
			now = 1_000_000,
		}
		pause_run(host, &clock, 3)
		if i == 1 {
			testing.expect(t, netcode.host_set_paused(host, true, clock.now))
			paused_at := host.client.verified
			session_time := netcode.host_session_time(host, clock.now)
			pause_run(host, &clock, 3)
			testing.expect_value(t, host.client.verified, paused_at)
			testing.expect_value(t, netcode.host_session_time(host, clock.now), session_time)
			testing.expect(t, !netcode.host_set_paused(host, false, clock.now))
			resumed_at := host.client.verified
			netcode.host_step(host, clock.now)
			testing.expectf(
				t,
				host.client.verified - resumed_at <= 1,
				"a catch-up burst on resume: %d ticks",
				host.client.verified - resumed_at,
			)
		}
		pause_run(host, &clock, 30)
		testing.expect(t, netcode.host_finished(host), "the session ran to its end")
		testing.expect_value(t, host.client.verified, PAUSE_TICKS)
		testing.expect_value(t, host.client.stats.rollbacks, 0)
		testing.expect_value(t, host.client.stats.stall_ticks, 0)
	}
	testing.expect(
		t,
		len(recordings[0]) > 0 && string(recordings[0][:]) == string(recordings[1][:]),
		"the logs differ",
	)
}

// The pause is single player only: refused once a remote link is added, and a link added while paused resumes it.
@(test)
the_single_player_pause_ends_with_a_remote_link :: proc(t: ^testing.T) {
	watch: Watch
	defer delete(watch.statuses)
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	host := netcode.host_create(&toy.GAME, {seed = SEED}, hooks_for(&watch))
	defer netcode.host_destroy(host)
	clock := netcode.Virtual_Clock {
		now = 1_000_000,
	}
	pause_run(host, &clock, 1)
	testing.expect(t, netcode.host_solo(host))
	testing.expect(t, netcode.host_set_paused(host, true, clock.now))
	pause_run(host, &clock, 1)
	netcode.host_add_link(host, netcode.loopback_link(hub, 0)) // opened to friends while paused
	verified := host.client.verified
	pause_run(host, &clock, 1)
	testing.expect(t, !host.paused, "a link resumes the pause")
	testing.expect(t, host.client.verified > verified, "ticks go on")
	testing.expect(t, !netcode.host_solo(host))
	testing.expect(t, !netcode.host_set_paused(host, true, clock.now), "refused with a remote link")
}

// A paused session steps exactly the ticks asked (netcode.host_advance) and stays paused, and a session stepped that
// way records the input log of one never paused: two hosts with the same scripted inputs, one paused in the middle
// and stepped in uneven chunks before it resumes.
@(test)
a_paused_session_steps_exactly_and_records_the_same_log :: proc(t: ^testing.T) {
	recordings: [2][dynamic]u8
	defer for &recording in recordings do delete(recording)
	watches: [2]Watch
	defer for &watch in watches do delete(watch.statuses)
	for &recording, i in recordings {
		host := netcode.host_create(
			&toy.GAME,
			{seed = SEED, ticks = PAUSE_TICKS, recording = sim.log_sink_memory(&recording)},
			hooks_for(&watches[i]),
		)
		defer netcode.host_destroy(host)
		clock := netcode.Virtual_Clock {
			now = 1_000_000,
		}
		pause_run(host, &clock, 2)
		if i == 1 {
			testing.expect_value(t, netcode.host_advance(host, 5), 0) // not paused: nothing
			testing.expect(t, netcode.host_set_paused(host, true, clock.now))
			for chunk in ([]u32{1, 7, 1, 30, 64}) {
				local := host.client.local
				testing.expect_value(t, netcode.host_advance(host, chunk), chunk)
				testing.expect_value(t, host.client.local, local + chunk)
				testing.expect_value(t, host.client.predicted, host.client.local)
				pause_run(host, &clock, 1) // paused: the clock stands still between steps
				testing.expect_value(t, host.client.local, local + chunk)
				testing.expect(t, host.paused)
			}
			testing.expect(t, !netcode.host_set_paused(host, false, clock.now))
		}
		pause_run(host, &clock, 30)
		testing.expect(t, netcode.host_finished(host), "the session ran to its end")
		testing.expect_value(t, host.client.verified, PAUSE_TICKS)
		testing.expect_value(t, host.client.stats.rollbacks, 0)
	}
	testing.expect(
		t,
		len(recordings[0]) > 0 && string(recordings[0][:]) == string(recordings[1][:]),
		"the logs differ",
	)
}
