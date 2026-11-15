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
// measured RTT. At most REL_IN_FLIGHT datagrams carrying reliable messages are in flight past the newest seq the
// peer acked, so one ack (its seq and 32 more) covers a whole burst (a snapshot): the rest waits for that ack instead
// of being resent though it arrived. Reliable messages are delivered once, in order. Unreliable ones are delivered as
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
REL_IN_FLIGHT :: 32 // datagrams with reliable messages past the newest seq the peer acked (one ack covers 33 seqs)
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
	acked_max:   u32, // the newest of our seqs the peer acked (0: none)
	rel_seqs:    [REL_IN_FLIGHT]u32, // seqs of datagrams with reliable messages, newer than acked_max (a FIFO)
	rel_first:   int,
	rel_count:   int,
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
	channel := new(Channel)
	channel.tx = wire.writer_make(MAX_DATAGRAM)
	// Distinct per process run and channel, so a restarted program never reuses its old epochs.
	channel.epochs = u32(now_us()) ~ u32(uintptr(channel) >> 4)
	return channel
}

// Adds a link; the channel owns it from now on (closed by channel_destroy). Returns its index.
channel_add_link :: proc(channel: ^Channel, link: Link) -> int {
	append(&channel.links, link)
	return len(channel.links) - 1
}

channel_destroy :: proc(channel: ^Channel) {
	for &conn in channel.conns {
		conn_reset(&conn)
	}
	delete(channel.events)
	for &link in channel.links {
		link_close(&link)
	}
	delete(channel.links)
	delete(channel.tx.buf)
	runtime.arena_destroy(&channel.arena)
	free(channel)
}

// The channel Peer for a link's peer, assigning one on first use (-1 when all are taken).
channel_peer :: proc(channel: ^Channel, link: int, link_peer: Peer) -> Peer {
	if peer := channel_find(channel, link, link_peer); peer >= 0 {
		return peer
	}
	free_slot := -1
	for &conn, i in channel.conns {
		if !conn.used {
			free_slot = i
			break
		}
	}
	if free_slot < 0 {
		return -1
	}
	conn := &channel.conns[free_slot]
	conn^ = {}
	conn.used = true
	conn.link = link
	conn.lpeer = link_peer
	return Peer(free_slot)
}

// The channel Peer already assigned to a link's peer, or -1.
@(private)
channel_find :: proc(channel: ^Channel, link: int, link_peer: Peer) -> Peer {
	for &conn, i in channel.conns {
		if conn.used && conn.link == link && conn.lpeer == link_peer {
			return Peer(i)
		}
	}
	return -1
}

// The account the peer's link vouches for (Link.account; ok = false: none).
channel_account :: proc(channel: ^Channel, peer: Peer) -> (account: Account, ok: bool) {
	if int(peer) < 0 || int(peer) >= MAX_PEERS || !channel.conns[peer].used {
		return
	}
	conn := &channel.conns[peer]
	return link_account(&channel.links[conn.link], conn.lpeer)
}

// Forgets a peer at once (no Disconnected event): after it said goodbye.
channel_drop :: proc(channel: ^Channel, peer: Peer) {
	if int(peer) >= 0 && int(peer) < MAX_PEERS {
		conn_release(channel, peer)
	}
}

// Ends a connection and frees its mapping, telling the link it may reuse the peer number.
@(private)
conn_release :: proc(channel: ^Channel, peer: Peer) {
	conn := &channel.conns[peer]
	used, link, link_peer := conn.used, conn.link, conn.lpeer
	conn_reset(conn)
	if used {
		link_forget(&channel.links[link], link_peer)
	}
}

@(private)
arena_bytes :: proc(channel: ^Channel, bytes: []u8) -> []u8 {
	return clone_bytes(bytes, runtime.arena_allocator(&channel.arena))
}

