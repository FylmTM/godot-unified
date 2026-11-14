// The transport interface (src/netcode/SPEC.md): send(peer, bytes, unreliable|reliable), poll() -> events,
// connect/disconnect events. A channel multiplexes any number of links (the relay serves its host's
// in-process client and remote peers at once) and numbers every (link, link peer) pair as one
// channel Peer. It runs the same minimal reliability protocol over every link:
//
//   datagram = u8 magic, u8 version, u32 epoch, u32 peer epoch, u32 seq, u32 ack, u32 ack_bits,
//              u16 chunk count, chunks
//   chunk    = u8 kind (0 unreliable, 1 reliable), [u32 message id if reliable], u16 len, bytes
//
// Every datagram acks the peer's latest sequence number plus a 32-bit history. A reliable message
// rides in datagrams until one of them is acked, and is resent after a timeout derived from the
// measured RTT. Reliable messages are delivered once, in order. Unreliable ones are delivered as
// they arrive (possibly duplicated or reordered by the network). A sender keeps at most REL_WINDOW
// reliable messages in flight past its oldest unacked one, and a receiver drops anything further
// ahead, so a peer cannot grow the out-of-order buffer at will. A datagram whose header doesn't
// validate never gets a connection (or a transport peer number).
//
// Epochs keep both sides on the same incarnation of a connection. `epoch` is the sender's (a fresh
// value each time a side opens the connection), `peer epoch` echoes the receiver's last one seen
// (0: none yet). A datagram echoing an epoch other than ours was meant for an earlier connection:
// it is dropped unread while a newer connection runs, and otherwise answered by a new connection,
// whose epoch ends the sender's stale side at once, so no side sits half-open. A new epoch from an
// active peer means it started over (a restarted program on the same address, e.g. a rejoining
// player): the old connection ends with Disconnected and the datagram opens the new one.
package netcode

import "base:runtime"
import "core:fmt"

import "unified:wire"

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
	data: []u8, // valid until the next channel_poll
}

MAX_PEERS :: 32
SENT_RING :: 1024 // per active connection, allocated when it opens
MAX_IDS_PER_PACKET :: 64
REL_WINDOW :: 512 // reliable messages in flight past the oldest unacked one
FLUSH_BUDGET :: 96 * 1024 // reliable bytes per peer per flush
DISCONNECT_US :: 10_000_000
KEEPALIVE_US :: 250_000
DGRAM_MAGIC :: 0xA7
DGRAM_VERSION :: 2
HEADER_BYTES :: 24
CHUNK_OVERHEAD :: 7 // kind u8, id u32, len u16
MAX_MESSAGE :: MAX_DATAGRAM - HEADER_BYTES - CHUNK_OVERHEAD // the largest message channel_send takes

Channel :: struct {
	links:  [dynamic]Link,
	conns:  [MAX_PEERS]Conn,
	events: [dynamic]Event,
	rx:     [MAX_DATAGRAM]u8,
	stats:  Channel_Stats,
	arena:  runtime.Arena, // event payloads, reset by each poll
	tx:     wire.Writer,
	epochs: u32, // seeds the epoch of each connection this channel opens
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
	at:    i64,
	seq:   u32,
	n_ids: u16,
	valid: bool,
	ids:   [MAX_IDS_PER_PACKET]u32,
}

Conn :: struct {
	used:        bool, // the (link, lpeer) mapping is assigned
	link:        int,
	lpeer:       Peer,
	active:      bool,
	epoch:       u32, // ours, sent in every datagram
	peer_epoch:  u32, // theirs (0: none seen yet)
	last_recv:   i64,
	last_sent:   i64,
	// send side
	next_seq:    u32,
	sent:        []Sent_Packet, // SENT_RING records while active, nil otherwise
	rel_out:     [dynamic]Rel_Msg,
	next_rel_id: u32,
	unrel_out:   [dynamic][]u8,
	srtt_us:     f64,
	rtt_last_us: f64, // the latest round-trip sample (valid once rtt_seen)
	rtt_seen:    bool,
	// receive side
	have_recv:   bool,
	recv_max:    u32,
	recv_bits:   u32,
	ack_pending: bool,
	rel_next:    u32,
	rel_early:   map[u32][]u8, // ids rel_next+1 ..< rel_next+REL_WINDOW that arrived early
}

channel_make :: proc() -> ^Channel {
	ch := new(Channel)
	ch.tx = wire.writer_make(MAX_DATAGRAM)
	// Distinct per process run and channel, so a restarted program never reuses its old epochs.
	ch.epochs = u32(now_us()) ~ u32(uintptr(ch) >> 4)
	return ch
}

