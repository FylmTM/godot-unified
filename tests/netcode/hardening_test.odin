// L2 netcode tests for bad, stale or hostile input and for the edges of a session: everyone
// leaving, a snapshot provider leaving, stale finalized ticks, a peer flooding reliable ids, UDP
// endpoints coming and going, and the channel's memory.
package test_netcode

import "core:net"
import "core:slice"
import "core:testing"
import "core:time"

import "../toy"
import "unified:netcode"
import "unified:sim"
import "unified:wire"

// With nobody left in the session the relay must not finalize ahead of its clock: an endless host
// session whose players all leave (or whose own loopback peer times out) used to append ticks
// until the session length (forever when endless) in one step. A player who comes back is refused: nobody is
// left to send it a snapshot, and the relay keeps only its last RELAY_RING ticks (no replay from tick 0).
@(test)
relay_idles_when_everyone_left :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 1_000_000)
	defer net_destroy(&session)
	client := net_join(&session)
	net_run(&session, 2)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	netcode.client_stop(client, session.clock.now)
	net_run(&session, 1)
	testing.expect_value(t, client.status, netcode.Status.Disconnected)
	testing.expect(t, !session.relay.seats[0].connected)
	testing.expectf(
		t,
		session.relay.finalized <= session.relay.clock + 1,
		"finalized %d at clock %d",
		session.relay.finalized,
		session.relay.clock,
	)
	again := net_join(&session)
	net_run(&session, 2)
	testing.expect_value(t, again.status, netcode.Status.Failed)
	testing.expect_value(t, again.detail, "no player can send this player a snapshot")
	testing.expect(t, session.relay.finalized <= session.relay.clock + 1)
}

// The provider of a late joiner's snapshot leaves before sending it: the relay asks another player.
@(test)
snapshot_provider_leaves_another_steps_in :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 2, 0)
	defer net_destroy(&session)
	provider := net_join(&session, 0)
	bystander := net_join(&session, 1)
	net_run(&session, 2)
	joiner := net_join(&session)
	net_run(&session, 1, proc(session: ^Net) -> bool {return session.relay.seats[2].provider >= 0})
	testing.expect_value(t, session.relay.seats[2].provider, 0) // the lowest player that can provide: provider
	netcode.client_stop(provider, session.clock.now)
	net_run(&session, 4)
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect_value(t, joiner.slot, 2)
	testing.expect(t, joiner.verified > joiner.first_tick)
	testing.expect_value(t, bystander.status, netcode.Status.Connected)
	expect_agree(t, &session)
}

// ... and with nobody else to ask, the joiner is refused and its seat is free again.
@(test)
snapshot_provider_leaves_joiner_is_refused :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	provider := net_join(&session, 0)
	net_run(&session, 2)
	joiner := net_join(&session)
	net_run(&session, 1, proc(session: ^Net) -> bool {return session.relay.seats[1].provider >= 0})
	testing.expect_value(t, session.relay.seats[1].provider, 0)
	netcode.client_stop(provider, session.clock.now)
	net_run(&session, 4)
	testing.expect_value(t, joiner.status, netcode.Status.Failed)
	testing.expect_value(t, joiner.detail, "no player can send this player a snapshot")
	testing.expect(t, !session.relay.seats[1].connected)
}

// A raw channel standing in for the relay, to send a client exactly the messages a test wants.
Fake_Relay :: struct {
	channel: ^netcode.Channel,
	peer:    netcode.Peer,
	writer:  wire.Writer,
	now:     i64,
}

fake_make :: proc(fake: ^Fake_Relay, hub: ^netcode.Hub) {
	fake.channel = netcode.channel_make()
	netcode.channel_add_link(fake.channel, netcode.loopback_link(hub, 0))
	fake.peer = -1
	fake.writer = wire.writer_make(netcode.MAX_DATAGRAM)
	fake.now = 1_000_000
}

fake_destroy :: proc(fake: ^Fake_Relay) {
	netcode.channel_destroy(fake.channel)
	delete(fake.writer.buf)
}

// Steps the fake relay and the client once, `elapsed_us` later.
fake_step :: proc(fake: ^Fake_Relay, client: ^Client, elapsed_us: i64 = 1000) {
	fake.now += elapsed_us
	netcode.channel_flush(fake.channel, fake.now)
	netcode.client_step(client, fake.now)
	for event in netcode.channel_poll(fake.channel, fake.now) {
		if event.kind == .Connected || event.kind == .Message {
			fake.peer = event.peer
		}
	}
}

fake_send :: proc(fake: ^Fake_Relay, delivery: netcode.Delivery = .Reliable) {
	netcode.channel_send(fake.channel, fake.peer, fake.writer.buf[:], delivery, fake.now)
}

fake_send_bytes :: proc(fake: ^Fake_Relay, bytes: []u8) {
	netcode.channel_send(fake.channel, fake.peer, bytes, .Reliable, fake.now)
}

fake_begin :: proc(fake: ^Fake_Relay, msg: netcode.Msg) -> ^wire.Writer {
	clear(&fake.writer.buf)
	wire.w_u8(&fake.writer, u8(msg))
	return &fake.writer
}

