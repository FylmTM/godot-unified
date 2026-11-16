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

Relay :: netcode.Relay(toy.Input, toy.PLAYERS)

// A plain relay (no host player) and remote clients over loopback, on a virtual clock.
Rnet :: struct {
	clock:   netcode.Virtual_Clock,
	hub:     ^netcode.Hub,
	relay:   ^Relay,
	clients: [dynamic]^Client,
	watch:   [8]Watch,
}

rnet_make :: proc(session: ^Rnet, start_players: int, ticks: u32) {
	session.clock.now = 1_000_000
	session.hub = netcode.hub_create(8)
	config := netcode.Relay_Config {
		tick_hz       = toy.HZ,
		seed          = SEED,
		ticks         = ticks,
		start_players = start_players,
		compat        = sim.compat_of(&toy.GAME),
		name          = "relay",
		quiet         = true,
	}
	session.relay = netcode.relay_create(config, toy.Input, toy.PLAYERS)
	netcode.relay_add_link(session.relay, netcode.loopback_link(session.hub, 0))
}

// A client under the `wan` profile.
rnet_join :: proc(session: ^Rnet, player := -1, game: ^toy.Game = nil) -> ^Client {
	endpoint := len(session.clients) + 1
	link := netcode.netsim_wrap(
		netcode.loopback_link(session.hub, netcode.Peer(endpoint)),
		netcode.PROFILES[1],
		u32(endpoint) * 7919,
		&session.clock,
	)
	client := netcode.client_create(game != nil ? game : &toy.GAME, {
			slot  = player,
			name  = "c",
			quiet = true,
		}, link, hooks_for(&session.watch[endpoint]))
	append(&session.clients, client)
	return client
}

rnet_run :: proc(session: ^Rnet, seconds: f64, until: proc(session: ^Rnet) -> bool = nil) {
	end := session.clock.now + i64(seconds * 1e6)
	for session.clock.now < end {
		session.clock.now += 250
		netcode.relay_step(session.relay, session.clock.now)
		for client in session.clients {
			netcode.client_step(client, session.clock.now)
		}
		if until != nil && until(session) {
			return
		}
	}
}

rnet_destroy :: proc(session: ^Rnet) {
	for client in session.clients {
		netcode.client_destroy(client)
	}
	delete(session.clients)
	netcode.relay_destroy(session.relay)
	netcode.hub_destroy(session.hub)
	for &watch in session.watch {
		delete(watch.statuses)
	}
}

// Every pair of clients that verified a checksummed tick agrees on it.
rnet_agree :: proc(t: ^testing.T, session: ^Rnet) {
	for client in session.clients {
		for other in session.clients {
			for entry in client.checksums {
				for other_entry in other.checksums {
					if entry[0] == other_entry[0] {
						testing.expectf(
							t,
							entry[1] == other_entry[1],
							"players %d and %d disagree at tick %d",
							client.slot,
							other.slot,
							entry[0],
						)
					}
				}
			}
		}
	}
	testing.expect_value(t, session.relay.desyncs, 0)
}

// With nobody left in the session the relay must not finalize ahead of its clock: an endless host
// session whose players all leave (or whose own loopback peer times out) used to append ticks
// until the session length (forever when endless) in one step. A player who comes back is refused: nobody is
// left to send it a snapshot, and the relay keeps only its last RELAY_RING ticks (no replay from tick 0).
@(test)
relay_idles_when_everyone_left :: proc(t: ^testing.T) {
	session: Rnet
	rnet_make(&session, 1, 1_000_000)
	defer rnet_destroy(&session)
	client := rnet_join(&session)
	rnet_run(&session, 2)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	netcode.client_stop(client, session.clock.now)
	rnet_run(&session, 1)
	testing.expect_value(t, client.status, netcode.Status.Disconnected)
	testing.expect(t, !session.relay.connected[0])
	testing.expectf(
		t,
		session.relay.finalized <= session.relay.clock + 1,
		"finalized %d at clock %d",
		session.relay.finalized,
		session.relay.clock,
	)
	again := rnet_join(&session)
	rnet_run(&session, 2)
	testing.expect_value(t, again.status, netcode.Status.Failed)
	testing.expect_value(t, again.detail, "no player can send this player a snapshot")
	testing.expect(t, session.relay.finalized <= session.relay.clock + 1)
}

