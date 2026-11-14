// L2 netcode tests for bad, stale or hostile input and for the edges of a session: everyone
// leaving, a snapshot provider leaving, stale finalized ticks, a peer flooding reliable ids, UDP
// endpoints coming and going, and the channel's memory.
package test_netcode

import "core:net"
import "core:testing"
import "core:time"

import "../toy"
import "unified:netcode"
import "unified:sim"
import "unified:wire"

Relay :: netcode.Relay(toy.Input, toy.SLOTS)

// A plain relay (no host player) and remote clients over loopback, on a virtual clock.
Rnet :: struct {
	clock:   netcode.Virtual_Clock,
	hub:     ^netcode.Hub,
	relay:   ^Relay,
	clients: [dynamic]^Client,
	watch:   [8]Watch,
}

rnet_make :: proc(n: ^Rnet, start_players: int, ticks: u32) {
	n.clock.now = 1_000_000
	n.hub = netcode.hub_create(8)
	cfg := netcode.Relay_Config {
		tick_hz       = toy.HZ,
		seed          = SEED,
		ticks         = ticks,
		start_players = start_players,
		compat        = sim.compat_of(&toy.GAME),
		name          = "relay",
		quiet         = true,
	}
	n.relay = netcode.relay_create(cfg, toy.Input, toy.SLOTS)
	netcode.relay_add_link(n.relay, netcode.loopback_link(n.hub, 0))
}

// A client under the `wan` profile.
rnet_join :: proc(n: ^Rnet, slot := -1) -> ^Client {
	k := len(n.clients) + 1
	link := netcode.netsim_wrap(
		netcode.loopback_link(n.hub, netcode.Peer(k)),
		netcode.PROFILES[1],
		u32(k) * 7919,
		&n.clock,
	)
	c := netcode.client_create(&toy.GAME, {slot = slot, name = "c", quiet = true}, link, hooks_for(&n.watch[k]))
	append(&n.clients, c)
	return c
}

rnet_run :: proc(n: ^Rnet, seconds: f64, until: proc(n: ^Rnet) -> bool = nil) {
	end := n.clock.now + i64(seconds * 1e6)
	for n.clock.now < end {
		n.clock.now += 250
		netcode.relay_step(n.relay, n.clock.now)
		for c in n.clients {
			netcode.client_step(c, n.clock.now)
		}
		if until != nil && until(n) {
			return
		}
	}
}

rnet_destroy :: proc(n: ^Rnet) {
	for c in n.clients {
		netcode.client_destroy(c)
	}
	delete(n.clients)
	netcode.relay_destroy(n.relay)
	netcode.hub_destroy(n.hub)
	for &w in n.watch {
		delete(w.statuses)
	}
}

// Every pair of clients that verified a checksummed tick agrees on it.
rnet_agree :: proc(t: ^testing.T, n: ^Rnet) {
	for a in n.clients {
		for b in n.clients {
			for ea in a.checksums {
				for eb in b.checksums {
					if ea[0] == eb[0] {
						testing.expectf(
							t,
							ea[1] == eb[1],
							"slots %d and %d disagree at tick %d",
							a.slot,
							b.slot,
							ea[0],
						)
					}
				}
			}
		}
	}
	testing.expect_value(t, n.relay.desyncs, 0)
}

// With nobody left in the session the relay must not finalize ahead of its clock: an endless host
// session whose players all leave (or whose own loopback peer times out) used to append ticks
// until the session length (forever when endless) in one step.
@(test)
relay_idles_when_everyone_left :: proc(t: ^testing.T) {
	n: Rnet
	rnet_make(&n, 1, 1_000_000)
	defer rnet_destroy(&n)
	c := rnet_join(&n)
	rnet_run(&n, 2)
	testing.expect_value(t, c.status, netcode.Status.Connected)
	netcode.client_stop(c, n.clock.now)
	rnet_run(&n, 1)
	testing.expect_value(t, c.status, netcode.Status.Disconnected)
	testing.expect(t, !n.relay.connected[0])
	testing.expectf(
		t,
		len(n.relay.log.ticks) <= int(n.relay.clock) + 1,
		"log holds %d ticks at clock %d",
		len(n.relay.log.ticks),
		n.relay.clock,
	)
	// A player who comes back finds a relay that kept pace, not one a million ticks ahead.
	again := rnet_join(&n)
	rnet_run(&n, 2)
	testing.expect_value(t, again.status, netcode.Status.Connected)
	testing.expect(t, again.verified > again.first_tick)
}