fake_welcome :: proc(fake: ^Fake_Relay, client: ^Client) {
	for fake.peer < 0 {
		fake_step(fake, client)
	}
	writer := fake_begin(fake, .Welcome)
	wire.w_u8(writer, 0) // slot
	wire.w_u16(writer, 1) // member
	wire.w_u64(writer, SEED)
	wire.w_u16(writer, toy.HZ)
	wire.w_u32(writer, 0) // endless
	wire.w_u32(writer, 1) // present from tick 1
	wire.w_u8(writer, 0)
	fake_send(fake)
	fake_step(fake, client)
	fake_step(fake, client)
}

finalized_of :: proc(tick: u32, dx: i8) -> (inputs: toy.Inputs) {
	inputs.present = {0}
	if tick == 1 do inputs.joins[0] = 1 // the join record
	inputs.input[0] = {
		dx = dx,
	}
	return
}

fake_finalized :: proc(fake: ^Fake_Relay, first: u32, ticks: []toy.Inputs) {
	writer := fake_begin(fake, .Finalized)
	wire.w_u64(writer, u64(fake.now)) // relay time
	wire.w_u32(writer, 0) // input ack
	wire.w_u32(writer, 0) // command ack
	wire.w_u32(writer, first)
	wire.w_u8(writer, u8(len(ticks)))
	for &tick_inputs, i in ticks {
		netcode.window_write_tick(writer, &tick_inputs, i > 0 ? &ticks[i - 1] : nil)
	}
	fake_send(fake, .Unreliable)
}

// A Finalized datagram reordered by more than the ring (FIN_RING ticks) must not overwrite the slot a
// newer, not yet verified tick shares with it.
@(test)
stale_finalized_is_ignored :: proc(t: ^testing.T) {
	STALE :: 89
	LAST :: STALE + netcode.FIN_RING - 1 // verified before the stale copy arrives; the next tick shares its slot
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	fake: Fake_Relay
	fake_make(&fake, hub)
	defer fake_destroy(&fake)
	watch: Watch
	client := netcode.client_create(&toy.GAME, {
			slot = -1,
		}, netcode.loopback_link(hub, 1), hooks_for(&watch))
	defer netcode.client_destroy(client)
	defer delete(watch.statuses)
	fake_welcome(&fake, client)
	reference := sim.create(&toy.GAME, SEED)
	defer sim.destroy(reference)
	batch: [16]toy.Inputs
	for first := u32(1); first <= LAST; first += 16 {
		for k in 0 ..< 16 {
			batch[k] = finalized_of(first + u32(k), 1)
			if first + u32(k) <= LAST {
				sim.step(reference, &batch[k])
			}
		}
		fake_finalized(&fake, first, batch[:min(16, LAST + 1 - int(first))])
		fake_step(&fake, client)
		fake_step(&fake, client)
	}
	testing.expect_value(t, client.verified, LAST)
	// The next tick arrives, then a copy of tick STALE delayed by the whole ring: the same ring slot.
	next := [1]toy.Inputs{finalized_of(LAST + 1, 3)}
	stale := [1]toy.Inputs{finalized_of(STALE, -3)}
	sim.step(reference, &next[0])
	fake_finalized(&fake, LAST + 1, next[:])
	fake_finalized(&fake, STALE, stale[:])
	fake_step(&fake, client)
	fake_step(&fake, client)
	testing.expect_value(t, client.verified, LAST + 1)
	testing.expect_value(t, client.fin_tick[(LAST + 1) % netcode.FIN_RING], LAST + 1)
	testing.expect_value(t, sim.checksum(client.sim), sim.checksum(reference))
}

// A raw datagram with reliable chunks of the given ids (1 byte each).
reliable_datagram :: proc(writer: ^wire.Writer, epoch, seq: u32, ids: []u32) {
	clear(&writer.buf)
	wire.w_u8(writer, netcode.DGRAM_TAG)
	wire.w_u32(writer, epoch)
	wire.w_u32(writer, 0)
	wire.w_u32(writer, seq)
	wire.w_u32(writer, 0)
	wire.w_u32(writer, 0)
	wire.w_u8(writer, 0) // recent: the ack
	wire.w_u16(writer, max(u16)) // no round-trip sample
	wire.w_u8(writer, u8(len(ids)))
	for id in ids {
		wire.w_u8(writer, 1)
		wire.w_u32(writer, id)
		wire.w_u16(writer, 1)
		wire.w_u8(writer, 0xEE)
	}
}