// Adds a link; the channel owns it from now on (closed by channel_destroy). Returns its index.
channel_add_link :: proc(ch: ^Channel, link: Link) -> int {
	append(&ch.links, link)
	return len(ch.links) - 1
}

channel_destroy :: proc(ch: ^Channel) {
	for &c in ch.conns {
		conn_reset(&c)
	}
	delete(ch.events)
	for &l in ch.links {
		link_close(&l)
	}
	delete(ch.links)
	delete(ch.tx.buf)
	runtime.arena_destroy(&ch.arena)
	free(ch)
}

// The channel Peer for a link's peer, assigning one on first use (-1 when all are taken).
channel_peer :: proc(ch: ^Channel, link: int, lpeer: Peer) -> Peer {
	if p := channel_find(ch, link, lpeer); p >= 0 {
		return p
	}
	free_slot := -1
	for &c, i in ch.conns {
		if !c.used {
			free_slot = i
			break
		}
	}
	if free_slot < 0 {
		return -1
	}
	c := &ch.conns[free_slot]
	c^ = {}
	c.used = true
	c.link = link
	c.lpeer = lpeer
	return Peer(free_slot)
}

// The channel Peer already assigned to a link's peer, or -1.
@(private)
channel_find :: proc(ch: ^Channel, link: int, lpeer: Peer) -> Peer {
	for &c, i in ch.conns {
		if c.used && c.link == link && c.lpeer == lpeer {
			return Peer(i)
		}
	}
	return -1
}

// Forgets a peer at once (no Disconnected event): after it said goodbye.
channel_drop :: proc(ch: ^Channel, peer: Peer) {
	if int(peer) >= 0 && int(peer) < MAX_PEERS {
		conn_release(ch, peer)
	}
}

// Ends a connection and frees its mapping, telling the link it may reuse the peer number.
@(private)
conn_release :: proc(ch: ^Channel, peer: Peer) {
	c := &ch.conns[peer]
	used, link, lpeer := c.used, c.link, c.lpeer
	conn_reset(c)
	if used {
		link_forget(&ch.links[link], lpeer)
	}
}

@(private)
arena_bytes :: proc(ch: ^Channel, b: []u8) -> []u8 {
	return clone_bytes(b, runtime.arena_allocator(&ch.arena))
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
	delete(c.sent)
	c^ = {}
}

@(private)
conn_open :: proc(ch: ^Channel, peer: Peer, now: i64) -> ^Conn {
	c := &ch.conns[peer]
	if !c.active {
		link, lpeer := c.link, c.lpeer
		conn_reset(c)
		c.used = true
		c.link = link
		c.lpeer = lpeer
		c.active = true
		c.sent = make([]Sent_Packet, SENT_RING)
		c.last_recv = now
		c.next_seq = 1
		c.srtt_us = 100_000
		ch.epochs += 1
		c.epoch = max(mix32(ch.epochs), 1)
		append(&ch.events, Event{kind = .Connected, peer = peer})
	}
	return c
}

// A bijective 32-bit mix (murmur3's finalizer): consecutive counters give unrelated epochs.
@(private)
mix32 :: proc(x: u32) -> u32 {
	h := x
	h ~= h >> 16
	h *= 0x85EBCA6B
	h ~= h >> 13
	h *= 0xC2B2AE35
	h ~= h >> 16
	return h
}

// Queues a message; it goes out on the next flush. A message longer than MAX_MESSAGE, or to a peer
// without a mapping, is dropped (false): never an assert, the bytes may come from the network.
channel_send :: proc(ch: ^Channel, peer: Peer, data: []u8, d: Delivery, now: i64) -> bool {
	if int(peer) < 0 || int(peer) >= MAX_PEERS || !ch.conns[peer].used || len(data) > MAX_MESSAGE {
		return false
	}
	c := conn_open(ch, peer, now)
	if d == .Reliable {
		append(&c.rel_out, Rel_Msg{id = c.next_rel_id, data = clone_bytes(data)})
		c.next_rel_id += 1
	} else {
		append(&c.unrel_out, clone_bytes(data))
	}
	return true
}

// The latest round-trip sample to `peer` (a datagram sent until its ack arrived; ok = false before the first ack).
// Every datagram is acked within a few ms, so from the first answer on it is a fresh measure of the path.
channel_rtt :: proc(ch: ^Channel, peer: Peer) -> (us: f64, ok: bool) {
	if int(peer) < 0 || int(peer) >= MAX_PEERS || !ch.conns[peer].active || !ch.conns[peer].rtt_seen {
		return 0, false
	}
	return ch.conns[peer].rtt_last_us, true
}

