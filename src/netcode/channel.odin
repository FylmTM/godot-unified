// The transport interface (CORE.md §2): send(peer, bytes, unreliable|reliable), poll() -> events,
// connect/disconnect events. It runs the same minimal reliability protocol over any link:
//
//   datagram = u8 magic, u8 version, u32 seq, u32 ack, u32 ack_bits, u16 chunk count, chunks
//   chunk    = u8 kind (0 unreliable, 1 reliable), [u32 message id if reliable], u16 len, bytes
//
// Every datagram acks the peer's latest sequence number plus a 32-bit history. A reliable message
// rides in datagrams until one of them is acked, and is resent after a timeout derived from the
// measured RTT. Reliable messages are delivered once, in order. Unreliable ones are delivered as
// they arrive (possibly duplicated or reordered by the network).
package netcode

import "core:fmt"
import "core:time"

import "../wire"

Delivery :: enum u8 {
	Unreliable,
	Reliable,
}

Event_Kind :: enum u8 {
	Connected,
	Disconnected,
	Message,
}

Event :: struct {
	kind: Event_Kind,
	peer: Peer,
	data: []u8, // temp-allocated; valid until the caller frees the temp allocator
}

MAX_PEERS :: 16
SENT_RING :: 1024
MAX_IDS_PER_PACKET :: 64
FLUSH_BUDGET :: 96 * 1024 // reliable bytes per peer per flush
DISCONNECT_US :: 10_000_000
KEEPALIVE_US :: 250_000
DGRAM_MAGIC :: 0xA7
DGRAM_VERSION :: 1
HEADER_BYTES :: 16

Channel :: struct {
	link:   Link,
	conns:  [MAX_PEERS]Conn,
	events: [dynamic]Event,
	rx:     [MAX_DATAGRAM]u8,
	stats:  Channel_Stats,
}

Channel_Stats :: struct {
	datagrams_sent, datagrams_recv, bytes_sent, bytes_recv, resends: int,
}

Rel_Msg :: struct {
	id:        u32,
	data:      []u8,
	last_sent: i64, // µs; 0 = never sent
	acked:     bool,
}

Sent_Packet :: struct {
	seq:   u32,
	valid: bool,
	at:    i64,
	n_ids: int,
	ids:   [MAX_IDS_PER_PACKET]u32,
}

Conn :: struct {
	active:      bool,
	last_recv:   i64,
	last_sent:   i64,
	// send side
	next_seq:    u32,
	sent:        [SENT_RING]Sent_Packet,
	rel_out:     [dynamic]Rel_Msg,
	next_rel_id: u32,
	unrel_out:   [dynamic][]u8,
	srtt_us:     f64,
	// receive side
	have_recv:   bool,
	recv_max:    u32,
	recv_bits:   u32,
	ack_pending: bool,
	rel_next:    u32,
	rel_early:   map[u32][]u8,
}

channel_make :: proc(link: Link) -> ^Channel {
	ch := new(Channel)
	ch.link = link
	return ch
}

channel_destroy :: proc(ch: ^Channel) {
	for &c in ch.conns {
		conn_reset(&c)
	}
	delete(ch.events)
	link_close(&ch.link)
	free(ch)
}

@(private)
conn_reset :: proc(c: ^Conn) {
	for m in c.rel_out {
		delete(m.data)
	}
	delete(c.rel_out)
	for b in c.unrel_out {
		delete(b)
	}
	delete(c.unrel_out)
	for _, b in c.rel_early {
		delete(b)
	}
	delete(c.rel_early)
	c^ = {}
}

@(private)
conn_open :: proc(ch: ^Channel, peer: Peer, now: i64) -> ^Conn {
	c := &ch.conns[peer]
	if !c.active {
		conn_reset(c)
		c.active = true
		c.last_recv = now
		c.next_seq = 1
		c.srtt_us = 100_000
		append(&ch.events, Event{kind = .Connected, peer = peer})
	}
	return c
}

// Queues a message; it goes out on the next flush.
channel_send :: proc(ch: ^Channel, peer: Peer, data: []u8, d: Delivery) {
	if int(peer) < 0 || int(peer) >= MAX_PEERS {
		return
	}
	c := conn_open(ch, peer, now_us())
	assert(len(data) <= MAX_DATAGRAM - HEADER_BYTES - 7)
	if d == .Reliable {
		append(&c.rel_out, Rel_Msg{id = c.next_rel_id, data = clone_bytes(data)})
		c.next_rel_id += 1
	} else {
		append(&c.unrel_out, clone_bytes(data))
	}
}