// The provider of a late joiner's snapshot leaves before sending it: the relay asks another player.
@(test)
snapshot_provider_leaves_another_steps_in :: proc(t: ^testing.T) {
	session: Rnet
	rnet_make(&session, 2, 0)
	defer rnet_destroy(&session)
	provider := rnet_join(&session, 0)
	bystander := rnet_join(&session, 1)
	rnet_run(&session, 2)
	joiner := rnet_join(&session)
	rnet_run(&session, 1, proc(session: ^Rnet) -> bool {return session.relay.provider[2] >= 0})
	testing.expect_value(t, session.relay.provider[2], 0) // the lowest player that can provide: provider
	netcode.client_stop(provider, session.clock.now)
	rnet_run(&session, 4)
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect_value(t, joiner.slot, 2)
	testing.expect(t, joiner.verified > joiner.first_tick)
	testing.expect_value(t, bystander.status, netcode.Status.Connected)
	rnet_agree(t, &session)
}

// ... and with nobody else to ask, the joiner is refused and its seat is free again.
@(test)
snapshot_provider_leaves_joiner_is_refused :: proc(t: ^testing.T) {
	session: Rnet
	rnet_make(&session, 1, 0)
	defer rnet_destroy(&session)
	provider := rnet_join(&session, 0)
	rnet_run(&session, 2)
	joiner := rnet_join(&session)
	rnet_run(&session, 1, proc(session: ^Rnet) -> bool {return session.relay.provider[1] >= 0})
	testing.expect_value(t, session.relay.provider[1], 0)
	netcode.client_stop(provider, session.clock.now)
	rnet_run(&session, 4)
	testing.expect_value(t, joiner.status, netcode.Status.Failed)
	testing.expect_value(t, joiner.detail, "no player can send this player a snapshot")
	testing.expect(t, !session.relay.connected[1])
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
	if tick == 1 do inputs.member[0] = 1 // the join record
	inputs.input[0] = {
		dx = dx,
	}
	return
}

fake_finalized :: proc(fake: ^Fake_Relay, first: u32, ticks: []toy.Inputs) {
	writer := fake_begin(fake, .Finalized)
	wire.w_u64(writer, u64(fake.now))
	wire.w_u64(writer, 0)
	wire.w_u64(writer, 0)
	wire.w_u32(writer, 0) // input ack
	wire.w_u32(writer, 0) // command ack
	wire.w_u32(writer, first)
	wire.w_u8(writer, u8(len(ticks)))
	for &tick_inputs, i in ticks {
		netcode.window_write_tick(writer, &tick_inputs, i > 0 ? &ticks[i - 1] : nil)
	}
	fake_send(fake, .Unreliable)
}

// A Finalized datagram reordered by more than the ring (512 ticks) must not overwrite the slot a
// newer, not yet verified tick shares with it.
@(test)
stale_finalized_is_ignored :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	fake: Fake_Relay
	fake_make(&fake, hub)
	defer fake_destroy(&fake)
	watch: Watch
	client := netcode.client_create(&toy.GAME, {
			slot  = -1,
			name  = "c",
			quiet = true,
		}, netcode.loopback_link(hub, 1), hooks_for(&watch))
	defer netcode.client_destroy(client)
	defer delete(watch.statuses)
	fake_welcome(&fake, client)
	reference := sim.create(&toy.GAME, SEED)
	defer sim.destroy(reference)
	batch: [16]toy.Inputs
	for first := u32(1); first <= 600; first += 16 {
		for k in 0 ..< 16 {
			batch[k] = finalized_of(first + u32(k), 1)
			if first + u32(k) <= 600 {
				sim.step(reference, &batch[k])
			}
		}
		fake_finalized(&fake, first, batch[:min(16, 601 - int(first))])
		fake_step(&fake, client)
		fake_step(&fake, client)
	}
	testing.expect_value(t, client.verified, 600)
	// Tick 601 arrives, then a copy of tick 89 delayed by 8 s: same ring slot (89 + 512 = 601).
	next := [1]toy.Inputs{finalized_of(601, 3)}
	stale := [1]toy.Inputs{finalized_of(89, -3)}
	sim.step(reference, &next[0])
	fake_finalized(&fake, 601, next[:])
	fake_finalized(&fake, 89, stale[:])
	fake_step(&fake, client)
	fake_step(&fake, client)
	testing.expect_value(t, client.verified, 601)
	testing.expect_value(t, client.fin_tick[601 % netcode.FIN_RING], 601)
	testing.expect_value(t, sim.checksum(client.sim), sim.checksum(reference))
}

