// A host stall (src/netcode/README.md, Host): the process stopped while its clock ran on (a debugger break, a laptop
// asleep), so host_step comes seconds or hours after the last one.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

STALL_TICKS :: 600

// A single-player host stalled mid-run goes on where it stopped, as if paused for the stall: two hosts with the same
// scripted inputs, one stalled for `gap` seconds after 3 s (while paused, with `paused`), record the same input log,
// keep their one member and never reconnect, and the first step after the stall catches nothing up.
solo_stall :: proc(t: ^testing.T, gap: i64, paused := false) {
	recordings: [2][dynamic]u8
	defer for &recording in recordings do delete(recording)
	watches: [2]Watch
	defer for &watch in watches do delete(watch.statuses)
	for &recording, i in recordings {
		host := netcode.host_create(
			&toy.GAME,
			{seed = SEED, ticks = STALL_TICKS, recording = sim.log_sink_memory(&recording)},
			hooks_for(&watches[i]),
		)
		defer netcode.host_destroy(host)
		clock := netcode.Virtual_Clock {
			now = 1_000_000,
		}
		pause_run(host, &clock, 3)
		if i == 1 {
			if paused do testing.expect(t, netcode.host_set_paused(host, true, clock.now))
			clock.now += gap * 1_000_000
			if paused do testing.expect(t, !netcode.host_set_paused(host, false, clock.now))
			before := host.client.verified
			netcode.host_step(host, clock.now)
			testing.expectf(
				t,
				host.client.verified - before <= 1,
				"%d s: %d ticks caught up",
				gap,
				host.client.verified - before,
			)
			testing.expect_value(t, host.stalls, paused ? 0 : 1) // a pause absorbs it: not folded twice
		}
		pause_run(host, &clock, 30)
		testing.expectf(t, netcode.host_finished(host), "%d s: the session ran to its end", gap)
		testing.expect_value(t, host.client.verified, STALL_TICKS)
		testing.expect_value(t, len(host.relay.members), 1)
		testing.expect_value(t, host.relay.replaced, 0)
		testing.expect_value(t, host.client.stats.stall_ticks, 0)
		testing.expect_value(t, host.client.stats.reconnects, 0)
		for status in watches[i].statuses {
			testing.expectf(t, status != .Reconnecting && status != .Failed, "%d s: %v", gap, status)
		}
	}
	testing.expectf(
		t,
		len(recordings[0]) > 0 && string(recordings[0][:]) == string(recordings[1][:]),
		"%d s: the logs differ",
		gap,
	)
}

@(test)
a_solo_host_stalled_11_s_goes_on_where_it_stopped :: proc(t: ^testing.T) {
	solo_stall(t, 11)
}

@(test)
a_solo_host_stalled_40_s_goes_on_where_it_stopped :: proc(t: ^testing.T) {
	solo_stall(t, 40)
}

@(test)
a_solo_host_stalled_an_hour_goes_on_where_it_stopped :: proc(t: ^testing.T) {
	solo_stall(t, 3600)
}

@(test)
a_paused_host_stalled_an_hour_goes_on_where_it_stopped :: proc(t: ^testing.T) {
	solo_stall(t, 3600, paused = true)
}

// Steps only the remote clients for `seconds` of virtual time: the host's process is stopped.
hold_host :: proc(session: ^Net, seconds: f64) {
	end := session.clock.now + i64(seconds * 1e6)
	for session.clock.now < end {
		wake := end
		for client in session.clients do wake = min(wake, netcode.client_step(client, session.clock.now))
		session.clock.now = clamp(wake, session.clock.now + 1, end)
	}
}