// True when every reliable message to `peer` has been acknowledged.
channel_idle :: proc(ch: ^Channel, peer: Peer) -> bool {
	return len(ch.conns[peer].rel_out) == 0
}

channel_rtt_us :: proc(ch: ^Channel, peer: Peer) -> f64 {
	return ch.conns[peer].srtt_us
}

// Receives everything pending and returns the events (valid until the temp allocator is freed).
channel_poll :: proc(ch: ^Channel) -> []Event {
	clear(&ch.events)
	now := now_us()
	for {
		n, from, ok := link_recv(&ch.link, ch.rx[:])
		if !ok {
			break
		}
		if int(from) < 0 || int(from) >= MAX_PEERS {
			continue
		}
		handle_datagram(ch, from, ch.rx[:n], now)
	}
	for &c, i in ch.conns {
		if c.active && now - c.last_recv > DISCONNECT_US {
			conn_reset(&c)
			append(&ch.events, Event{kind = .Disconnected, peer = Peer(i)})
		}
	}
	return ch.events[:]
}

@(private)
seq_acked :: proc(c: ^Conn, seq: u32, now: i64) {
	sp := &c.sent[seq % SENT_RING]
	if !sp.valid || sp.seq != seq {
		return
	}
	sp.valid = false
	sample := f64(now - sp.at)
	c.srtt_us += (sample - c.srtt_us) * 0.125
	for k in 0 ..< sp.n_ids {
		id := sp.ids[k]
		for &m in c.rel_out {
			if m.id == id {
				m.acked = true
				break
			}
		}
	}
}

@(private)
handle_datagram :: proc(ch: ^Channel, from: Peer, bytes: []u8, now: i64) {
	r := wire.reader_make(bytes)
	if wire.r_u8(&r) != DGRAM_MAGIC || wire.r_u8(&r) != DGRAM_VERSION {
		return
	}
	seq := wire.r_u32(&r)
	ack := wire.r_u32(&r)
	ack_bits := wire.r_u32(&r)
	n_chunks := int(wire.r_u16(&r))
	if !r.ok {
		return
	}
	ch.stats.datagrams_recv += 1
	ch.stats.bytes_recv += len(bytes)
	c := conn_open(ch, from, now)
	c.last_recv = now

	// Our sequence numbers that the peer has received.
	if ack != 0 {
		seq_acked(c, ack, now)
		for b in 0 ..< u32(32) {
			if ack_bits & (1 << b) != 0 && ack > b + 1 {
				seq_acked(c, ack - b - 1, now)
			}
		}
		// Drop the acknowledged prefix of the reliable queue.
		k := 0
		for k < len(c.rel_out) && c.rel_out[k].acked {
			delete(c.rel_out[k].data)
			k += 1
		}
		if k > 0 {
			remove_range(&c.rel_out, 0, k)
		}
	}

	// Record the peer's sequence number for our acks.
	if !c.have_recv || seq > c.recv_max {
		shift := c.have_recv ? seq - c.recv_max : 33
		c.recv_bits = shift >= 32 ? 0 : (c.recv_bits << shift)
		if c.have_recv && shift <= 32 {
			c.recv_bits |= 1 << (shift - 1)
		}
		c.recv_max = seq
		c.have_recv = true
	} else if seq < c.recv_max && c.recv_max - seq <= 32 {
		c.recv_bits |= 1 << (c.recv_max - seq - 1)
	}

	for _ in 0 ..< n_chunks {
		kind := wire.r_u8(&r)
		id: u32
		if kind == 1 {
			id = wire.r_u32(&r)
		}
		data := wire.r_bytes(&r, int(wire.r_u16(&r)))
		if !r.ok {
			return
		}
		if kind == 0 {
			append(&ch.events, Event{kind = .Message, peer = from, data = clone_bytes(data, context.temp_allocator)})
			continue
		}
		c.ack_pending = true
		if id < c.rel_next {
			continue // duplicate
		}
		if id > c.rel_next {
			if id not_in c.rel_early {
				c.rel_early[id] = clone_bytes(data)
			}
			continue
		}
		append(&ch.events, Event{kind = .Message, peer = from, data = clone_bytes(data, context.temp_allocator)})
		c.rel_next += 1
		for {
			b, ok := c.rel_early[c.rel_next]
			if !ok {
				break
			}
			append(&ch.events, Event{kind = .Message, peer = from, data = clone_bytes(b, context.temp_allocator)})
			delete(b)
			delete_key(&c.rel_early, c.rel_next)
			c.rel_next += 1
		}
	}
}

