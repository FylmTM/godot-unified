// L2 netcode tests of a lost connection (Status.Reconnecting): the client keeps its sim, opens a new connection by
// itself and resumes from its own verified tick with no snapshot while the relay's ring holds the ticks after it, else
// comes back as a late joiner; it gives up after RECONNECT_US.
package test_netcode

import "core:testing"

import "unified:netcode"

// Steps until the first remote client is Connected again and back within a cap of the relay; how long it took.
@(private = "file")
back_at_the_live_tick :: proc(session: ^Net, seconds: f64) -> (took_ms: i64) {
	start := session.clock.now
	net_run(session, seconds, proc(session: ^Net) -> bool {
		client := session.clients[0]
		return client.status == .Connected && client.verified + client.tm.prediction_cap >= session.relay.finalized
	})
	return (session.clock.now - start) / 1000
}

// Both ways dark for 12 s: the relay and the client each time the other out after 10 s. The client reconnects on a new
// connection, the relay takes its resume (the ticks since are in its ring, its checksum is the majority's), and it
// plays on with the sim it had: Reconnecting, then Connected, no new snapshot, the checksums agree.
@(test)
a_lost_connection_resumes_without_a_snapshot :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, gate := gated_join(&session, 1, netcode.PROFILES[.Wan], &session.watch[1])
	net_run(&session, 3)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	snapshot_bytes := client.stats.snapshot_bytes
	gate.block_out, gate.block_in = true, true
	net_run(&session, 12)
	testing.expect_value(t, client.status, netcode.Status.Reconnecting)
	testing.expect(t, session.relay.seats[1].conn < 0)
	gate.block_out, gate.block_in = false, false
	took_ms := back_at_the_live_tick(&session, 10)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	testing.expectf(t, took_ms < 2000, "back at the live tick in %d ms", took_ms)
	testing.expect_value(t, client.stats.reconnects, 1)
	testing.expect_value(t, client.stats.resumes, 1)
	testing.expect_value(t, session.relay.resumes, 1)
	testing.expect_value(t, client.stats.snapshot_bytes, snapshot_bytes) // no new snapshot
	net_run(&session, 3)
	testing.expect_value(t, session.relay.desyncs, 0)
	statuses := session.watch[1].statuses[:]
	testing.expectf(
		t,
		len(statuses) >= 2 &&
		statuses[len(statuses) - 2] == .Reconnecting &&
		statuses[len(statuses) - 1] == .Connected,
		"statuses %v",
		statuses,
	)
	expect_agree(t, &session)
}

// One way dark (the relay stops hearing the client, the client still hears the relay): the relay forgets the client
// after 10 s, the client learns it when its own timeout comes (nothing arrives for its connection any more: the relay's
// epoch moved on), reconnects and resumes. (This used to end the client's session.)
@(test)
a_one_way_outage_resumes :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, gate := gated_join(&session, 1, netcode.PROFILES[.Wan], &session.watch[1])
	net_run(&session, 3)
	gate.block_out = true
	net_run(&session, 12)
	testing.expect(t, session.relay.seats[1].conn < 0)
	gate.block_out = false
	took_ms := back_at_the_live_tick(&session, 15)
	testing.expectf(t, client.status == .Connected, "%v (%s) after %d ms", client.status, client.detail, took_ms)
	testing.expect_value(t, client.stats.resumes, 1)
	testing.expect_value(t, session.relay.desyncs, 0)
	expect_agree(t, &session)
}

// Dark for 30 s: past what a resume reaches (RESUME_MAX ticks, 26 s at 64 Hz), inside the reconnect time. The client
// comes back as a late joiner with a snapshot: its old sim is replaced.
@(test)
a_resume_too_old_falls_back_to_a_snapshot :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, gate := gated_join(&session, 1, netcode.PROFILES[.Wan], &session.watch[1])
	net_run(&session, 3)
	snapshot_bytes := client.stats.snapshot_bytes
	gate.block_out, gate.block_in = true, true
	net_run(&session, 30)
	gate.block_out, gate.block_in = false, false
	back_at_the_live_tick(&session, 10)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	testing.expect_value(t, client.stats.resumes, 0)
	testing.expect_value(t, session.relay.resumes, 0)
	testing.expect(t, client.stats.snapshot_bytes > 0 && client.stats.snapshot_us > 0)
	_ = snapshot_bytes
	net_run(&session, 2)
	testing.expect_value(t, session.relay.desyncs, 0)
	expect_agree(t, &session)
}