// A host with a remote player stalled under DISCONNECT_US plays the gap on: both keep their members and seats, and
// nobody reconnects.
@(test)
a_linked_host_stalled_9_s_keeps_everyone :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	remote := net_join(&session, profile = .Ideal, token = netcode.Token{0 = 7}) // a Godot joiner always has one
	net_run(&session, 3)
	testing.expect_value(t, remote.status, netcode.Status.Connected)
	hold_host(&session, 9)
	net_run(&session, 5)
	testing.expect_value(t, session.host.stalls, 1)
	testing.expect_value(t, len(session.relay.members), 2)
	testing.expect_value(t, int(netcode.client_local(session.host.client, 0).member), 1)
	testing.expect_value(t, int(netcode.client_local(remote, 0).member), 2)
	testing.expect_value(t, remote.status, netcode.Status.Connected)
	testing.expect_value(t, remote.stats.reconnects, 0)
	testing.expect_value(t, session.host.client.stats.reconnects, 0)
	testing.expect_value(t, session.relay.seats[0].member, 1)
	testing.expect_value(t, session.relay.seats[1].member, 2)
	testing.expect(t, session.relay.finalized > 14 * 64 - 64, "the gap was played on")
	expect_agree(t, &session)
}

// A host with a remote player stalled past DISCONNECT_US goes on at the tick it stopped on: its own player stays, and
// the remote (whose side timed out) comes back as itself through the reconnect, at that tick.
@(test)
a_linked_host_stalled_12_s_brings_the_remote_back :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	remote := net_join(&session, profile = .Ideal, token = netcode.Token{0 = 7}) // a Godot joiner always has one
	net_run(&session, 3)
	testing.expect_value(t, remote.status, netcode.Status.Connected)
	finalized := session.relay.finalized
	hold_host(&session, 12)
	testing.expect_value(t, remote.status, netcode.Status.Reconnecting) // its side timed out
	netcode.host_step(session.host, session.clock.now)
	testing.expectf(
		t,
		session.relay.finalized - finalized <= 4,
		"finalized %d ticks past where it stopped",
		session.relay.finalized - finalized,
	)
	net_run(&session, 5)
	testing.expect_value(t, session.host.stalls, 1)
	testing.expect_value(t, len(session.relay.members), 2)
	testing.expect_value(t, int(netcode.client_local(session.host.client, 0).member), 1)
	testing.expect_value(t, int(netcode.client_local(remote, 0).member), 2)
	testing.expect_value(t, remote.status, netcode.Status.Connected)
	testing.expect_value(t, session.host.client.stats.reconnects, 0)
	testing.expect_value(t, session.relay.resumes, 1)
	for status in session.watch[0].statuses do testing.expect(t, status != .Reconnecting)
	testing.expect(t, session.relay.finalized < finalized + 6 * 64, "the session went on from where it stopped")
	expect_agree(t, &session)
}

// A connection on an in-process link (Link.in_process: a host's relay and its own client) never times out, however
// long its silence; the same pair unflagged does.
@(test)
an_in_process_link_never_times_out :: proc(t: ^testing.T) {
	for in_process in ([]bool{true, false}) {
		hub := netcode.hub_create(2)
		defer netcode.hub_destroy(hub)
		a, b := netcode.channel_make(), netcode.channel_make()
		defer netcode.channel_destroy(a)
		defer netcode.channel_destroy(b)
		a_link, b_link := netcode.loopback_link(hub, 0), netcode.loopback_link(hub, 1)
		a_link.in_process, b_link.in_process = in_process, in_process
		to_b := netcode.channel_peer(a, netcode.channel_add_link(a, a_link), 1)
		netcode.channel_add_link(b, b_link)
		now: i64 = 1_000_000
		netcode.channel_send(a, to_b, {1, 2, 3}, .Reliable, now)
		for _ in 0 ..< 10 {
			now += 1000
			netcode.channel_flush(a, now)
			netcode.channel_poll(b, now)
			netcode.channel_flush(b, now)
			netcode.channel_poll(a, now)
		}
		testing.expect(t, netcode.channel_connected(a, to_b))
		now += 3600 * 1_000_000
		disconnected := false
		for event in netcode.channel_poll(a, now) do disconnected ||= event.kind == .Disconnected
		for event in netcode.channel_poll(b, now) do disconnected ||= event.kind == .Disconnected
		testing.expectf(t, disconnected != in_process, "in_process %v: disconnected %v", in_process, disconnected)
	}
}
