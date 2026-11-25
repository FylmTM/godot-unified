// Malformed-datagram fuzzing of every decoder that reads network bytes: the channel (datagram
// headers and chunks), the relay (client messages) and the client (relay messages). Seeded, so a
// failure reproduces; each run feeds a few thousand random and mutated inputs and then checks the
// session still works. Asserts and bounds checks are on in tests, so any unchecked read crashes.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"
import "unified:wire"

Fuzz :: struct {
	state: u32,
}

fuzz_next :: proc(fuzz: ^Fuzz) -> u32 {
	fuzz.state ~= fuzz.state << 13
	fuzz.state ~= fuzz.state >> 17
	fuzz.state ~= fuzz.state << 5
	return fuzz.state
}

fuzz_below :: proc(fuzz: ^Fuzz, bound: int) -> int {
	return int(fuzz_next(fuzz) % u32(bound))
}

// Random bytes, or a mutation of `valid` (a byte flipped, cut short, a field set to an extreme).
fuzz_bytes :: proc(fuzz: ^Fuzz, out: ^[dynamic]u8, valid: []u8) {
	clear(out)
	switch fuzz_below(fuzz, 4) {
	case 0:
		for _ in 0 ..< fuzz_below(fuzz, 64) {
			append(out, u8(fuzz_next(fuzz)))
		}
	case 1:
		append(out, ..valid)
		if len(out) > 0 {
			resize(out, fuzz_below(fuzz, len(out)))
		}
	case:
		append(out, ..valid)
		for _ in 0 ..< 1 + fuzz_below(fuzz, 4) {
			if len(out) == 0 {
				break
			}
			index := fuzz_below(fuzz, len(out))
			switch fuzz_below(fuzz, 3) {
			case 0:
				out[index] ~= u8(1 << u32(fuzz_below(fuzz, 8)))
			case 1:
				out[index] = 0xFF
			case:
				out[index] = 0
			}
		}
		for _ in 0 ..< fuzz_below(fuzz, 3) * fuzz_below(fuzz, 400) {
			append(out, u8(fuzz_next(fuzz))) // trailing junk, up to oversized chunks
		}
	}
}

// A valid client -> relay message of kind `msg`, for mutation, from a client holding `token` in a session that
// finalized `finalized`: inputs for the ticks after it (local player 0), a checksum of the checksum tick at or before
// it.
// A kind only the relay sends is its kind byte and a few bytes.
@(private = "file")
relay_sample :: proc(writer: ^wire.Writer, msg: netcode.Msg, token: netcode.Token, finalized: u32) -> []u8 {
	clear(&writer.buf)
	if msg == .Hello {
		hello := netcode.Hello {
			compat     = sim.compat_of(&toy.GAME),
			token      = token,
			seat_count = 1,
		}
		hello.seats[0] = {
			slot = netcode.ANY_SLOT,
			name = netcode.text_of(netcode.NAME_MAX, "bot"),
			profile = {len = size_of(toy.Profile)},
		}
		netcode.write_hello(writer, &hello)
		return writer.buf[:]
	}
	wire.w_u8(writer, u8(msg))
	#partial switch msg {
	case .Inputs:
		wire.w_u8(writer, 0) // local player 0
		wire.w_u32(writer, finalized) // finalized ack
		wire.w_u32(writer, finalized + 1)
		wire.w_u8(writer, 2)
		wire.w_bytes(writer, {0b0111, 1, 2, 3, 0b0111, 4, 5, 6}) // {1, 2, 3, 0} from zero, then {4, 5, 6, 0}
		// commands: seq 1, 2 (a bump for the first tick, a mark for the next)
		wire.w_u32(writer, 1)
		wire.w_u8(writer, 2)
		wire.w_u32(writer, finalized + 1)
		wire.w_u8(writer, 0)
		wire.w_u8(writer, size_of(toy.Command_Bump))
		wire.w_bytes(writer, {9, 0, 0, 0})
		wire.w_u32(writer, finalized + 2)
		wire.w_u8(writer, 1)
		wire.w_u8(writer, size_of(toy.Command_Mark))
		for i in 0 ..< size_of(toy.Command_Mark) {
			wire.w_u8(writer, u8(i))
		}
	case .Join:
		wire.w_u8(writer, 1 + u8(finalized % 3)) // another local player
		wire.w_u8(writer, netcode.ANY_SLOT)
		wire.w_u32(writer, 0) // as soon as possible
		wire.w_u8(writer, 3)
		wire.w_bytes(writer, {'b', 'o', 't'})
		wire.w_u8(writer, size_of(toy.Profile))
		for _ in 0 ..< size_of(toy.Profile) do wire.w_u8(writer, 0)
	case .Checksum:
		wire.w_u32(writer, max(finalized - finalized % 16, 16))
		wire.w_u64(writer, 99)
	case .Snap_Begin:
		wire.w_u8(writer, 0)
		wire.w_u32(writer, 40)
		wire.w_u32(writer, 3000)
	case .Snap_Chunk:
		wire.w_u8(writer, 0)
		wire.w_u32(writer, 0)
		wire.w_bytes(writer, {1, 2, 3, 4})
	case .Leave:
		wire.w_u8(writer, 1 + u8(finalized % 3)) // a local player beside local 0
	case .Done:
	case:
		wire.w_bytes(writer, {1, 2, 3, 4, 5, 6, 7, 8})
	}
	return writer.buf[:]
}

