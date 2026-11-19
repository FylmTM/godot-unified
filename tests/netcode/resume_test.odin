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

// A link whose transport can say the relay is gone (Link.event), as EOS does when its P2P connection closes.
@(private = "file")
Cut :: struct {
	inner: netcode.Link,
	cut:   bool, // the next poll reports Disconnected, once
}

@(private = "file")
cut_wrap :: proc(inner: netcode.Link) -> (netcode.Link, ^Cut) {
	cut := new(Cut)
	cut.inner = inner
	link := netcode.Link {
		data = cut,
		send = proc(data: rawptr, to: netcode.Peer, bytes: []u8) {
			netcode.link_send(&(^Cut)(data).inner, to, bytes)
		},
		recv = proc(data: rawptr, buf: []u8) -> (size: int, from: netcode.Peer, ok: bool) {
			return netcode.link_recv(&(^Cut)(data).inner, buf)
		},
		close = proc(data: rawptr) {
			cut := (^Cut)(data)
			netcode.link_close(&cut.inner)
			free(cut)
		},
		event = proc(data: rawptr) -> (peer: netcode.Peer, kind: netcode.Link_Event_Kind, ok: bool) {
			cut := (^Cut)(data)
			if cut.cut {
				cut.cut = false
				return 0, .Disconnected, true
			}
			return
		},
	}
	return link, cut
}

// The transport says the relay is gone while the client holds finalized ticks it has not verified (it is catching up
// after a hitch, one tick per step). Its Hello resumes from its verified tick V, and V holds until the Welcome answers
// it (a V that moved on would no longer be what the relay resumed): the client resumes, catches up and agrees.
@(test)
a_resume_while_verifying_a_backlog_holds_its_verified_tick :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	inner, _ := net_link(&session)
	link, cut := cut_wrap(inner)
	client := net_join(&session, link = link)
	net_run(&session, 3)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	net_run(&session, 2, hitched = 0) // its process hitches: the relay's ticks wait in its socket
	client.cfg.catchup_ticks = 1
	netcode.client_step(client, session.clock.now) // reads the backlog, verifies one tick of it
	testing.expectf(t, client.fin_upto > client.verified, "holds %d unverified", client.fin_upto - client.verified)
	held_from := client.verified
	cut.cut = true
	for _ in 0 ..< 4 {
		netcode.client_step(client, session.clock.now)
		testing.expect_value(t, client.status, netcode.Status.Reconnecting)
		testing.expect_value(t, client.verified, held_from) // the Hello's V, until the Welcome
	}
	client.cfg.catchup_ticks = 0
	net_run(&session, 6)
	testing.expectf(
		t,
		client.status == .Connected && client.sim != nil && client.verified + 32 >= session.relay.finalized,
		"%v (%s), sim %v, verified %d, relay %d",
		client.status,
		client.detail,
		client.sim != nil,
		client.verified,
		session.relay.finalized,
	)
	testing.expect_value(t, client.stats.resumes, 1)
	testing.expect_value(t, session.relay.resumes, 1)
	net_run(&session, 2)
	testing.expect_value(t, session.relay.desyncs, 0)
	expect_agree(t, &session)
}

// How long each of the waking client's steps takes in the test below (a real game's step at its catch-up budget).
@(private = "file")
WAKING_STEP_MS :: 12

// A client whose process hitches past the relay's timeout (a suspended laptop) wakes with a socket full of finalized
// ticks, verifies a budget of them per 12 ms step and learns meanwhile that the relay forgot it: a catch-up slower than
// that notice. Its Hello's verified tick holds until the Welcome, so the relay's resume is one it can take: it is back
// at the live tick within 3 s, with its seat.
@(test)
a_resume_while_catching_up_gets_back :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, _ := gated_join(&session, 1, netcode.PROFILES[.Wan], &session.watch[1])
	net_run(&session, 3)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	net_run(&session, 11, hitched = 0) // not stepped: what arrives waits in its socket; the relay forgets it
	testing.expect(t, session.relay.seats[1].conn < 0, "the relay forgot the hitched client")
	back_ms := -1
	for k in 0 ..< 10_000 / WAKING_STEP_MS {
		net_run(&session, WAKING_STEP_MS / 1000.0, hitched = 0)
		netcode.client_step(client, session.clock.now)
		if client.status == .Connected && client.verified + 32 >= session.relay.finalized {
			back_ms = k * WAKING_STEP_MS
			break
		}
		if netcode.client_finished(client) do break
	}
	testing.expectf(
		t,
		back_ms >= 0 && back_ms < 3000,
		"back in %d ms (-1: never; %v, %s): relay resumes %d, client resumes %d, reconnects %d, sim %v",
		back_ms,
		client.status,
		client.detail,
		session.relay.resumes,
		client.stats.resumes,
		client.stats.reconnects,
		client.sim != nil,
	)
	testing.expect_value(t, client.stats.resumes, 1)
	net_run(&session, 2)
	expect_agree(t, &session)
}

// A resume the relay grants that the client cannot take (here its seed was spoiled while it was away: the state it
// would resume is not the session's) gets no snapshot from a relay that resumed it: the client drops its sim, says
// Hello again on a new connection without the resume pair, and comes back as a late joiner.
@(test)
a_resume_the_client_cannot_take_reconnects_without_it :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client, gate := gated_join(&session, 1, netcode.PROFILES[.Wan], &session.watch[1])
	net_run(&session, 3)
	gate.block_out, gate.block_in = true, true
	net_run(&session, 12)
	testing.expect_value(t, client.status, netcode.Status.Reconnecting)
	client.seed ~= 1
	gate.block_out, gate.block_in = false, false
	back_at_the_live_tick(&session, 10)
	testing.expectf(t, client.status == .Connected, "%v (%s)", client.status, client.detail)
	testing.expect_value(t, session.relay.resumes, 1)
	testing.expect_value(t, client.stats.resumes, 0)
	testing.expect_value(t, client.stats.reconnects, 2)
	testing.expect(t, client.stats.snapshot_us > 0)
	net_run(&session, 2)
	testing.expect_value(t, session.relay.desyncs, 0)
	expect_agree(t, &session)
}