// The provider of a late joiner's snapshot leaves before sending it: the relay asks another player.
@(test)
snapshot_provider_leaves_another_steps_in :: proc(t: ^testing.T) {
	n: Rnet
	rnet_make(&n, 2, 0)
	defer rnet_destroy(&n)
	a := rnet_join(&n, 0)
	b := rnet_join(&n, 1)
	rnet_run(&n, 2)
	joiner := rnet_join(&n)
	rnet_run(&n, 1, proc(n: ^Rnet) -> bool {return n.relay.provider[2] >= 0})
	testing.expect_value(t, n.relay.provider[2], 0) // the lowest slot that can provide: a
	netcode.client_stop(a, n.clock.now)
	rnet_run(&n, 4)
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect_value(t, joiner.slot, 2)
	testing.expect(t, joiner.verified > joiner.first_tick)
	testing.expect_value(t, b.status, netcode.Status.Connected)
	rnet_agree(t, &n)
}

// ... and with nobody else to ask, the joiner starts from tick 0 and replays the log.
@(test)
snapshot_provider_leaves_joiner_replays :: proc(t: ^testing.T) {
	n: Rnet
	rnet_make(&n, 1, 0)
	defer rnet_destroy(&n)
	a := rnet_join(&n, 0)
	rnet_run(&n, 2)
	joiner := rnet_join(&n)
	rnet_run(&n, 1, proc(n: ^Rnet) -> bool {return n.relay.provider[1] >= 0})
	testing.expect_value(t, n.relay.provider[1], 0)
	netcode.client_stop(a, n.clock.now)
	rnet_run(&n, 4)
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect(t, joiner.verified > joiner.first_tick)
	testing.expect(t, len(n.relay.log.commands) > 0) // the replay reproduces commands too
	// The joiner's verified checksums are the log's, replayed from tick 0.
	if !testing.expect(t, len(joiner.checksums) > 0) {
		return
	}
	last := joiner.checksums[len(joiner.checksums) - 1]
	s := sim.create(&toy.GAME, SEED)
	defer sim.destroy(s)
	for k in 0 ..< int(last[0]) {
		in_ := sim.log_inputs(&n.relay.log, k)
		sim.step(s, &in_)
	}
	testing.expect_value(t, sim.checksum(s), last[1])
}

// A raw channel standing in for the relay, to send a client exactly the messages a test wants.
Fake_Relay :: struct {
	ch:   ^netcode.Channel,
	peer: netcode.Peer,
	w:    wire.Writer,
	now:  i64,
}

fake_make :: proc(f: ^Fake_Relay, hub: ^netcode.Hub) {
	f.ch = netcode.channel_make()
	netcode.channel_add_link(f.ch, netcode.loopback_link(hub, 0))
	f.peer = -1
	f.w = wire.writer_make(netcode.MAX_DATAGRAM)
	f.now = 1_000_000
}

fake_destroy :: proc(f: ^Fake_Relay) {
	netcode.channel_destroy(f.ch)
	delete(f.w.buf)
}

// Steps the fake relay and the client once, `us` later.
fake_step :: proc(f: ^Fake_Relay, c: ^Client, us: i64 = 1000) {
	f.now += us
	netcode.channel_flush(f.ch, f.now)
	netcode.client_step(c, f.now)
	for ev in netcode.channel_poll(f.ch, f.now) {
		if ev.kind == .Connected || ev.kind == .Message {
			f.peer = ev.peer
		}
	}
}

fake_send :: proc(f: ^Fake_Relay, d: netcode.Delivery = .Reliable) {
	netcode.channel_send(f.ch, f.peer, f.w.buf[:], d, f.now)
}

fake_begin :: proc(f: ^Fake_Relay, m: netcode.Msg) -> ^wire.Writer {
	clear(&f.w.buf)
	wire.w_u8(&f.w, u8(m))
	return &f.w
}

fake_welcome :: proc(f: ^Fake_Relay, c: ^Client) {
	for f.peer < 0 {
		fake_step(f, c)
	}
	w := fake_begin(f, .Welcome)
	wire.w_u8(w, 0) // slot
	wire.w_u64(w, SEED)
	wire.w_u16(w, toy.HZ)
	wire.w_u32(w, 0) // endless
	wire.w_u32(w, 1) // present from tick 1
	wire.w_u8(w, 0)
	fake_send(f)
	fake_step(f, c)
	fake_step(f, c)
}

finalized_of :: proc(t: u32, dx: i8) -> (in_: toy.Inputs) {
	in_.present = {0}
	in_.input[0] = {
		dx = dx,
	}
	return
}