// A peer that sends reliable ids far ahead of the next expected one (never the next) cannot grow
// the receiver's out-of-order buffer past the window.
@(test)
reliable_reorder_buffer_is_bounded :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	channel := netcode.channel_make()
	defer netcode.channel_destroy(channel)
	netcode.channel_add_link(channel, netcode.loopback_link(hub, 0))
	raw := netcode.loopback_link(hub, 1)
	defer netcode.link_close(&raw)
	writer := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(writer.buf)
	ids: [100]u32
	for k in 0 ..< 50 {
		for i in 0 ..< 100 {
			ids[i] = u32(1 + k * 100 + i)
		}
		reliable_datagram(&writer, 77, u32(k + 1), ids[:])
		netcode.link_send(&raw, 0, writer.buf[:])
		netcode.channel_poll(channel, 1_000_000 + i64(k) * 1000)
	}
	testing.expectf(
		t,
		len(channel.conns[0].rel_early) < netcode.REL_WINDOW,
		"%d early messages buffered",
		len(channel.conns[0].rel_early),
	)
	// The missing id 0 releases what the window kept, in order.
	ids[0] = 0
	reliable_datagram(&writer, 77, 51, ids[:1])
	netcode.link_send(&raw, 0, writer.buf[:])
	events := netcode.channel_poll(channel, 2_000_000)
	testing.expect_value(t, len(events), netcode.REL_WINDOW)
	testing.expect_value(t, channel.conns[0].rel_next, netcode.REL_WINDOW)
}

// A channel costs little until peers connect (it used to embed 32 peers' sent-packet rings: 8.8 MiB).
@(test)
channel_memory :: proc(t: ^testing.T) {
	testing.expectf(t, size_of(netcode.Channel) < 16 * 1024, "Channel is %d bytes", size_of(netcode.Channel))
}

// UDP: endpoints that come and go (client restarts get new ports) and garbage from strangers
// don't use up the relay's peer numbers.
@(test)
udp_endpoints_are_reused :: proc(t: ^testing.T) {
	link, ok := netcode.udp_listen(0, .Local)
	if !testing.expect(t, ok) {
		return
	}
	port := netcode.udp_bound_port(&link)
	server := netcode.channel_make()
	defer netcode.channel_destroy(server)
	netcode.channel_add_link(server, link)
	remote := net.Endpoint{net.IP4_Loopback, port}
	garbage := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	for i in 0 ..< 2 * netcode.MAX_PEERS {
		// A stranger's garbage, then a client that connects, says something and leaves.
		junk, junk_ok := netcode.udp_connect(remote)
		testing.expect(t, junk_ok)
		netcode.link_send(&junk, 0, garbage[:])
		netcode.link_close(&junk)
		client_link, client_ok := netcode.udp_connect(remote)
		testing.expect(t, client_ok)
		client := netcode.channel_make()
		link_index := netcode.channel_add_link(client, client_link)
		peer := netcode.channel_peer(client, link_index, 0)
		msg := [3]u8{u8(i), 0xAB, 0xCD}
		netcode.channel_send(client, peer, msg[:], .Reliable, netcode.now_us())
		netcode.channel_flush(client, netcode.now_us())
		got := netcode.Peer(-1)
		deadline := netcode.now_us() + 200_000
		for got < 0 && netcode.now_us() < deadline {
			for event in netcode.channel_poll(server, netcode.now_us()) {
				if event.kind == .Message && len(event.data) == 3 && event.data[0] == u8(i) {
					got = event.peer
				}
			}
			time.sleep(200 * time.Microsecond)
		}
		testing.expectf(t, got >= 0, "client %d never got through", i)
		if got >= 0 {
			netcode.channel_drop(server, got)
		}
		netcode.channel_destroy(client)
	}
}

// A message too long for one datagram (it can arrive as an unreliable chunk and be forwarded
// reliably, which has more framing) is dropped, never an assert.
@(test)
oversized_message_is_dropped :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	channel := netcode.channel_make()
	defer netcode.channel_destroy(channel)
	link_index := netcode.channel_add_link(channel, netcode.loopback_link(hub, 0))
	peer := netcode.channel_peer(channel, link_index, 1)
	big: [netcode.MAX_MESSAGE + 4]u8
	testing.expect(t, !netcode.channel_send(channel, peer, big[:], .Reliable, 1_000))
	testing.expect(t, netcode.channel_send(channel, peer, big[:netcode.MAX_MESSAGE], .Reliable, 1_000))
}