// A raw datagram with reliable chunks of the given ids (1 byte each).
reliable_datagram :: proc(writer: ^wire.Writer, epoch, seq: u32, ids: []u32) {
	clear(&writer.buf)
	wire.w_u8(writer, netcode.DGRAM_MAGIC)
	wire.w_u8(writer, netcode.DGRAM_VERSION)
	wire.w_u32(writer, epoch)
	wire.w_u32(writer, 0)
	wire.w_u32(writer, seq)
	wire.w_u32(writer, 0)
	wire.w_u32(writer, 0)
	wire.w_u16(writer, u16(len(ids)))
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
	session: Rnet
	rnet_make(&session, 1, 0)
	defer rnet_destroy(&session)
	rnet_join(&session, 0)
	rnet_run(&session, 1)
	// An attacker takes player 1 with a raw channel.
	evil := netcode.channel_make()
	defer netcode.channel_destroy(evil)
	link_index := netcode.channel_add_link(evil, netcode.loopback_link(session.hub, 7))
	evil_peer := netcode.channel_peer(evil, link_index, 0)
	writer := wire.writer_make(64)
	defer delete(writer.buf)
	wire.w_u8(&writer, u8(netcode.Msg.Hello))
	wire.w_u16(&writer, netcode.PROTOCOL_VERSION)
	wire.w_u8(&writer, netcode.ANY_PLAYER)
	wire.w_u32(&writer, 0)
	wire.w_u64(&writer, sim.compat_of(&toy.GAME))
	wire.w_bytes(&writer, make([]u8, netcode.TOKEN_SIZE, context.temp_allocator))
	wire.w_u8(&writer, 0)
	netcode.channel_send(evil, evil_peer, writer.buf[:], .Reliable, session.clock.now)
	for _ in 0 ..< 20 {
		netcode.channel_flush(evil, session.clock.now)
		netcode.channel_poll(evil, session.clock.now)
		rnet_run(&session, 0.01)
	}
	testing.expect(t, session.relay.connected[1])
	joiner := rnet_join(&session)
	rnet_run(&session, 1, proc(session: ^Rnet) -> bool {return session.relay.provider[2] >= 0})
	testing.expect_value(t, session.relay.provider[2], 0)
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
		rnet_run(&session, 0.01)
	}
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	testing.expect(t, joiner.verified > joiner.first_tick)
}

// A build whose simulation differs (here: another sim version) is refused with "a different game build or level"
// instead of joining and desyncing; compat comes from the game by default.
@(test)
other_build_is_refused :: proc(t: ^testing.T) {
	session: Rnet
	rnet_make(&session, 1, 0)
	defer rnet_destroy(&session)
	rnet_join(&session, 0)
	rnet_run(&session, 1)
	other := toy.GAME
	other.version = "2"
	link := netcode.loopback_link(session.hub, 6)
	client := netcode.client_create(&other, {
			slot  = -1,
			name  = "other",
			quiet = true,
		}, link, hooks_for(&session.watch[6]))
	append(&session.clients, client)
	rnet_run(&session, 1)
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
		session: Rnet
		rnet_make(&session, 1, 0)
		defer rnet_destroy(&session)
		rnet_join(&session, 0)
		rnet_run(&session, 1)
		link := netcode.loopback_link(session.hub, 6)
		client := netcode.client_create(&toy.GAME, {
				slot   = -1,
				name   = "other",
				quiet  = true,
				compat = compat,
			}, link, hooks_for(&session.watch[6]))
		append(&session.clients, client)
		rnet_run(&session, 1)
		testing.expectf(t, client.status == .Failed, "build %d: %v", i, client.status)
		testing.expect_value(t, client.detail, "a different game build or level")
	}
}