@(private)
conn_reset :: proc(conn: ^Conn) {
	for message in conn.rel_out {
		delete(message.data)
	}
	delete(conn.rel_out)
	for bytes in conn.unrel_out {
		delete(bytes)
	}
	delete(conn.unrel_out)
	for _, bytes in conn.rel_early {
		delete(bytes)
	}
	delete(conn.rel_early)
	delete(conn.sent)
	conn^ = {}
}

@(private)
conn_open :: proc(channel: ^Channel, peer: Peer, now: i64) -> ^Conn {
	conn := &channel.conns[peer]
	if !conn.active {
		link, link_peer := conn.link, conn.lpeer
		conn_reset(conn)
		conn.used = true
		conn.link = link
		conn.lpeer = link_peer
		conn.active = true
		conn.sent = make([]Sent_Packet, SENT_RING)
		conn.last_recv = now
		conn.next_seq = 1
		conn.srtt_us = 100_000
		channel.epochs += 1
		conn.epoch = max(mix32(channel.epochs), 1)
		append(&channel.events, Event{kind = .Connected, peer = peer})
	}
	return conn
}

// A bijective 32-bit mix (murmur3's finalizer): consecutive counters give unrelated epochs.
@(private)
mix32 :: proc(x: u32) -> u32 {
	hash := x
	hash ~= hash >> 16
	hash *= 0x85EBCA6B
	hash ~= hash >> 13
	hash *= 0xC2B2AE35
	hash ~= hash >> 16
	return hash
}

// Queues a message; it goes out on the next flush. A message longer than MAX_MESSAGE, or to a peer
// without a mapping, is dropped (false): never an assert, the bytes may come from the network.
channel_send :: proc(channel: ^Channel, peer: Peer, data: []u8, delivery: Delivery, now: i64) -> bool {
	if int(peer) < 0 || int(peer) >= MAX_PEERS || !channel.conns[peer].used || len(data) > MAX_MESSAGE {
		return false
	}
	conn := conn_open(channel, peer, now)
	if delivery == .Reliable {
		append(&conn.rel_out, Rel_Msg{id = conn.next_rel_id, data = clone_bytes(data)})
		conn.next_rel_id += 1
	} else {
		append(&conn.unrel_out, clone_bytes(data))
	}
	return true
}

// The latest round-trip sample to `peer` (a datagram sent until its ack arrived; ok = false before the first ack).
// Every datagram is acked within a few ms, so from the first answer on it is a fresh measure of the path.
channel_rtt :: proc(channel: ^Channel, peer: Peer) -> (us: f64, ok: bool) {
	if int(peer) < 0 || int(peer) >= MAX_PEERS || !channel.conns[peer].active || !channel.conns[peer].rtt_seen {
		return 0, false
	}
	return channel.conns[peer].rtt_last_us, true
}

// True when every reliable message to `peer` has been acknowledged.
channel_idle :: proc(channel: ^Channel, peer: Peer) -> bool {
	return len(channel.conns[peer].rel_out) == 0
}

// Receives everything pending on every link and returns the events (valid until the next poll).
channel_poll :: proc(channel: ^Channel, now: i64) -> []Event {
	clear(&channel.events)
	runtime.arena_free_all(&channel.arena)
	for &link, link_index in channel.links {
		if link.event != nil {
			for {
				link_peer, kind, ok := link.event(link.data)
				if !ok {
					break
				}
				peer := channel_find(channel, link_index, link_peer)
				if kind == .Disconnected && peer >= 0 && channel.conns[peer].active {
					conn_release(channel, peer)
					append(&channel.events, Event{kind = .Disconnected, peer = peer})
				}
			}
		}
		for {
			size, from, ok := link_recv(&link, channel.rx[:])
			if !ok {
				break
			}
			header, header_ok := read_header(channel.rx[:size])
			if !header_ok {
				// Garbage: no connection for it, and an endpoint we don't know yet is forgotten.
				if channel_find(channel, link_index, from) < 0 {
					link_forget(&link, from)
				}
				continue
			}
			peer := channel_peer(channel, link_index, from)
			if peer < 0 {
				link_forget(&link, from)
				continue
			}
			handle_datagram(channel, peer, header, channel.rx[:size], now)
		}
	}
	for &conn, i in channel.conns {
		if conn.active && now - conn.last_recv > DISCONNECT_US {
			conn_release(channel, Peer(i))
			append(&channel.events, Event{kind = .Disconnected, peer = Peer(i)})
		}
	}
	return channel.events[:]
}