// A valid relay -> client message of each kind, for mutation (a kind only clients send: its kind byte and a few bytes).
@(private = "file")
client_samples :: proc(writer: ^wire.Writer, k: int) -> []u8 {
	clear(&writer.buf)
	msg := netcode.Msg(1 + k % len(netcode.Msg))
	if msg == .Welcome {
		write_test_welcome(writer, 0, 1, 1)
		return writer.buf[:]
	}
	wire.w_u8(writer, u8(msg))
	#partial switch msg {
	case .Finalized:
		write_finalized_head(writer, 5000, 5, 2, input_ack = 3, command_ack = 1)
		first := finalized_of(5, 1)
		netcode.window_write_tick(writer, &first, nil)
		inputs := finalized_of(6, 2)
		inputs.present = {0, 1}
		bump := sim.command_make(toy.Command, toy.Command_Bump{3})
		sim.add_command(&inputs, bump)
		mark := sim.command_make(toy.Command, toy.Command_Mark{count = 2})
		mark.slot = 1
		sim.add_command(&inputs, mark)
		netcode.window_write_tick(writer, &inputs, &first)
	case .Snap_Request:
		wire.w_u8(writer, 1)
		wire.w_u32(writer, 3)
	case .Snap_Begin:
		wire.w_u8(writer, 0)
		wire.w_u32(writer, 10)
		wire.w_u32(writer, 9)
	case .Snap_Chunk:
		wire.w_u8(writer, 0)
		wire.w_u32(writer, 0)
		wire.w_bytes(writer, {'U', 'N', 'I', 'S', 2, 0, 0, 0, 1})
	case .Reject:
		wire.w_u8(writer, 2)
	case .Roster:
		wire.w_u16(writer, 2) // member
		wire.w_u8(writer, 1) // slot
		wire.w_u8(writer, 1) // connected
		wire.w_u8(writer, 2)
		wire.w_bytes(writer, {'h', 'i'})
		wire.w_u8(writer, 3)
		wire.w_bytes(writer, {'e', 'o', 's'})
		wire.w_u8(writer, 2)
		wire.w_bytes(writer, {'a', 'b'})
	case .Snap_Ok:
		wire.w_u32(writer, 16)
	case .Desync:
		wire.w_u32(writer, 16)
		wire.w_u32(writer, 0b10) // slot 1
		wire.w_u16(writer, 2)
		wire.w_bytes(writer, {'h', 'p'})
	case .Seated:
		wire.w_u8(writer, 1) // local
		wire.w_u8(writer, 1) // slot
		wire.w_u16(writer, 3) // member
		wire.w_u32(writer, 20) // first tick
	case .Resync:
		wire.w_u32(writer, 16)
		wire.w_u32(writer, 100)
		wire.w_u8(writer, 1)
		wire.w_u8(writer, 0)
		wire.w_u32(writer, 0)
	case .Hello, .Inputs, .Checksum, .Done, .Leave, .Join:
		wire.w_bytes(writer, {1, 2, 3, 4, 5, 6, 7, 8})
	}
	return writer.buf[:]
}

