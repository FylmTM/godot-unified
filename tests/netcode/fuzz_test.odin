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

// A valid client -> relay message of each kind, for mutation.
@(private = "file")
relay_samples :: proc(writer: ^wire.Writer, k: int, player: u8) -> []u8 {
	clear(&writer.buf)
	msg := netcode.Msg(1 + k % 13)
	wire.w_u8(writer, u8(msg))
	#partial switch msg {
	case .Hello:
		wire.w_u16(writer, netcode.PROTOCOL_VERSION)
		wire.w_u8(writer, netcode.ANY_PLAYER)
		wire.w_u32(writer, 0)
		wire.w_u64(writer, sim.compat_of(&toy.GAME))
		wire.w_bytes(writer, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}) // token
		wire.w_u8(writer, 3)
		wire.w_bytes(writer, {'b', 'o', 't'})
	case .Inputs:
		wire.w_u8(writer, player)
		wire.w_u64(writer, 1234)
		wire.w_u32(writer, 10)
		wire.w_u32(writer, 11)
		wire.w_u8(writer, 2)
		wire.w_bytes(writer, {0b0111, 1, 2, 3, 0b0111, 4, 5, 6}) // {1, 2, 3, 0} from zero, then {4, 5, 6, 0}
		// commands: seq 1, 2 (a bump for tick 11, a mark for tick 12)
		wire.w_u32(writer, 1)
		wire.w_u8(writer, 2)
		wire.w_u32(writer, 11)
		wire.w_u8(writer, 0)
		wire.w_u8(writer, size_of(toy.Cmd_Bump))
		wire.w_bytes(writer, {9, 0, 0, 0})
		wire.w_u32(writer, 12)
		wire.w_u8(writer, 1)
		wire.w_u8(writer, size_of(toy.Cmd_Mark))
		for i in 0 ..< size_of(toy.Cmd_Mark) {
			wire.w_u8(writer, u8(i))
		}
	case .Checksum:
		wire.w_u8(writer, player)
		wire.w_u32(writer, 32)
		wire.w_u64(writer, 99)
	case .Snap_Begin:
		wire.w_u8(writer, 0)
		wire.w_u32(writer, 40)
		wire.w_u32(writer, 3000)
	case .Snap_Chunk:
		wire.w_u8(writer, 0)
		wire.w_u32(writer, 0)
		wire.w_bytes(writer, {1, 2, 3, 4})
	case .Done:
		wire.w_u8(writer, player)
		wire.w_u32(writer, 64)
	}
	return writer.buf[:]
}

// A valid relay -> client message of each kind, for mutation.
@(private = "file")
client_samples :: proc(writer: ^wire.Writer, k: int) -> []u8 {
	clear(&writer.buf)
	msg := netcode.Msg(1 + k % 13)
	wire.w_u8(writer, u8(msg))
	#partial switch msg {
	case .Welcome:
		wire.w_u8(writer, 0)
		wire.w_u16(writer, 1)
		wire.w_u64(writer, SEED)
		wire.w_u16(writer, toy.HZ)
		wire.w_u32(writer, 0)
		wire.w_u32(writer, 1)
		wire.w_u8(writer, 0)
	case .Finalized:
		for _ in 0 ..< 3 {
			wire.w_u64(writer, 5000)
		}
		wire.w_u32(writer, 3) // input ack
		wire.w_u32(writer, 1) // command ack
		wire.w_u32(writer, 5)
		wire.w_u8(writer, 2)
		first := finalized_of(5, 1)
		netcode.window_write_tick(writer, &first, nil)
		inputs := finalized_of(6, 2)
		inputs.present = {0, 1}
		bump, _ := sim.command_make(toy.Cmd, toy.Cmd_Bump{3})
		sim.add_command(&inputs, bump)
		mark, _ := sim.command_make(toy.Cmd, toy.Cmd_Mark{count = 2})
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
	}
	return writer.buf[:]
}

// Raw datagrams (headers and chunk framing) from many link peers into a relay that also serves a
// real client; then the real session must still verify.
@(test)
fuzz_channel_datagrams :: proc(t: ^testing.T) {
	session: Rnet
	rnet_make(&session, 1, 0)
	defer rnet_destroy(&session)
	client := rnet_join(&session)
	rnet_run(&session, 1)
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
			rnet_run(&session, 0.001)
		}
	}
	rnet_run(&session, 2.5) // 4 s since Welcome, of which the relay's start lead (0.5 s) is before tick 1
	testing.expect_value(t, client.status, netcode.Status.Connected)
	testing.expect(t, client.verified > 3 * toy.HZ)
}

// Well-framed channel messages with malformed relay-protocol payloads, from clients that may be
// players; the relay must neither crash nor stop serving the honest client.
@(test)
fuzz_relay_messages :: proc(t: ^testing.T) {
	session: Rnet
	rnet_make(&session, 1, 0)
	defer rnet_destroy(&session)
	honest := rnet_join(&session, 0)
	rnet_run(&session, 1)
	fuzz := Fuzz{0x9E37_79B9}
	writer := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(writer.buf)
	buf: [dynamic]u8
	defer delete(buf)
	// Two attackers with channels of their own, each on its own hub endpoint.
	attackers: [2]^netcode.Channel
	peers: [2]netcode.Peer
	for &attacker, i in attackers {
		attacker = netcode.channel_make()
		link_index := netcode.channel_add_link(attacker, netcode.loopback_link(session.hub, netcode.Peer(6 + i)))
		peers[i] = netcode.channel_peer(attacker, link_index, 0)
	}
	defer for attacker in attackers {
		netcode.channel_destroy(attacker)
	}
	for k in 0 ..< 4000 {
		attacker_index := k % 2
		fuzz_bytes(&fuzz, &buf, relay_samples(&writer, fuzz_below(&fuzz, 13), u8(1 + attacker_index)))
		netcode.channel_send(
			attackers[attacker_index],
			peers[attacker_index],
			buf[:],
			fuzz_below(&fuzz, 2) == 0 ? .Reliable : .Unreliable,
			session.clock.now,
		)
		if k % 4 == 0 {
			for attacker in attackers {
				netcode.channel_flush(attacker, session.clock.now)
				netcode.channel_poll(attacker, session.clock.now)
			}
			rnet_run(&session, 0.002)
		}
	}
	rnet_run(&session, 3)
	testing.expect_value(t, honest.status, netcode.Status.Connected)
	testing.expect(t, honest.verified > 3 * toy.HZ)
}

// Malformed relay messages into a client (after a real Welcome); the client must not crash.
@(test)
fuzz_client_messages :: proc(t: ^testing.T) {
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
	fuzz := Fuzz{0xC0FF_EE11}
	writer := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(writer.buf)
	buf: [dynamic]u8
	defer delete(buf)
	for k in 0 ..< 4000 {
		fuzz_bytes(&fuzz, &buf, client_samples(&writer, fuzz_below(&fuzz, 13)))
		if fuzz_below(&fuzz, 13) == 0 {
			continue // keep End and Reject rare: they end the session early
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
	testing.expect(t, client.status != .Idle)
}