// Another player can't feed a late joiner a snapshot the relay didn't ask it for.
@(test)
only_the_asked_provider_sends_snapshots :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0)
	net_run(&session, 1)
	// An attacker takes player 1 with a raw channel.
	evil := netcode.channel_make()
	defer netcode.channel_destroy(evil)
	link_index := netcode.channel_add_link(evil, netcode.loopback_link(session.hub, 7))
	evil_peer := netcode.channel_peer(evil, link_index, 0)
	writer := wire.writer_make(64)
	defer delete(writer.buf)
	wire.w_u8(&writer, u8(netcode.Msg.Hello))
	wire.w_u8(&writer, netcode.ANY_SLOT)
	wire.w_u32(&writer, 0)
	wire.w_u64(&writer, sim.compat_of(&toy.GAME))
	wire.w_bytes(&writer, make([]u8, netcode.TOKEN_SIZE, context.temp_allocator))
	wire.w_u8(&writer, 0)
	netcode.channel_send(evil, evil_peer, writer.buf[:], .Reliable, session.clock.now)
	for _ in 0 ..< 20 {
		netcode.channel_flush(evil, session.clock.now)
		netcode.channel_poll(evil, session.clock.now)
		net_run(&session, 0.01)
	}
	testing.expect(t, session.relay.seats[1].connected)
	joiner := net_join(&session)
	net_run(&session, 1, proc(session: ^Net) -> bool {return session.relay.seats[2].provider >= 0})
	testing.expect_value(t, session.relay.seats[2].provider, 0)
	// The attacker sends a 5-byte "snapshot" for the joiner.
	clear(&writer.buf)
	wire.w_u8(&writer, u8(netcode.Msg.Snap_Begin))
	wire.w_u8(&writer, 2)
	wire.w_u32(&writer, session.relay.finalized)
	wire.w_u32(&writer, 5)
	netcode.channel_send(evil, evil_peer, writer.buf[:], .Reliable, session.clock.now)
	clear(&writer.buf)
	wire.w_u8(&writer, u8(netcode.Msg.Snap_Chunk))
	wire.w_u8(&writer, 2)
	wire.w_u32(&writer, 0)
	wire.w_bytes(&writer, {1, 2, 3, 4, 5})
	netcode.channel_send(evil, evil_peer, writer.buf[:], .Reliable, session.clock.now)
	for _ in 0 ..< 300 {
		netcode.channel_flush(evil, session.clock.now)
		netcode.channel_poll(evil, session.clock.now)
		net_run(&session, 0.01)
	}
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect(t, joiner.verified > joiner.first_tick)
}

// A build whose simulation differs (here: another sim version) is refused with "a different game build or level"
// instead of joining and desyncing; compat comes from the game by default.
@(test)
other_build_is_refused :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0)
	net_run(&session, 1)
	other := toy.GAME
	other.version = "a version the toy never has"
	link := netcode.loopback_link(session.hub, 6)
	client := netcode.client_create(&other, {
			slot = -1,
		}, link, hooks_for(&session.watch[6]))
	append(&session.clients, client)
	net_run(&session, 1)
	testing.expect_value(t, client.status, netcode.Status.Failed)
	testing.expect_value(t, client.detail, "a different game build or level")
}

// Two builds that differ only in the library's simulation (LIBRARY_VERSION) or the unified-box3d pin refuse each
// other at hello (#233): both are in compat.
@(test)
other_library_build_is_refused :: proc(t: ^testing.T) {
	this := sim.compat_of(&toy.GAME)
	testing.expect_value(t, sim.compat_of(&toy.GAME, nil, {sim.LIBRARY_VERSION, sim.box3d_pin()}), this)
	others := []sim.Library{{version = sim.LIBRARY_VERSION + 1}, {box3d = "another-release"}}
	for library, i in others {
		compat := sim.compat_of(&toy.GAME, nil, library)
		testing.expect(t, compat != this)
		session: Net
		net_make_relay(&session, 1, 0)
		defer net_destroy(&session)
		net_join(&session, 0)
		net_run(&session, 1)
		link := netcode.loopback_link(session.hub, 6)
		client := netcode.client_create(&toy.GAME, {
				slot   = -1,
				compat = compat,
			}, link, hooks_for(&session.watch[6]))
		append(&session.clients, client)
		net_run(&session, 1)
		testing.expectf(t, client.status == .Failed, "build %d: %v", i, client.status)
		testing.expect_value(t, client.detail, "a different game build or level")
	}
}

// A raw channel seated as `slot` in a session that has not started (a start player): a hostile client.
Evil :: struct {
	channel: ^netcode.Channel,
	peer:    netcode.Peer,
	writer:  wire.Writer,
	slot:    u8,
	acking:  bool, // acks the relay's finalized ticks (with no inputs), so it isn't dropped as too far behind
}

evil_seat :: proc(evil: ^Evil, session: ^Net, endpoint: int, slot: u8, token: netcode.Token = {}) {
	token := token
	evil.slot = slot
	evil.channel = netcode.channel_make()
	link_index := netcode.channel_add_link(evil.channel, netcode.loopback_link(session.hub, netcode.Peer(endpoint)))
	evil.peer = netcode.channel_peer(evil.channel, link_index, 0)
	evil.writer = wire.writer_make(64)
	writer := evil_begin(evil, .Hello)
	wire.w_u8(writer, slot)
	wire.w_u32(writer, 0)
	wire.w_u64(writer, sim.compat_of(&toy.GAME))
	wire.w_bytes(writer, token[:])
	wire.w_u8(writer, 0)
	evil_send(evil, session)
}

evil_begin :: proc(evil: ^Evil, msg: netcode.Msg) -> ^wire.Writer {
	clear(&evil.writer.buf)
	wire.w_u8(&evil.writer, u8(msg))
	return &evil.writer
}

evil_send :: proc(evil: ^Evil, session: ^Net) {
	netcode.channel_send(evil.channel, evil.peer, evil.writer.buf[:], .Reliable, session.clock.now)
}