// Raw datagrams (headers and chunk framing) from many link peers into a relay that also serves a
// real client; then the real session must still verify.
@(test)
fuzz_channel_datagrams :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	client := net_join(&session)
	net_run(&session, 1)
	fuzz := Fuzz{0x1234_5678}
	writer := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(writer.buf)
	buf: [dynamic]u8
	defer delete(buf)
	raws: [4]netcode.Link
	for &raw, i in raws {
		raw = netcode.loopback_link(session.hub, netcode.Peer(4 + i))
	}
	defer for &raw in raws {
		netcode.link_close(&raw)
	}
	ids := [3]u32{0, 1, 600}
	for k in 0 ..< 4000 {
		reliable_datagram(&writer, u32(k % 7 + 1), u32(k), ids[:1 + k % 3])
		fuzz_bytes(&fuzz, &buf, writer.buf[:])
		if len(buf) > netcode.MAX_DATAGRAM {
			resize(&buf, netcode.MAX_DATAGRAM)
		}
		netcode.link_send(&raws[k % 4], 0, buf[:])
		if k % 8 == 0 {
			net_run(&session, 0.001)
		}
	}
	net_run(&session, 2.5) // 4 s since Welcome, of which the relay's start lead (0.5 s) is before tick 1
	testing.expect_value(t, client.status, netcode.Status.Connected)
	testing.expect(t, client.verified > 3 * toy.HZ)
}

// A raw channel of a fuzzing client on hub endpoint `endpoint`, with its own token, and its peer number for the relay.
@(private = "file")
Attacker :: struct {
	channel:  ^netcode.Channel,
	peer:     netcode.Peer,
	endpoint: int,
	token:    netcode.Token,
}

// Opens a fresh connection for `attacker` (a new channel: a restarted program) and says an unmutated Hello on it.
@(private = "file")
attacker_hello :: proc(attacker: ^Attacker, session: ^Net, writer: ^wire.Writer) {
	if attacker.channel != nil do netcode.channel_destroy(attacker.channel)
	attacker.channel = netcode.channel_make()
	link := netcode.loopback_link(session.hub, netcode.Peer(attacker.endpoint))
	attacker.peer = netcode.channel_peer(attacker.channel, netcode.channel_add_link(attacker.channel, link), 0)
	hello := relay_sample(writer, .Hello, attacker.token, 0)
	netcode.channel_send(attacker.channel, attacker.peer, hello, .Reliable, session.clock.now)
}

// The relay's seats `attacker` holds (local 0's and its Joins').
@(private = "file")
attacker_seats :: proc(attacker: ^Attacker, session: ^Net) -> (seats: sim.Slots) {
	relay := session.relay
	for &seat, slot in relay.seats {
		if seat.conn >= 0 && relay.ch.conns[seat.conn].lpeer == netcode.Peer(attacker.endpoint) do seats += {slot}
	}
	return
}