// True when every reliable message to `peer` has been acknowledged.
channel_idle :: proc(ch: ^Channel, peer: Peer) -> bool {
	return len(ch.conns[peer].rel_out) == 0
}

// Receives everything pending on every link and returns the events (valid until the next poll).
channel_poll :: proc(ch: ^Channel, now: i64) -> []Event {
	clear(&ch.events)
	runtime.arena_free_all(&ch.arena)
	for &l, li in ch.links {
		if l.event != nil {
			for {
				lp, kind, ok := l.event(l.data)
				if !ok {
					break
				}
				peer := channel_find(ch, li, lp)
				if kind == .Disconnected && peer >= 0 && ch.conns[peer].active {
					conn_release(ch, peer)
					append(&ch.events, Event{kind = .Disconnected, peer = peer})
				}
			}
		}
		for {
			n, from, ok := link_recv(&l, ch.rx[:])
			if !ok {
				break
			}
			h, hok := read_header(ch.rx[:n])
			if !hok {
				// Garbage: no connection for it, and an endpoint we don't know yet is forgotten.
				if channel_find(ch, li, from) < 0 {
					link_forget(&l, from)
				}
				continue
			}
			peer := channel_peer(ch, li, from)
			if peer < 0 {
				link_forget(&l, from)
				continue
			}
			handle_datagram(ch, peer, h, ch.rx[:n], now)
		}
	}
	for &c, i in ch.conns {
		if c.active && now - c.last_recv > DISCONNECT_US {
			conn_release(ch, Peer(i))
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
	c.rtt_last_us = sample
	c.rtt_seen = true
	for k in 0 ..< int(sp.n_ids) {
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
Dgram_Header :: struct {
	epoch, echo, seq, ack, ack_bits: u32,
	n_chunks:                        int,
	body:                            int, // offset of the first chunk
}

// The datagram header, if it is one of ours.
@(private)
read_header :: proc(bytes: []u8) -> (h: Dgram_Header, ok: bool) {
	r := wire.reader_make(bytes)
	if wire.r_u8(&r) != DGRAM_MAGIC || wire.r_u8(&r) != DGRAM_VERSION {
		return
	}
	h.epoch = wire.r_u32(&r)
	h.echo = wire.r_u32(&r)
	h.seq = wire.r_u32(&r)
	h.ack = wire.r_u32(&r)
	h.ack_bits = wire.r_u32(&r)
	h.n_chunks = int(wire.r_u16(&r))
	h.body = r.pos
	return h, r.ok && h.epoch != 0
}

@(private)
handle_datagram :: proc(ch: ^Channel, from: Peer, h: Dgram_Header, bytes: []u8, now: i64) {
	c, read := accept_epoch(ch, from, h, now)
	if !read {
		return
	}
	ch.stats.datagrams_recv += 1
	ch.stats.bytes_recv += len(bytes)
	if h.ack != 0 {
		take_acks(c, h.ack, h.ack_bits, now)
	}
	note_seq(c, h.seq)
	r := wire.reader_make(bytes)
	r.pos = h.body
	read_chunks(ch, c, from, &r, h.n_chunks)
}

// Matches the datagram's epochs against the connection; returns it when the datagram should be read.
@(private)
accept_epoch :: proc(ch: ^Channel, from: Peer, h: Dgram_Header, now: i64) -> (^Conn, bool) {
	old := &ch.conns[from]
	if h.echo != 0 && old.active && h.echo != old.epoch {
		return nil, false // for an earlier connection of ours
	}
	if h.echo != 0 && !old.active {
		// The peer still talks to a connection we ended (timed out, or dropped after a goodbye).
		// Open a new one without reading this datagram: our reply carries the new epoch, which
		// ends the peer's side at once.
		c := conn_open(ch, from, now)
		c.peer_epoch = h.epoch
		return nil, false
	}
	if old.active && old.peer_epoch != 0 && old.peer_epoch != h.epoch {
		// The peer started over: end the old connection; this datagram opens the new one.
		link, lpeer := old.link, old.lpeer
		conn_reset(old)
		old.used, old.link, old.lpeer = true, link, lpeer
		append(&ch.events, Event{kind = .Disconnected, peer = from})
	}
	c := conn_open(ch, from, now)
	c.last_recv = now
	c.peer_epoch = h.epoch
	return c, true
}

// Our sequence numbers that the peer has received: mark their reliable messages acked and drop the
// acknowledged prefix of the reliable queue.
@(private)
take_acks :: proc(c: ^Conn, ack, ack_bits: u32, now: i64) {
	seq_acked(c, ack, now)
	for b in 0 ..< u32(32) {
		if ack_bits & (1 << b) != 0 && ack > b + 1 {
			seq_acked(c, ack - b - 1, now)
		}
	}
	k := 0
	for k < len(c.rel_out) && c.rel_out[k].acked {
		delete(c.rel_out[k].data)
		k += 1
	}
	if k > 0 {
		remove_range(&c.rel_out, 0, k)
	}
}

// Records the peer's sequence number for our acks.
@(private)
note_seq :: proc(c: ^Conn, seq: u32) {
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
}

// Delivers the datagram's chunks: unreliable ones at once, reliable ones in id order (early ones wait
// within REL_WINDOW; duplicates and ids beyond the window are dropped).
@(private)
read_chunks :: proc(ch: ^Channel, c: ^Conn, from: Peer, r: ^wire.Reader, n_chunks: int) {
	for _ in 0 ..< n_chunks {
		kind := wire.r_u8(r)
		id: u32
		if kind == 1 {
			id = wire.r_u32(r)
		}
		data := wire.r_bytes(r, int(wire.r_u16(r)))
		if !r.ok || kind > 1 {
			return
		}
		if kind == 0 {
			append(&ch.events, Event{kind = .Message, peer = from, data = arena_bytes(ch, data)})
			continue
		}
		c.ack_pending = true
		if id < c.rel_next || id - c.rel_next >= REL_WINDOW {
			continue // a duplicate, or further ahead than a well-behaved sender goes
		}
		if id > c.rel_next {
			if id not_in c.rel_early {
				c.rel_early[id] = clone_bytes(data)
			}
			continue
		}
		append(&ch.events, Event{kind = .Message, peer = from, data = arena_bytes(ch, data)})
		c.rel_next += 1
		for {
			b, ok := c.rel_early[c.rel_next]
			if !ok {
				break
			}
			append(&ch.events, Event{kind = .Message, peer = from, data = arena_bytes(ch, b)})
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
	wire.w_u32(&pb.w, c.epoch)
	wire.w_u32(&pb.w, c.peer_epoch)
	wire.w_u32(&pb.w, c.next_seq)
	wire.w_u32(&pb.w, c.have_recv ? c.recv_max : 0)
	wire.w_u32(&pb.w, c.recv_bits)
	wire.w_u16(&pb.w, 0) // chunk count, patched in end_packet
}

@(private)
end_packet :: proc(ch: ^Channel, pb: ^Packet_Builder, c: ^Conn, peer: Peer, now: i64) {
	pb.w.buf[HEADER_BYTES - 2] = u8(pb.count)
	pb.w.buf[HEADER_BYTES - 1] = u8(pb.count >> 8)
	sp := &c.sent[c.next_seq % SENT_RING]
	sp^ = pb.sp
	sp.seq = c.next_seq
	sp.valid = true
	sp.at = now
	c.next_seq += 1
	c.last_sent = now
	c.ack_pending = false
	link_send(&ch.links[c.link], c.lpeer, pb.w.buf[:])
	ch.stats.datagrams_sent += 1
	ch.stats.bytes_sent += len(pb.w.buf)
}

// Sends everything queued, plus due resends and pending acks, as datagrams.
channel_flush :: proc(ch: ^Channel, now: i64) {
	pb := Packet_Builder {
		w = ch.tx,
	}
	defer ch.tx = pb.w
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
			if m.id - c.rel_out[0].id >= REL_WINDOW || budget <= 0 {
				break // the receiver would drop it: wait for acks
			}
			if m.acked || (m.last_sent != 0 && now - m.last_sent < rto) {
				continue
			}
			if !fits(&pb, CHUNK_OVERHEAD + len(m.data)) || pb.sp.n_ids == MAX_IDS_PER_PACKET {
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

// A channel's datagram and byte counts, as JSON (temp-allocated).
channel_stats_json :: proc(s: Channel_Stats) -> string {
	return fmt.tprintf(
		`{{"datagrams_sent":%d,"datagrams_recv":%d,"bytes_sent":%d,"bytes_recv":%d,"resends":%d}}`,
		s.datagrams_sent,
		s.datagrams_recv,
		s.bytes_sent,
		s.bytes_recv,
		s.resends,
	)
}