fake_finalized :: proc(f: ^Fake_Relay, first: u32, ticks: []toy.Inputs) {
	w := fake_begin(f, .Finalized)
	wire.w_u64(w, u64(f.now))
	wire.w_u64(w, 0)
	wire.w_u64(w, 0)
	wire.w_u32(w, 0) // input ack
	wire.w_u32(w, 0) // command ack
	wire.w_u32(w, first)
	wire.w_u8(w, u8(len(ticks)))
	for &tk in ticks {
		sim.inputs_write(w, &tk)
	}
	fake_send(f, .Unreliable)
}

// A Finalized datagram reordered by more than the ring (512 ticks) must not overwrite the slot a
// newer, not yet verified tick shares with it.
@(test)
stale_finalized_is_ignored :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	f: Fake_Relay
	fake_make(&f, hub)
	defer fake_destroy(&f)
	w: Watch
	c := netcode.client_create(
		&toy.GAME,
		{slot = -1, name = "c", quiet = true},
		netcode.loopback_link(hub, 1),
		hooks_for(&w),
	)
	defer netcode.client_destroy(c)
	defer delete(w.statuses)
	fake_welcome(&f, c)
	ref := sim.create(&toy.GAME, SEED)
	defer sim.destroy(ref)
	batch: [16]toy.Inputs
	for first := u32(1); first <= 600; first += 16 {
		for k in 0 ..< 16 {
			batch[k] = finalized_of(first + u32(k), 1)
			if first + u32(k) <= 600 {
				sim.step(ref, &batch[k])
			}
		}
		fake_finalized(&f, first, batch[:min(16, 601 - int(first))])
		fake_step(&f, c)
		fake_step(&f, c)
	}
	testing.expect_value(t, c.verified, 600)
	// Tick 601 arrives, then a copy of tick 89 delayed by 8 s: same ring slot (89 + 512 = 601).
	next := [1]toy.Inputs{finalized_of(601, 3)}
	stale := [1]toy.Inputs{finalized_of(89, -3)}
	sim.step(ref, &next[0])
	fake_finalized(&f, 601, next[:])
	fake_finalized(&f, 89, stale[:])
	fake_step(&f, c)
	fake_step(&f, c)
	testing.expect_value(t, c.verified, 601)
	testing.expect_value(t, c.fin_tick[601 % netcode.FIN_RING], 601)
	testing.expect_value(t, sim.checksum(c.sim), sim.checksum(ref))
}

// A raw datagram with reliable chunks of the given ids (1 byte each).
reliable_datagram :: proc(w: ^wire.Writer, epoch, seq: u32, ids: []u32) {
	clear(&w.buf)
	wire.w_u8(w, netcode.DGRAM_MAGIC)
	wire.w_u8(w, netcode.DGRAM_VERSION)
	wire.w_u32(w, epoch)
	wire.w_u32(w, 0)
	wire.w_u32(w, seq)
	wire.w_u32(w, 0)
	wire.w_u32(w, 0)
	wire.w_u16(w, u16(len(ids)))
	for id in ids {
		wire.w_u8(w, 1)
		wire.w_u32(w, id)
		wire.w_u16(w, 1)
		wire.w_u8(w, 0xEE)
	}
}