// Well-framed channel messages with malformed relay-protocol payloads, from clients that are players: two attackers,
// each seated with an unmutated Hello and its own token (seated again on a fresh connection whenever a mangled message
// unseats it), send every other kind of message, as is or mangled; a third sends mangled Hellos. The relay must
// neither crash nor stop serving the honest client, and the fuzz must reach past the seated gate: an attacker's inputs
// are taken, and one of its Joins seats another local player.
@(test)
fuzz_relay_messages :: proc(t: ^testing.T) {
	context.logger.lowest_level = .Error // mangled checksums and snapshots warn by design
	session: Net
	net_make_relay(&session, 1, 0)
	defer net_destroy(&session)
	honest := net_join(&session, 0)
	net_run(&session, 1)
	fuzz := Fuzz{0x9E37_79B9}
	writer := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(writer.buf)
	buf: [dynamic]u8
	defer delete(buf)
	attackers: [3]Attacker
	for &attacker, i in attackers {
		attacker.endpoint = 5 + i
		attacker.token[0], attacker.token[1] = 0xA7, u8(i + 1)
		attacker_hello(&attacker, &session, &writer)
	}
	defer for attacker in attackers do netcode.channel_destroy(attacker.channel)
	inputs_taken, joins_seated := 0, 0
	for k in 0 ..< 4000 {
		attacker := &attackers[k % 3]
		msg := netcode.Msg(.Hello)
		if k % 3 != 2 {
			msg = netcode.Msg(2 + fuzz_below(&fuzz, len(netcode.Msg) - 1)) // anything but a Hello
		}
		sample := relay_sample(&writer, msg, attacker.token, session.relay.finalized)
		if fuzz_below(&fuzz, 3) == 0 {
			clear(&buf)
			append(&buf, ..sample) // as is
		} else {
			fuzz_bytes(&fuzz, &buf, sample)
		}
		netcode.channel_send(
			attacker.channel,
			attacker.peer,
			buf[:],
			fuzz_below(&fuzz, 2) == 0 ? .Reliable : .Unreliable,
			session.clock.now,
		)
		if k % 6 == 0 {
			for &other in attackers {
				netcode.channel_flush(other.channel, session.clock.now)
				netcode.channel_poll(other.channel, session.clock.now)
			}
			net_run(&session, 0.002)
			for &other in attackers[:2] {
				seats := attacker_seats(&other, &session)
				for slot in seats {
					seat := &session.relay.seats[slot]
					if seat.local != 0 do joins_seated += 1
					for tick in seat.input_tick do inputs_taken += int(tick != 0 && tick >= seat.active_from)
				}
				if seats == {} && k % 60 == 0 do attacker_hello(&other, &session, &writer) // unseated: back in
			}
		}
	}
	net_run(&session, 3)
	testing.expect_value(t, honest.status, netcode.Status.Connected)
	testing.expect(t, honest.verified > 3 * toy.HZ)
	testing.expectf(t, inputs_taken > 0, "no attacker's input was taken (on_inputs unreached)")
	testing.expectf(t, joins_seated > 0, "no attacker's Join seated a player (on_join unreached)")
}

// Malformed relay messages into a client (after a real Welcome); the client must not crash, and must still verify
// valid ticks after them.
@(test)
fuzz_client_messages :: proc(t: ^testing.T) {
	context.logger.lowest_level = .Error // mangled desync reports warn by design
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	fake: Fake_Relay
	fake_make(&fake, hub)
	defer fake_destroy(&fake)
	watch: Watch
	client := netcode.client_create(&toy.GAME, {}, netcode.loopback_link(hub, 1), hooks_for(&watch))
	defer netcode.client_destroy(client)
	defer delete(watch.statuses)
	fake_welcome(&fake, client)
	first := [1]toy.Inputs{finalized_of(1, 1)} // a running session: the client's clock is set from the relay's
	fake_finalized(&fake, 1, first[:])
	fake_step(&fake, client)
	fuzz := Fuzz{0xC0FF_EE11}
	writer := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(writer.buf)
	buf: [dynamic]u8
	defer delete(buf)
	for k in 0 ..< 4000 {
		fuzz_bytes(&fuzz, &buf, client_samples(&writer, fuzz_below(&fuzz, len(netcode.Msg))))
		// What ends the session or stops its verifying (End, Reject, a snapshot that does not load, a Resync whose
		// snapshot never comes) is left out, mangled or not: the client would ignore everything after it.
		if len(buf) > 0 {
			#partial switch netcode.Msg(buf[0]) {
			case .End, .Reject, .Snap_Begin, .Snap_Chunk, .Resync:
				continue
			}
		}
		netcode.channel_send(
			fake.channel,
			fake.peer,
			buf[:],
			fuzz_below(&fuzz, 2) == 0 ? .Reliable : .Unreliable,
			fake.now,
		)
		if k % 4 == 0 {
			fake_step(&fake, client)
		}
	}
	for _ in 0 ..< 100 {
		fake_step(&fake, client)
	}
	testing.expect_value(t, client.status, netcode.Status.Connected)
	// Still a working client: valid finalized ticks after the fuzz are verified.
	verified := client.verified
	batch: [16]toy.Inputs
	for first := verified + 1; first <= verified + 64; first += 16 {
		for k in 0 ..< 16 do batch[k] = finalized_of(first + u32(k), 1)
		fake_finalized(&fake, first, batch[:])
		fake_step(&fake, client)
		fake_step(&fake, client)
	}
	testing.expect_value(t, client.status, netcode.Status.Connected)
	testing.expectf(
		t,
		client.verified > verified,
		"verified %d before the valid ticks, %d after",
		verified,
		client.verified,
	)
}