// Runs the session and the evil channel for `seconds`, in rounds of `round` seconds, or until `done` says so; returns
// the first message the evil channel got of `kind` (empty: none). `hitched`: as net_run's.
evil_run :: proc(
	evil: ^Evil,
	session: ^Net,
	seconds: f64,
	kind := netcode.Msg(0),
	round := 0.01,
	hitched := -1,
	done: proc(session: ^Net) -> bool = nil,
) -> (
	got: []u8,
) {
	for _ in 0 ..< int(seconds / round + 0.5) {
		netcode.channel_flush(evil.channel, session.clock.now)
		for event in netcode.channel_poll(evil.channel, session.clock.now) {
			if event.kind == .Message && got == nil && len(event.data) > 0 && netcode.Msg(event.data[0]) == kind {
				got = slice.clone(event.data, context.temp_allocator)
			}
		}
		if evil.acking {
			writer := evil_begin(evil, .Inputs)
			wire.w_u32(writer, session.relay.finalized)
			wire.w_u32(writer, 0)
			wire.w_u8(writer, 0) // no inputs
			wire.w_u32(writer, 1)
			wire.w_u8(writer, 0) // no commands
			netcode.channel_send(evil.channel, evil.peer, writer.buf[:], .Unreliable, session.clock.now)
		}
		net_run(session, round, hitched = hitched)
		if done != nil && done(session) do return
	}
	return
}

// Sends `snapshot` of `tick` for the joiner in `target` as a provider does: Snap_Begin, then the chunks.
evil_snapshot :: proc(evil: ^Evil, session: ^Net, target: u8, tick: u32, snapshot: []u8) {
	writer := evil_begin(evil, .Snap_Begin)
	wire.w_u8(writer, target)
	wire.w_u32(writer, tick)
	wire.w_u32(writer, u32(len(snapshot)))
	evil_send(evil, session)
	for offset := 0; offset < len(snapshot); offset += netcode.SNAP_CHUNK {
		writer = evil_begin(evil, .Snap_Chunk)
		wire.w_u8(writer, target)
		wire.w_u32(writer, u32(offset))
		wire.w_bytes(writer, snapshot[offset:min(offset + netcode.SNAP_CHUNK, len(snapshot))])
		evil_send(evil, session)
	}
}

evil_destroy :: proc(evil: ^Evil) {
	netcode.channel_destroy(evil.channel)
	delete(evil.writer.buf)
}

// A client cannot switch desync detection off: checksums of ticks the relay has not finalized are dropped, so they
// never take the ring's slots from the honest reports.
@(test)
future_checksums_are_dropped :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 2, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 1)
	defer evil_destroy(&evil)
	net_join(&session, 0)
	evil_run(&evil, &session, 1)
	testing.expect(t, session.relay.started)
	for k in 0 ..< u32(netcode.CHECK_RING) {
		writer := evil_begin(&evil, .Checksum)
		wire.w_u32(writer, 0x8000_0000 + k * netcode.CHECKSUM_EVERY)
		wire.w_u64(writer, 1)
		evil_send(&evil, &session)
	}
	flooded := session.relay.finalized
	evil_run(&evil, &session, 3) // past CHECK_WAIT_MS: the evil seat never reports, so a check is judged on its wait
	testing.expect(t, session.relay.finalized > flooded + 2 * netcode.CHECKSUM_EVERY)
	judged := false
	for check in session.relay.checks {
		testing.expectf(t, check.tick <= session.relay.finalized, "a checksum of tick %d was kept", check.tick)
		judged ||= check.judged && check.tick > flooded
	}
	testing.expect(t, judged) // honest reports are still judged
}

// A joiner in a slot another player just left, on a machine whose clock is 4 hours off the relay's, times its clock
// from the relay and measures its own round trip (nothing of the previous occupant's is taken for it).
@(test)
joiner_in_a_reused_slot_ignores_the_old_echo :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0)
	net_run(&session, 1)
	old := net_join(&session)
	net_run(&session, 3, proc(session: ^Net) -> bool {return session.clients[1].status == .Connected})
	testing.expect_value(t, old.status, netcode.Status.Connected)
	net_run(&session, 1)
	netcode.client_stop(old, session.clock.now)
	net_run(&session, 1)
	testing.expect(t, !session.relay.seats[1].connected)
	netcode.client_destroy(pop(&session.clients))

	AHEAD :: i64(4 * 3600) * 1_000_000 // the joiner's machine booted 4 hours earlier
	joiner_clock := netcode.Virtual_Clock {
		now = session.clock.now + AHEAD,
	}
	link := netcode.netsim_wrap(netcode.loopback_link(session.hub, 5), netcode.PROFILES[.Wan], 5 * 7919, &joiner_clock)
	joiner := netcode.client_create(&toy.GAME, {slot = -1}, link, hooks_for(&session.watch[5]))
	defer netcode.client_destroy(joiner)
	for _ in 0 ..< 3 * 4000 {
		session.clock.now += 250
		joiner_clock.now = session.clock.now + AHEAD
		netcode.relay_step(session.relay, session.clock.now)
		for client in session.clients do netcode.client_step(client, session.clock.now)
		netcode.client_step(joiner, joiner_clock.now)
	}
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect_value(t, joiner.slot, 1)
	testing.expectf(t, joiner.rtt_us < 300_000, "rtt %.0f us", joiner.rtt_us)
	testing.expectf(
		t,
		joiner.local < session.relay.clock + 64,
		"joiner at %d, relay at %d",
		joiner.local,
		session.relay.clock,
	)
	testing.expect_value(t, joiner.stats.own_replaced, 0)
}

