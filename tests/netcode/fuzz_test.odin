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
	x: u32,
}

fz_next :: proc(f: ^Fuzz) -> u32 {
	f.x ~= f.x << 13
	f.x ~= f.x >> 17
	f.x ~= f.x << 5
	return f.x
}

fz_below :: proc(f: ^Fuzz, n: int) -> int {
	return int(fz_next(f) % u32(n))
}

// Random bytes, or a mutation of `valid` (a byte flipped, cut short, a field set to an extreme).
fz_bytes :: proc(f: ^Fuzz, out: ^[dynamic]u8, valid: []u8) {
	clear(out)
	switch fz_below(f, 4) {
	case 0:
		for _ in 0 ..< fz_below(f, 64) {
			append(out, u8(fz_next(f)))
		}
	case 1:
		append(out, ..valid)
		if len(out) > 0 {
			resize(out, fz_below(f, len(out)))
		}
	case:
		append(out, ..valid)
		for _ in 0 ..< 1 + fz_below(f, 4) {
			if len(out) == 0 {
				break
			}
			i := fz_below(f, len(out))
			switch fz_below(f, 3) {
			case 0:
				out[i] ~= u8(1 << u32(fz_below(f, 8)))
			case 1:
				out[i] = 0xFF
			case:
				out[i] = 0
			}
		}
		for _ in 0 ..< fz_below(f, 3) * fz_below(f, 400) {
			append(out, u8(fz_next(f))) // trailing junk, up to oversized chunks
		}
	}
}

// A valid client -> relay message of each kind, for mutation.
@(private = "file")
relay_samples :: proc(w: ^wire.Writer, k: int, slot: u8) -> []u8 {
	clear(&w.buf)
	m := netcode.Msg(1 + k % 13)
	wire.w_u8(w, u8(m))
	#partial switch m {
	case .Hello:
		wire.w_u16(w, netcode.PROTOCOL_VERSION)
		wire.w_u8(w, netcode.ANY_SLOT)
		wire.w_u32(w, 0)
		wire.w_u64(w, sim.compat_of(&toy.GAME))
		wire.w_u8(w, 3)
		wire.w_bytes(w, {'b', 'o', 't'})
	case .Inputs:
		wire.w_u8(w, slot)
		wire.w_u64(w, 1234)
		wire.w_u32(w, 10)
		wire.w_u32(w, 11)
		wire.w_u8(w, 2)
		wire.w_bytes(w, {1, 2, 3, 0, 4, 5, 6, 0})
		// commands: seq 1, 2 (a bump for tick 11, a mark for tick 12)
		wire.w_u32(w, 1)
		wire.w_u8(w, 2)
		wire.w_u32(w, 11)
		wire.w_u8(w, 0)
		wire.w_u8(w, size_of(toy.Cmd_Bump))
		wire.w_bytes(w, {9, 0, 0, 0})
		wire.w_u32(w, 12)
		wire.w_u8(w, 1)
		wire.w_u8(w, size_of(toy.Cmd_Mark))
		for b in 0 ..< size_of(toy.Cmd_Mark) {
			wire.w_u8(w, u8(b))
		}
	case .Checksum:
		wire.w_u8(w, slot)
		wire.w_u32(w, 32)
		wire.w_u64(w, 99)
	case .Snap_Begin:
		wire.w_u8(w, 0)
		wire.w_u32(w, 40)
		wire.w_u32(w, 3000)
	case .Snap_Chunk:
		wire.w_u8(w, 0)
		wire.w_u32(w, 0)
		wire.w_bytes(w, {1, 2, 3, 4})
	case .Done:
		wire.w_u8(w, slot)
		wire.w_u32(w, 64)
	}
	return w.buf[:]
}

// A valid relay -> client message of each kind, for mutation.
@(private = "file")
client_samples :: proc(w: ^wire.Writer, k: int) -> []u8 {
	clear(&w.buf)
	m := netcode.Msg(1 + k % 13)
	wire.w_u8(w, u8(m))
	#partial switch m {
	case .Welcome:
		wire.w_u8(w, 0)
		wire.w_u64(w, SEED)
		wire.w_u16(w, toy.HZ)
		wire.w_u32(w, 0)
		wire.w_u32(w, 1)
		wire.w_u8(w, 0)
	case .Finalized:
		for _ in 0 ..< 3 {
			wire.w_u64(w, 5000)
		}
		wire.w_u32(w, 3) // input ack
		wire.w_u32(w, 1) // command ack
		wire.w_u32(w, 5)
		wire.w_u8(w, 2)
		in_ := finalized_of(5, 1)
		sim.inputs_write(w, &in_)
		bump, _ := sim.command_make(toy.GAME.commands, toy.Cmd_Bump{3})
		sim.add_command(&in_, bump)
		mark, _ := sim.command_make(toy.GAME.commands, toy.Cmd_Mark{count = 2})
		mark.slot = 1
		sim.add_command(&in_, mark)
		sim.inputs_write(w, &in_)
	case .Snap_Request:
		wire.w_u8(w, 1)
		wire.w_u32(w, 3)
	case .Snap_Begin:
		wire.w_u8(w, 0)
		wire.w_u32(w, 10)
		wire.w_u32(w, 9)
	case .Snap_Chunk:
		wire.w_u8(w, 0)
		wire.w_u32(w, 0)
		wire.w_bytes(w, {'U', 'N', 'I', 'S', 2, 0, 0, 0, 1})
	case .Reject:
		wire.w_u8(w, 2)
	case .Roster:
		wire.w_u8(w, toy.SLOTS)
		for _ in 0 ..< toy.SLOTS {
			wire.w_u8(w, 1)
			wire.w_u8(w, 2)
			wire.w_bytes(w, {'h', 'i'})
		}
	}
	return w.buf[:]
}