// A joiner fed snapshots by a relay that may be hostile: Snap_Begins for different ticks in any order, chunks of two
// genuine snapshots, Finalized ticks and Snap_Oks, each sent as is or mangled. Whatever arrives, the joiner loads a
// snapshot, fails with a reason, or waits: never an assert (src/netcode/README.md: a crafted snapshot can do no more
// than fail to load). A client that failed is replaced by a new joiner.
@(test)
fuzz_joiner_snapshots :: proc(t: ^testing.T) {
	planted: Planted // the fault this test plants warns by design: counted here, not printed
	context.logger = planted_logger(&planted)
	JOIN_TICK :: 33
	// Genuine snapshots of checksum ticks 32 and 48 of the session the fake relay streams.
	simulation := sim.create(&toy.GAME, SEED)
	defer sim.destroy(simulation)
	snapshots: [2][]u8
	for tick in u32(1) ..= 48 {
		inputs := finalized_of(tick, 1)
		sim.step(simulation, &inputs)
		if tick % 16 == 0 && tick >= 32 do snapshots[tick / 16 - 2] = packed_snapshot(simulation, tick)
	}
	defer for snapshot in snapshots do delete(snapshot)
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	fake: Fake_Relay
	fake_make(&fake, hub)
	defer fake_destroy(&fake)
	watch: Watch
	defer delete(watch.statuses)
	join :: proc(fake: ^Fake_Relay, hub: ^netcode.Hub, watch: ^Watch) -> ^Client {
		client := netcode.client_create(&toy.GAME, {}, netcode.loopback_link(hub, 1), hooks_for(watch))
		fake.peer = -1
		for fake.peer < 0 {
			fake_step(fake, client)
		}
		clear(&fake.writer.buf)
		write_test_welcome(&fake.writer, 1, 2, JOIN_TICK) // slot 1, member 2, a joiner
		fake_send(fake)
		fake_step(fake, client)
		return client
	}
	client := join(&fake, hub, &watch)
	defer netcode.client_destroy(client)
	fuzz := Fuzz{0x5EED_CAFE}
	buf: [dynamic]u8
	defer delete(buf)
	loads, joiners := 0, 1
	for k in 0 ..< 4000 {
		which := fuzz_below(&fuzz, 2)
		snapshot := snapshots[which]
		tick := u32(32 + 16 * which)
		writer: ^wire.Writer
		switch fuzz_below(&fuzz, 5) {
		case 0:
			writer = fake_begin(&fake, .Snap_Begin)
			wire.w_u8(writer, 1)
			wire.w_u32(writer, tick)
			wire.w_u32(writer, u32(len(snapshot)))
		case 1, 2:
			offset := min(
				fuzz_below(&fuzz, 4) * netcode.SNAP_CHUNK,
				(len(snapshot) - 1) / netcode.SNAP_CHUNK * netcode.SNAP_CHUNK,
			)
			writer = fake_begin(&fake, .Snap_Chunk)
			wire.w_u8(writer, 1)
			wire.w_u32(writer, u32(offset))
			wire.w_bytes(writer, snapshot[offset:min(offset + netcode.SNAP_CHUNK, len(snapshot))])
		case 3:
			first := u32(16 + fuzz_below(&fuzz, 64))
			batch: [8]toy.Inputs
			for &inputs, i in batch do inputs = finalized_of(first + u32(i), 1)
			writer = fake_begin(&fake, .Finalized)
			write_finalized_head(writer, i64(fake.now), first, len(batch))
			for &inputs, i in batch do netcode.window_write_tick(writer, &inputs, i > 0 ? &batch[i - 1] : nil)
		case:
			writer = fake_begin(&fake, .Snap_Ok)
			wire.w_u32(writer, tick)
		}
		if fuzz_below(&fuzz, 2) == 0 {
			fuzz_bytes(&fuzz, &buf, writer.buf[:])
			fake_send_bytes(&fake, buf[:])
		} else {
			fake_send(&fake)
		}
		if k % 2 == 0 {
			fake_step(&fake, client)
		}
		if client.sim != nil && client.checking {
			loads += 1
		}
		if netcode.client_finished(client) {
			netcode.client_destroy(client)
			client = join(&fake, hub, &watch)
			joiners += 1
		}
	}
	testing.expectf(t, loads > 0 && joiners > 1, "%d snapshots loaded, %d joiners", loads, joiners)
	testing.expectf(t, planted.warnings > 0, "the planted fault warned of nothing")
}