// One ack that covers several datagrams measures the round trip of the newest one only: the older ones waited at
// the receiver, and their samples would read the round trip that much longer.
@(test)
one_ack_of_several_datagrams_samples_the_newest :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	sender := netcode.channel_make()
	defer netcode.channel_destroy(sender)
	receiver := netcode.channel_make()
	defer netcode.channel_destroy(receiver)
	netcode.channel_add_link(sender, netcode.loopback_link(hub, 0))
	netcode.channel_add_link(receiver, netcode.loopback_link(hub, 1))
	to := netcode.channel_peer(sender, 0, 1)
	start := i64(1_000_000)
	for k in 0 ..< i64(3) { 	// three datagrams, 10 ms apart, that the receiver reads at once
		netcode.channel_send(sender, to, {u8(k)}, .Reliable, start + k * 10_000)
		netcode.channel_flush(sender, start + k * 10_000)
	}
	netcode.channel_poll(receiver, start + 30_000)
	netcode.channel_flush(receiver, start + 30_000) // one datagram acks all three
	netcode.channel_poll(sender, start + 30_000)
	rtt, samples := netcode.channel_rtt(sender, to)
	testing.expect_value(t, samples, 1)
	testing.expect_value(t, rtt, 10_000) // the newest, sent at +20 ms; the oldest would read 30 ms
}

// Newest wins only once the new connection is accepted: a Hello with a seated member's token that is then refused
// (the slot it asks for is taken) leaves the seated connection alone.
@(test)
refused_hello_does_not_replace_the_seated_member :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 2, 0)
	defer net_destroy(&session)
	TOKEN :: netcode.Token{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	seated := netcode.client_create(
		&toy.GAME,
		{slot = 0, token = TOKEN},
		netcode.loopback_link(session.hub, 1),
		hooks_for(&session.watch[1]),
	)
	append(&session.clients, seated)
	other := netcode.client_create(
		&toy.GAME,
		{slot = 1},
		netcode.loopback_link(session.hub, 2),
		hooks_for(&session.watch[2]),
	)
	append(&session.clients, other)
	net_run(&session, 1)
	testing.expect_value(t, seated.status, netcode.Status.Connected)
	evil: Evil
	evil_seat(&evil, &session, 7, 1, TOKEN) // seat 1 is the other player's
	defer evil_destroy(&evil)
	reject := evil_run(&evil, &session, 1, .Reject)
	testing.expect(t, len(reject) == 2 && netcode.Reject_Reason(reject[1]) == .Slot_Taken)
	testing.expect(t, session.relay.seats[0].connected)
	testing.expect_value(t, seated.status, netcode.Status.Connected)
}

// A Hello while the session ends gets End at once, not 30 s of silence.
@(test)
hello_while_ending_gets_end :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	net_join(&session, 0)
	net_run(&session, 1)
	netcode.relay_stop(session.relay, session.clock.now)
	evil: Evil
	evil_seat(&evil, &session, 7, netcode.ANY_SLOT)
	defer evil_destroy(&evil)
	testing.expect(t, evil_run(&evil, &session, 0.5, .End) != nil)
}

// A snapshot provider that never sends one is replaced by another player after SNAP_STALL_US, and one whose
// snapshot the relay can't use is replaced at once: the joiner doesn't hold its seat forever.
@(test)
silent_or_unusable_snapshot_provider_is_replaced :: proc(t: ^testing.T) {
	for unusable in ([]bool{false, true}) {
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
		testing.expect_value(t, session.relay.seats[2].provider, 0)
		if unusable {
			writer := evil_begin(&evil, .Snap_Begin)
			wire.w_u8(writer, 2)
			wire.w_u32(writer, session.relay.finalized - 1) // not a checksum tick
			wire.w_u32(writer, 100)
			evil_send(&evil, &session)
			evil_run(&evil, &session, 0.1)
			testing.expect_value(t, session.relay.seats[2].provider, 1)
		}
		evil_run(&evil, &session, f64(netcode.SNAP_STALL_US) / 1e6 + 3)
		testing.expectf(t, joiner.status == .Connected, "unusable %v: the joiner is %v", unusable, joiner.status)
		testing.expect(t, joiner.verified > joiner.first_tick)
	}
}