@(private)
Packet_Builder :: struct {
	w:     wire.Writer,
	count: int,
	sp:    Sent_Packet,
}

@(private)
begin_packet :: proc(pb: ^Packet_Builder, c: ^Conn) {
	clear(&pb.w.buf)
	pb.count = 0
	pb.sp = {}
	wire.w_u8(&pb.w, DGRAM_MAGIC)
	wire.w_u8(&pb.w, DGRAM_VERSION)
	wire.w_u32(&pb.w, c.next_seq)
	wire.w_u32(&pb.w, c.have_recv ? c.recv_max : 0)
	wire.w_u32(&pb.w, c.recv_bits)
	wire.w_u16(&pb.w, 0) // chunk count, patched in end_packet
}

@(private)
end_packet :: proc(ch: ^Channel, pb: ^Packet_Builder, c: ^Conn, peer: Peer, now: i64) {
	pb.w.buf[14] = u8(pb.count)
	pb.w.buf[15] = u8(pb.count >> 8)
	sp := &c.sent[c.next_seq % SENT_RING]
	sp^ = pb.sp
	sp.seq = c.next_seq
	sp.valid = true
	sp.at = now
	c.next_seq += 1
	c.last_sent = now
	c.ack_pending = false
	link_send(&ch.link, peer, pb.w.buf[:])
	ch.stats.datagrams_sent += 1
	ch.stats.bytes_sent += len(pb.w.buf)
}

// Sends everything queued, plus due resends and pending acks, as datagrams.
channel_flush :: proc(ch: ^Channel) {
	now := now_us()
	pb := Packet_Builder {
		w = wire.writer_make(MAX_DATAGRAM, context.temp_allocator),
	}
	for &c, i in ch.conns {
		if !c.active {
			continue
		}
		peer := Peer(i)
		rto := i64(clamp(c.srtt_us * 1.5 + 15_000, 30_000, 500_000))
		begin_packet(&pb, &c)
		fits :: proc(pb: ^Packet_Builder, n: int) -> bool {
			return len(pb.w.buf) + n <= MAX_DATAGRAM
		}
		for b in c.unrel_out {
			if !fits(&pb, 3 + len(b)) {
				end_packet(ch, &pb, &c, peer, now)
				begin_packet(&pb, &c)
			}
			wire.w_u8(&pb.w, 0)
			wire.w_u16(&pb.w, u16(len(b)))
			wire.w_bytes(&pb.w, b)
			pb.count += 1
			delete(b)
		}
		clear(&c.unrel_out)
		budget := FLUSH_BUDGET
		for &m in c.rel_out {
			if m.acked || (m.last_sent != 0 && now - m.last_sent < rto) {
				continue
			}
			if budget <= 0 {
				break
			}
			if !fits(&pb, 7 + len(m.data)) || pb.sp.n_ids == MAX_IDS_PER_PACKET {
				end_packet(ch, &pb, &c, peer, now)
				begin_packet(&pb, &c)
			}
			if m.last_sent != 0 {
				ch.stats.resends += 1
			}
			wire.w_u8(&pb.w, 1)
			wire.w_u32(&pb.w, m.id)
			wire.w_u16(&pb.w, u16(len(m.data)))
			wire.w_bytes(&pb.w, m.data)
			pb.count += 1
			pb.sp.ids[pb.sp.n_ids] = m.id
			pb.sp.n_ids += 1
			m.last_sent = now
			budget -= len(m.data)
		}
		// Data, a pending ack, or a keepalive so idle peers (e.g. waiting for the start) stay connected.
		if pb.count > 0 || (c.ack_pending && now - c.last_sent > 5_000) || now - c.last_sent > KEEPALIVE_US {
			end_packet(ch, &pb, &c, peer, now)
		}
	}
}

channel_stats_json :: proc(ch: ^Channel) -> string {
	s := ch.stats
	return fmt.tprintf(
		`{{"datagrams_sent":%d,"datagrams_recv":%d,"bytes_sent":%d,"bytes_recv":%d,"resends":%d}}`,
		s.datagrams_sent,
		s.datagrams_recv,
		s.bytes_sent,
		s.bytes_recv,
		s.resends,
	)
}

sleep_ms :: proc(ms: int) {
	time.sleep(time.Duration(ms) * time.Millisecond)
}