@(private)
seq_acked :: proc(conn: ^Conn, seq: u32, now: i64) {
	record := &conn.sent[seq % SENT_RING]
	if !record.valid || record.seq != seq {
		return
	}
	record.valid = false
	sample := f64(now - record.at)
	conn.srtt_us += (sample - conn.srtt_us) * 0.125
	conn.rtt_last_us = sample
	conn.rtt_seen = true
	for k in 0 ..< int(record.n_ids) {
		id := record.ids[k]
		for &message in conn.rel_out {
			if message.id == id {
				message.acked = true
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
read_header :: proc(bytes: []u8) -> (header: Dgram_Header, ok: bool) {
	reader := wire.reader_make(bytes)
	if wire.r_u8(&reader) != DGRAM_MAGIC || wire.r_u8(&reader) != DGRAM_VERSION {
		return
	}
	header.epoch = wire.r_u32(&reader)
	header.echo = wire.r_u32(&reader)
	header.seq = wire.r_u32(&reader)
	header.ack = wire.r_u32(&reader)
	header.ack_bits = wire.r_u32(&reader)
	header.n_chunks = int(wire.r_u16(&reader))
	header.body = reader.pos
	return header, reader.ok && header.epoch != 0
}

@(private)
handle_datagram :: proc(channel: ^Channel, from: Peer, header: Dgram_Header, bytes: []u8, now: i64) {
	conn, read := accept_epoch(channel, from, header, now)
	if !read {
		return
	}
	channel.stats.datagrams_recv += 1
	channel.stats.bytes_recv += len(bytes)
	if header.ack != 0 {
		take_acks(conn, header.ack, header.ack_bits, now)
	}
	note_seq(conn, header.seq)
	reader := wire.reader_make(bytes)
	reader.pos = header.body
	read_chunks(channel, conn, from, &reader, header.n_chunks)
}

// Matches the datagram's epochs against the connection; returns it when the datagram should be read.
@(private)
accept_epoch :: proc(channel: ^Channel, from: Peer, header: Dgram_Header, now: i64) -> (^Conn, bool) {
	old := &channel.conns[from]
	if header.echo != 0 && old.active && header.echo != old.epoch {
		return nil, false // for an earlier connection of ours
	}
	if header.echo != 0 && !old.active {
		// The peer still talks to a connection we ended (timed out, or dropped after a goodbye).
		// Open a new one without reading this datagram: our reply carries the new epoch, which
		// ends the peer's side at once.
		conn := conn_open(channel, from, now)
		conn.peer_epoch = header.epoch
		return nil, false
	}
	if old.active && old.peer_epoch != 0 && old.peer_epoch != header.epoch {
		// The peer started over: end the old connection; this datagram opens the new one.
		link, link_peer := old.link, old.lpeer
		conn_reset(old)
		old.used, old.link, old.lpeer = true, link, link_peer
		append(&channel.events, Event{kind = .Disconnected, peer = from})
	}
	conn := conn_open(channel, from, now)
	conn.last_recv = now
	conn.peer_epoch = header.epoch
	return conn, true
}

// Our sequence numbers that the peer has received: mark their reliable messages acked and drop the
// acknowledged prefix of the reliable queue.
@(private)
take_acks :: proc(conn: ^Conn, ack, ack_bits: u32, now: i64) {
	conn.acked_max = max(conn.acked_max, min(ack, conn.next_seq - 1))
	seq_acked(conn, ack, now)
	for bit in 0 ..< u32(32) {
		if ack_bits & (1 << bit) != 0 && ack > bit + 1 {
			seq_acked(conn, ack - bit - 1, now)
		}
	}
	k := 0
	for k < len(conn.rel_out) && conn.rel_out[k].acked {
		delete(conn.rel_out[k].data)
		k += 1
	}
	if k > 0 {
		remove_range(&conn.rel_out, 0, k)
	}
}

// Records the peer's sequence number for our acks.
@(private)
note_seq :: proc(conn: ^Conn, seq: u32) {
	if !conn.have_recv || seq > conn.recv_max {
		shift := conn.have_recv ? seq - conn.recv_max : 33
		conn.recv_bits = shift >= 32 ? 0 : (conn.recv_bits << shift)
		if conn.have_recv && shift <= 32 {
			conn.recv_bits |= 1 << (shift - 1)
		}
		conn.recv_max = seq
		conn.have_recv = true
	} else if seq < conn.recv_max && conn.recv_max - seq <= 32 {
		conn.recv_bits |= 1 << (conn.recv_max - seq - 1)
	}
}

// Delivers the datagram's chunks: unreliable ones at once, reliable ones in id order (early ones wait
// within REL_WINDOW; duplicates and ids beyond the window are dropped).
@(private)
read_chunks :: proc(channel: ^Channel, conn: ^Conn, from: Peer, reader: ^wire.Reader, n_chunks: int) {
	for _ in 0 ..< n_chunks {
		kind := wire.r_u8(reader)
		id: u32
		if kind == 1 {
			id = wire.r_u32(reader)
		}
		data := wire.r_bytes(reader, int(wire.r_u16(reader)))
		if !reader.ok || kind > 1 {
			return
		}
		if kind == 0 {
			append(&channel.events, Event {
				kind = .Message,
				peer = from,
				data = arena_bytes(channel, data),
			})
			continue
		}
		conn.ack_pending = true
		if id < conn.rel_next || id - conn.rel_next >= REL_WINDOW {
			continue // a duplicate, or further ahead than a well-behaved sender goes
		}
		if id > conn.rel_next {
			if id not_in conn.rel_early {
				conn.rel_early[id] = clone_bytes(data)
			}
			continue
		}
		append(&channel.events, Event {
			kind = .Message,
			peer = from,
			data = arena_bytes(channel, data),
		})
		conn.rel_next += 1
		for {
			early, ok := conn.rel_early[conn.rel_next]
			if !ok {
				break
			}
			append(&channel.events, Event {
				kind = .Message,
				peer = from,
				data = arena_bytes(channel, early),
			})
			delete(early)
			delete_key(&conn.rel_early, conn.rel_next)
			conn.rel_next += 1
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
begin_packet :: proc(builder: ^Packet_Builder, conn: ^Conn) {
	clear(&builder.w.buf)
	builder.count = 0
	builder.sp = {}
	wire.w_u8(&builder.w, DGRAM_MAGIC)
	wire.w_u8(&builder.w, DGRAM_VERSION)
	wire.w_u32(&builder.w, conn.epoch)
	wire.w_u32(&builder.w, conn.peer_epoch)
	wire.w_u32(&builder.w, conn.next_seq)
	wire.w_u32(&builder.w, conn.have_recv ? conn.recv_max : 0)
	wire.w_u32(&builder.w, conn.recv_bits)
	wire.w_u16(&builder.w, 0) // chunk count, patched in end_packet
}

@(private)
end_packet :: proc(channel: ^Channel, builder: ^Packet_Builder, conn: ^Conn, peer: Peer, now: i64) {
	builder.w.buf[HEADER_BYTES - 2] = u8(builder.count)
	builder.w.buf[HEADER_BYTES - 1] = u8(builder.count >> 8)
	record := &conn.sent[conn.next_seq % SENT_RING]
	record^ = builder.sp
	record.seq = conn.next_seq
	record.valid = true
	record.at = now
	if builder.sp.n_ids > 0 {
		conn.rel_seqs[(conn.rel_first + conn.rel_count) % REL_IN_FLIGHT] = conn.next_seq
		conn.rel_count += 1
	}
	conn.next_seq += 1
	conn.last_sent = now
	conn.ack_pending = false
	link_send(&channel.links[conn.link], conn.lpeer, builder.w.buf[:])
	channel.stats.datagrams_sent += 1
	channel.stats.bytes_sent += len(builder.w.buf)
}

// Whether another datagram may carry reliable messages: fewer than REL_IN_FLIGHT of them are newer than the
// peer's newest ack (the older ones were acked, or are lost and resent when their timer runs out).
@(private)
rel_room :: proc(conn: ^Conn) -> bool {
	for conn.rel_count > 0 && conn.rel_seqs[conn.rel_first] <= conn.acked_max {
		conn.rel_first = (conn.rel_first + 1) % REL_IN_FLIGHT
		conn.rel_count -= 1
	}
	return conn.rel_count < REL_IN_FLIGHT
}

// Sends everything queued, plus due resends and pending acks, as datagrams.
channel_flush :: proc(channel: ^Channel, now: i64) {
	builder := Packet_Builder {
		w = channel.tx,
	}
	defer channel.tx = builder.w
	for &conn, i in channel.conns {
		if !conn.active {
			continue
		}
		peer := Peer(i)
		rto := i64(clamp(conn.srtt_us * 1.5 + 15_000, 30_000, 500_000))
		begin_packet(&builder, &conn)
		fits :: proc(builder: ^Packet_Builder, size: int) -> bool {
			return len(builder.w.buf) + size <= MAX_DATAGRAM
		}
		for bytes in conn.unrel_out {
			if !fits(&builder, 3 + len(bytes)) {
				end_packet(channel, &builder, &conn, peer, now)
				begin_packet(&builder, &conn)
			}
			wire.w_u8(&builder.w, 0)
			wire.w_u16(&builder.w, u16(len(bytes)))
			wire.w_bytes(&builder.w, bytes)
			builder.count += 1
			delete(bytes)
		}
		clear(&conn.unrel_out)
		budget := FLUSH_BUDGET
		for &message in conn.rel_out {
			if message.id - conn.rel_out[0].id >= REL_WINDOW || budget <= 0 {
				break // the receiver would drop it: wait for acks
			}
			if message.acked || (message.last_sent != 0 && now - message.last_sent < rto) {
				continue
			}
			if !fits(&builder, CHUNK_OVERHEAD + len(message.data)) || builder.sp.n_ids == MAX_IDS_PER_PACKET {
				end_packet(channel, &builder, &conn, peer, now)
				begin_packet(&builder, &conn)
			}
			if builder.sp.n_ids == 0 && !rel_room(&conn) {
				break // as many reliable datagrams in flight as one ack covers: wait for it
			}
			if message.last_sent != 0 {
				channel.stats.resends += 1
			}
			wire.w_u8(&builder.w, 1)
			wire.w_u32(&builder.w, message.id)
			wire.w_u16(&builder.w, u16(len(message.data)))
			wire.w_bytes(&builder.w, message.data)
			builder.count += 1
			builder.sp.ids[builder.sp.n_ids] = message.id
			builder.sp.n_ids += 1
			message.last_sent = now
			budget -= len(message.data)
		}
		// Data, a pending ack, or a keepalive so idle peers (e.g. waiting for the start) stay connected.
		if builder.count > 0 ||
		   (conn.ack_pending && now - conn.last_sent > 5_000) ||
		   now - conn.last_sent > KEEPALIVE_US {
			end_packet(channel, &builder, &conn, peer, now)
		}
	}
}

// A channel's datagram and byte counts, as JSON (temp-allocated).
channel_stats_json :: proc(stats: Channel_Stats) -> string {
	return fmt.tprintf(
		`{{"datagrams_sent":%d,"datagrams_recv":%d,"bytes_sent":%d,"bytes_recv":%d,"resends":%d}}`,
		stats.datagrams_sent,
		stats.datagrams_recv,
		stats.bytes_sent,
		stats.bytes_recv,
		stats.resends,
	)
}