// A client acts only on its relay's messages, and not on a Reject cut short.
@(test)
client_ignores_strangers_and_cut_rejects :: proc(t: ^testing.T) {
	hub := netcode.hub_create(3)
	defer netcode.hub_destroy(hub)
	fake: Fake_Relay
	fake_make(&fake, hub)
	defer fake_destroy(&fake)
	watch: Watch
	client := netcode.client_create(&toy.GAME, {slot = -1}, netcode.loopback_link(hub, 1), hooks_for(&watch))
	defer netcode.client_destroy(client)
	defer delete(watch.statuses)
	fake_welcome(&fake, client)
	stranger := netcode.channel_make()
	defer netcode.channel_destroy(stranger)
	netcode.channel_add_link(stranger, netcode.loopback_link(hub, 2))
	reject := []u8{u8(netcode.Msg.Reject), u8(netcode.Reject_Reason.Full)}
	netcode.channel_send(stranger, netcode.channel_peer(stranger, 0, 1), reject, .Reliable, fake.now)
	netcode.channel_flush(stranger, fake.now)
	fake_send_bytes(&fake, reject[:1]) // a Reject without its reason
	for _ in 0 ..< 10 {
		fake_step(&fake, client)
	}
	testing.expect_value(t, client.status, netcode.Status.Connected)
}

// Inputs a seat's previous occupant planted far ahead (a hostile or far-ahead client) are not the next occupant's:
// a seat is emptied when its occupant leaves.
@(test)
a_reused_seat_starts_empty :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 2, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 1)
	defer evil_destroy(&evil)
	net_join(&session, 0)
	evil.acking = true
	evil_run(&evil, &session, 1)
	planted_from := session.relay.finalized + 100
	writer := evil_begin(&evil, .Inputs)
	wire.w_u32(writer, session.relay.finalized)
	wire.w_u32(writer, planted_from)
	wire.w_u8(writer, 32)
	planted, base: toy.Input
	planted.dx = 99 // never scripted (its dx is in -3..3)
	for _ in 0 ..< 32 {
		netcode.window_write_input(writer, &planted, &base)
		base = planted
	}
	wire.w_u32(writer, 1)
	wire.w_u8(writer, 0) // no commands
	netcode.channel_send(evil.channel, evil.peer, writer.buf[:], .Unreliable, session.clock.now)
	evil.acking = false
	evil_begin(&evil, .Leave)
	evil_send(&evil, &session)
	evil_run(&evil, &session, 0.2)
	testing.expect(t, !session.relay.seats[1].connected)
	joiner := net_join(&session, 1)
	net_run(
		&session,
		4,
		proc(session: ^Net) -> bool {return(
				session.relay.finalized > session.relay.clock - 2 &&
				session.clients[1].status == .Connected \
			)},
	)
	net_run(&session, 2)
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect(t, joiner.first_tick < planted_from, "the joiner plays the planted ticks")
	testing.expect(t, session.relay.finalized > planted_from + 32)
	for tick in planted_from ..< planted_from + 32 {
		inputs := netcode.relay_tick(session.relay, tick)
		if inputs != nil && 1 in inputs.present {
			testing.expectf(t, inputs.input[1].dx != 99, "tick %d has the previous occupant's input", tick)
		}
	}
	expect_agree(t, &session)
}

// A peer on another protocol version never parses our datagrams: the relay answers its datagram with a notice of
// its own version, and a client that gets one fails at once ("a different game build"), not after 30 s of silence.
@(test)
another_protocol_version_is_told_at_once :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	stranger := netcode.loopback_link(session.hub, 6)
	defer netcode.link_close(&stranger)
	old: [netcode.HEADER_BYTES + 8]u8
	old[0] = 0x80 | u8(netcode.PROTOCOL_VERSION - 1)
	old[1] = 7 // an epoch
	netcode.link_send(&stranger, 0, old[:])
	net_run(&session, 0.01)
	buf: [netcode.MAX_DATAGRAM]u8
	size, _, got := netcode.link_recv(&stranger, buf[:])
	testing.expect(t, got && size == netcode.NOTICE_BYTES && buf[0] == netcode.DGRAM_TAG, "the relay's notice")
	testing.expect(t, got && buf[1] | buf[2] | buf[3] | buf[4] == 0)

	// A client gets a notice of another version from its relay's address.
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	relay_end := netcode.loopback_link(hub, 0)
	defer netcode.link_close(&relay_end)
	watch: Watch
	defer delete(watch.statuses)
	client := netcode.client_create(&toy.GAME, {slot = -1}, netcode.loopback_link(hub, 1), hooks_for(&watch))
	defer netcode.client_destroy(client)
	netcode.client_step(client, 1_000_000) // its Hello
	notice := [netcode.NOTICE_BYTES]u8{0x80 | u8(netcode.PROTOCOL_VERSION + 1), 0, 0, 0, 0}
	netcode.link_send(&relay_end, 1, notice[:])
	netcode.client_step(client, 1_001_000)
	testing.expect_value(t, client.status, netcode.Status.Failed)
	testing.expect_value(t, client.detail, "a different game build (another protocol version)")
}