// A resume whose checksum is not the majority's (the client's state is not the session's) is a late join with a
// snapshot instead: never a resume of a diverged sim.
@(test)
a_resume_with_another_checksum_gets_a_snapshot :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, gate := gated_join(&session, 1, netcode.PROFILES[.Wan], &session.watch[1])
	net_run(&session, 3)
	gate.block_out, gate.block_in = true, true
	net_run(&session, 0.5) // its verified tick stops moving
	// what the client will resume from: its checksum of the checksum tick at or before its verified tick, spoiled
	check_tick := client.verified - client.verified % netcode.CHECKSUM_EVERY
	client.chk[(check_tick / netcode.CHECKSUM_EVERY) % netcode.CHK_RING].value ~= 1
	net_run(&session, 11.5)
	gate.block_out, gate.block_in = false, false
	back_at_the_live_tick(&session, 10)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	testing.expect_value(t, client.stats.resumes, 0)
	testing.expect_value(t, session.relay.resumes, 0)
	net_run(&session, 2)
	testing.expect_value(t, session.relay.desyncs, 0)
	expect_agree(t, &session)
}

// Dark for good: the client gives up RECONNECT_US after the loss, Disconnected ("connection lost").
@(test)
a_reconnect_gives_up :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, gate := gated_join(&session, 1, netcode.PROFILES[.Wan], &session.watch[1])
	net_run(&session, 3)
	gate.block_out, gate.block_in = true, true
	net_run(&session, 35)
	testing.expect_value(t, client.status, netcode.Status.Reconnecting)
	net_run(&session, 10)
	testing.expect_value(t, client.status, netcode.Status.Disconnected)
	testing.expect_value(t, client.detail, "connection lost")
}

// A client that leaves while reconnecting finishes "left" at once, and a session that ends meanwhile is not waited on.
@(test)
a_reconnecting_client_can_leave :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, gate := gated_join(&session, 1, netcode.PROFILES[.Wan], &session.watch[1])
	net_run(&session, 3)
	gate.block_out, gate.block_in = true, true
	net_run(&session, 12)
	testing.expect_value(t, client.status, netcode.Status.Reconnecting)
	netcode.client_stop(client, session.clock.now)
	net_run(&session, 3)
	testing.expect_value(t, client.status, netcode.Status.Disconnected)
	testing.expect_value(t, client.detail, "left")
}

// A client with two local players loses its link: its Hello on the new connection asks for both, the resume takes the
// one sim back, and both are seated again as the same members (the token says who they are), with no new snapshot.
@(test)
a_client_with_two_local_players_resumes_both :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, gate := gated_join(&session, 1, netcode.PROFILES[.Wan], &session.watch[1])
	client.cfg.token = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} // the link vouches for nobody
	testing.expect(t, add_second(client))
	net_run(&session, 3)
	first, second := netcode.client_local(client, 0), netcode.client_local(client, 1)
	testing.expect_value(t, first.state, netcode.Local_State.Seated)
	testing.expect_value(t, second.state, netcode.Local_State.Seated)
	snapshot_bytes := client.stats.snapshot_bytes
	gate.block_out, gate.block_in = true, true
	net_run(&session, 12)
	testing.expect_value(t, client.status, netcode.Status.Reconnecting)
	gate.block_out, gate.block_in = false, false
	back_at_the_live_tick(&session, 10)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	testing.expect_value(t, client.stats.resumes, 1)
	testing.expect_value(t, client.stats.snapshot_bytes, snapshot_bytes)
	again_first, again_second := netcode.client_local(client, 0), netcode.client_local(client, 1)
	testing.expect_value(t, again_first.state, netcode.Local_State.Seated)
	testing.expect_value(t, again_second.state, netcode.Local_State.Seated)
	testing.expect_value(t, again_first.member, first.member)
	testing.expect_value(t, again_second.member, second.member)
	testing.expect(t, again_first.slot != again_second.slot)
	net_run(&session, 3)
	testing.expect_value(t, session.relay.desyncs, 0)
	expect_agree(t, &session)
}