// Raw datagrams (headers and chunk framing) from many link peers into a relay that also serves a
// real client; then the real session must still verify.
@(test)
fuzz_channel_datagrams :: proc(t: ^testing.T) {
	n: Rnet
	rnet_make(&n, 1, 0)
	defer rnet_destroy(&n)
	c := rnet_join(&n)
	rnet_run(&n, 1)
	f := Fuzz{0x1234_5678}
	w := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(w.buf)
	buf: [dynamic]u8
	defer delete(buf)
	raws: [4]netcode.Link
	for &r, i in raws {
		r = netcode.loopback_link(n.hub, netcode.Peer(4 + i))
	}
	defer for &r in raws {
		netcode.link_close(&r)
	}
	ids := [3]u32{0, 1, 600}
	for k in 0 ..< 4000 {
		reliable_datagram(&w, u32(k % 7 + 1), u32(k), ids[:1 + k % 3])
		fz_bytes(&f, &buf, w.buf[:])
		if len(buf) > netcode.MAX_DATAGRAM {
			resize(&buf, netcode.MAX_DATAGRAM)
		}
		netcode.link_send(&raws[k % 4], 0, buf[:])
		if k % 8 == 0 {
			rnet_run(&n, 0.001)
		}
	}
	rnet_run(&n, 2)
	testing.expect_value(t, c.status, netcode.Status.Connected)
	testing.expect(t, c.verified > 3 * toy.HZ)
}

// Well-framed channel messages with malformed relay-protocol payloads, from clients that may hold a
// slot; the relay must neither crash nor stop serving the honest client.
@(test)
fuzz_relay_messages :: proc(t: ^testing.T) {
	n: Rnet
	rnet_make(&n, 1, 0)
	defer rnet_destroy(&n)
	honest := rnet_join(&n, 0)
	rnet_run(&n, 1)
	f := Fuzz{0x9E37_79B9}
	w := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(w.buf)
	buf: [dynamic]u8
	defer delete(buf)
	// Two attackers with channels of their own, each on its own hub endpoint.
	attackers: [2]^netcode.Channel
	peers: [2]netcode.Peer
	for &a, i in attackers {
		a = netcode.channel_make()
		li := netcode.channel_add_link(a, netcode.loopback_link(n.hub, netcode.Peer(6 + i)))
		peers[i] = netcode.channel_peer(a, li, 0)
	}
	defer for a in attackers {
		netcode.channel_destroy(a)
	}
	for k in 0 ..< 4000 {
		i := k % 2
		fz_bytes(&f, &buf, relay_samples(&w, fz_below(&f, 13), u8(1 + i)))
		netcode.channel_send(
			attackers[i],
			peers[i],
			buf[:],
			fz_below(&f, 2) == 0 ? .Reliable : .Unreliable,
			n.clock.now,
		)
		if k % 4 == 0 {
			for a in attackers {
				netcode.channel_flush(a, n.clock.now)
				netcode.channel_poll(a, n.clock.now)
			}
			rnet_run(&n, 0.002)
		}
	}
	rnet_run(&n, 3)
	testing.expect_value(t, honest.status, netcode.Status.Connected)
	testing.expect(t, honest.verified > 3 * toy.HZ)
}

// Malformed relay messages into a client (after a real Welcome); the client must not crash.
@(test)
fuzz_client_messages :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	fr: Fake_Relay
	fake_make(&fr, hub)
	defer fake_destroy(&fr)
	wt: Watch
	c := netcode.client_create(
		&toy.GAME,
		{slot = -1, name = "c", quiet = true},
		netcode.loopback_link(hub, 1),
		hooks_for(&wt),
	)
	defer netcode.client_destroy(c)
	defer delete(wt.statuses)
	fake_welcome(&fr, c)
	f := Fuzz{0xC0FF_EE11}
	w := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(w.buf)
	buf: [dynamic]u8
	defer delete(buf)
	for k in 0 ..< 4000 {
		fz_bytes(&f, &buf, client_samples(&w, fz_below(&f, 13)))
		if fz_below(&f, 13) == 0 {
			continue // keep End and Reject rare: they end the session early
		}
		netcode.channel_send(fr.ch, fr.peer, buf[:], fz_below(&f, 2) == 0 ? .Reliable : .Unreliable, fr.now)
		if k % 4 == 0 {
			fake_step(&fr, c)
		}
	}
	for _ in 0 ..< 100 {
		fake_step(&fr, c)
	}
	testing.expect(t, c.status != .Idle)
}