// A seated peer that sends Leave and Hello in one datagram (or a Leave from its old connection and a Hello from its
// new one in one poll) is not seated again on the connection the Leave just ended: such a seat would have nobody
// behind it to time out, and the next newcomer, given that channel peer number, would have its Hello ignored and be
// told it fell too far behind.
@(test)
a_leave_and_a_hello_in_one_datagram_seat_nobody :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 2, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 1)
	defer evil_destroy(&evil)
	net_join(&session, 0)
	evil.acking = true
	evil_run(&evil, &session, 1)
	testing.expect(t, session.relay.seats[1].connected)
	evil.acking = false
	evil_begin(&evil, .Leave)
	evil_send(&evil, &session)
	writer := evil_begin(&evil, .Hello)
	wire.w_u8(writer, 1)
	wire.w_u32(writer, 0)
	wire.w_u64(writer, sim.compat_of(&toy.GAME))
	token: netcode.Token
	wire.w_bytes(writer, token[:])
	wire.w_u8(writer, 0)
	evil_send(&evil, &session)
	netcode.channel_flush(evil.channel, session.clock.now) // one datagram: Leave, then Hello; then silence for good
	net_run(&session, 0.5)
	seat := &session.relay.seats[1]
	testing.expectf(
		t,
		!seat.connected || netcode.channel_connected(session.relay.ch, seat.peer),
		"seat 1 is held by channel peer %d, which has no connection",
		seat.peer,
	)
	replaced := session.relay.replaced
	late := net_join(&session) // the next endpoint gets the dropped peer's number
	net_run(&session, 20)
	testing.expectf(
		t,
		late.status == .Connected,
		"a newcomer 0.5 s later is %v after 20 s (%d inputs replaced meanwhile)",
		late.status,
		session.relay.replaced - replaced,
	)
}

// The input ack (Seat.recv_upto) moves past a tick whose input came too late and was replaced: the client stops
// resending inputs the relay already holds.
@(test)
a_replaced_input_does_not_hold_the_input_ack_back :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client := net_join(&session, -1, .Wan)
	net_run(&session, 5)
	// The client's machine hitches for 300 ms: the relay replaces the inputs it misses.
	for end := session.clock.now + 300_000; session.clock.now < end; {
		wake := netcode.host_step(session.host, session.clock.now)
		session.clock.now = clamp(wake, session.clock.now + 1, end)
	}
	net_run(&session, 20)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	testing.expect(t, session.relay.replaced > 0)
	seat := &session.relay.seats[client.slot]
	testing.expectf(
		t,
		session.relay.finalized - seat.recv_upto < 64,
		"recv_upto %d, finalized %d (%d inputs replaced)",
		seat.recv_upto,
		session.relay.finalized,
		session.relay.replaced,
	)
}

// A client that stops acking finalized ticks is refused (Too_Far_Behind) once the ticks it hasn't acked leave the
// relay's ring: they can't be streamed to it any more. The others play on.
@(test)
a_client_that_stops_acking_is_refused_as_too_far_behind :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 2, 0)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 1) // never acks a finalized tick (acking false), but its channel stays connected
	defer evil_destroy(&evil)
	honest := net_join(&session, 0)
	reject := evil_run(&evil, &session, f64(netcode.RELAY_RING) / toy.HZ + 3, .Reject)
	testing.expect(t, len(reject) == 2 && netcode.Reject_Reason(reject[1]) == .Too_Far_Behind, "a Too_Far_Behind")
	testing.expect(t, session.relay.finalized > netcode.RELAY_RING)
	testing.expect(t, !session.relay.seats[1].connected)
	net_run(&session, 1)
	testing.expect_value(t, honest.status, netcode.Status.Connected)
}

// A relay time far off (a mangled first Finalized, a relay that is no relay) throws the client's clock far ahead, but
// a step still does a ring's worth of work: it samples at most OWN_RING inputs, not one per tick of the jump (2^50 µs
// would be ~7e10 ticks at 64 Hz).
@(test)
a_relay_time_far_off_costs_a_ring_of_inputs :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	fake: Fake_Relay
	fake_make(&fake, hub)
	defer fake_destroy(&fake)
	samples := 0
	hooks := Hooks {
		user = &samples,
		sample = proc(user: rawptr, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
			(^int)(user)^ += 1
			return {}
		},
	}
	client := netcode.client_create(&toy.GAME, {slot = -1}, netcode.loopback_link(hub, 1), hooks)
	defer netcode.client_destroy(client)
	fake_welcome(&fake, client)
	far := [1]toy.Inputs{finalized_of(1, 1)}
	writer := fake_begin(&fake, .Finalized)
	wire.w_u64(writer, 1 << 50) // relay time: 35 years after tick 0
	wire.w_u32(writer, 0)
	wire.w_u32(writer, 0)
	wire.w_u32(writer, 1)
	wire.w_u8(writer, 1)
	netcode.window_write_tick(writer, &far[0], nil)
	fake_send(&fake, .Unreliable)
	for _ in 0 ..< 20 {
		fake_step(&fake, client)
	}
	testing.expect(t, client.local > 1 << 30, "the clock followed the relay time")
	testing.expectf(t, samples <= 2 * netcode.OWN_RING, "%d inputs sampled", samples)
	testing.expect_value(t, client.status, netcode.Status.Connected)
}