// A peer that sends reliable ids far ahead of the next expected one (never the next) cannot grow
// the receiver's out-of-order buffer past the window.
@(test)
reliable_reorder_buffer_is_bounded :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	ch := netcode.channel_make()
	defer netcode.channel_destroy(ch)
	netcode.channel_add_link(ch, netcode.loopback_link(hub, 0))
	raw := netcode.loopback_link(hub, 1)
	defer netcode.link_close(&raw)
	w := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(w.buf)
	ids: [100]u32
	for k in 0 ..< 50 {
		for i in 0 ..< 100 {
			ids[i] = u32(1 + k * 100 + i)
		}
		reliable_datagram(&w, 77, u32(k + 1), ids[:])
		netcode.link_send(&raw, 0, w.buf[:])
		netcode.channel_poll(ch, 1_000_000 + i64(k) * 1000)
	}
	testing.expectf(
		t,
		len(ch.conns[0].rel_early) < netcode.REL_WINDOW,
		"%d early messages buffered",
		len(ch.conns[0].rel_early),
	)
	// The missing id 0 releases what the window kept, in order.
	ids[0] = 0
	reliable_datagram(&w, 77, 51, ids[:1])
	netcode.link_send(&raw, 0, w.buf[:])
	evs := netcode.channel_poll(ch, 2_000_000)
	testing.expect_value(t, len(evs), netcode.REL_WINDOW)
	testing.expect_value(t, ch.conns[0].rel_next, netcode.REL_WINDOW)
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
		junk, jok := netcode.udp_connect(remote)
		testing.expect(t, jok)
		netcode.link_send(&junk, 0, garbage[:])
		netcode.link_close(&junk)
		cl, cok := netcode.udp_connect(remote)
		testing.expect(t, cok)
		client := netcode.channel_make()
		li := netcode.channel_add_link(client, cl)
		peer := netcode.channel_peer(client, li, 0)
		msg := [3]u8{u8(i), 0xAB, 0xCD}
		netcode.channel_send(client, peer, msg[:], .Reliable, netcode.now_us())
		netcode.channel_flush(client, netcode.now_us())
		got := netcode.Peer(-1)
		deadline := netcode.now_us() + 200_000
		for got < 0 && netcode.now_us() < deadline {
			for ev in netcode.channel_poll(server, netcode.now_us()) {
				if ev.kind == .Message && len(ev.data) == 3 && ev.data[0] == u8(i) {
					got = ev.peer
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
	ch := netcode.channel_make()
	defer netcode.channel_destroy(ch)
	li := netcode.channel_add_link(ch, netcode.loopback_link(hub, 0))
	peer := netcode.channel_peer(ch, li, 1)
	big: [netcode.MAX_MESSAGE + 4]u8
	testing.expect(t, !netcode.channel_send(ch, peer, big[:], .Reliable, 1_000))
	testing.expect(t, netcode.channel_send(ch, peer, big[:netcode.MAX_MESSAGE], .Reliable, 1_000))
}

// Another player can't feed a late joiner a snapshot the relay didn't ask it for.
@(test)
only_the_asked_provider_sends_snapshots :: proc(t: ^testing.T) {
	n: Rnet
	rnet_make(&n, 1, 0)
	defer rnet_destroy(&n)
	rnet_join(&n, 0)
	rnet_run(&n, 1)
	// An attacker takes slot 1 with a raw channel.
	evil := netcode.channel_make()
	defer netcode.channel_destroy(evil)
	li := netcode.channel_add_link(evil, netcode.loopback_link(n.hub, 7))
	ep := netcode.channel_peer(evil, li, 0)
	w := wire.writer_make(64)
	defer delete(w.buf)
	wire.w_u8(&w, u8(netcode.Msg.Hello))
	wire.w_u16(&w, netcode.PROTOCOL_VERSION)
	wire.w_u8(&w, netcode.ANY_SLOT)
	wire.w_u32(&w, 0)
	wire.w_u64(&w, sim.compat_of(&toy.GAME))
	wire.w_u8(&w, 0)
	netcode.channel_send(evil, ep, w.buf[:], .Reliable, n.clock.now)
	for _ in 0 ..< 20 {
		netcode.channel_flush(evil, n.clock.now)
		netcode.channel_poll(evil, n.clock.now)
		rnet_run(&n, 0.01)
	}
	testing.expect(t, n.relay.connected[1])
	joiner := rnet_join(&n)
	rnet_run(&n, 1, proc(n: ^Rnet) -> bool {return n.relay.provider[2] >= 0})
	testing.expect_value(t, n.relay.provider[2], 0)
	// The attacker sends a 5-byte "snapshot" for the joiner.
	clear(&w.buf)
	wire.w_u8(&w, u8(netcode.Msg.Snap_Begin))
	wire.w_u8(&w, 2)
	wire.w_u32(&w, n.relay.finalized)
	wire.w_u32(&w, 5)
	netcode.channel_send(evil, ep, w.buf[:], .Reliable, n.clock.now)
	clear(&w.buf)
	wire.w_u8(&w, u8(netcode.Msg.Snap_Chunk))
	wire.w_u8(&w, 2)
	wire.w_u32(&w, 0)
	wire.w_bytes(&w, {1, 2, 3, 4, 5})
	netcode.channel_send(evil, ep, w.buf[:], .Reliable, n.clock.now)
	for _ in 0 ..< 300 {
		netcode.channel_flush(evil, n.clock.now)
		netcode.channel_poll(evil, n.clock.now)
		rnet_run(&n, 0.01)
	}
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect(t, joiner.verified > joiner.first_tick)
}

// A build whose simulation differs (here: another sim version) is refused with "a different game build or level"
// instead of joining and desyncing; compat comes from the game by default.
@(test)
other_build_is_refused :: proc(t: ^testing.T) {
	n: Rnet
	rnet_make(&n, 1, 0)
	defer rnet_destroy(&n)
	rnet_join(&n, 0)
	rnet_run(&n, 1)
	other := toy.GAME
	other.version = "2"
	link := netcode.loopback_link(n.hub, 6)
	c := netcode.client_create(&other, {slot = -1, name = "other", quiet = true}, link, hooks_for(&n.watch[6]))
	append(&n.clients, c)
	rnet_run(&n, 1)
	testing.expect_value(t, c.status, netcode.Status.Failed)
	testing.expect_value(t, c.detail, "a different game build or level")
}
