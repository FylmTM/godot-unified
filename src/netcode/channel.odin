// The channel (src/netcode/README.md, Channel): reliable and unreliable messages to peers over any number of links,
// each (link, link peer) pair one channel Peer, the same protocol over every link. Its datagrams:
//
//   datagram = u8 tag (0x80 | PROTOCOL_VERSION), u32 epoch, u32 peer epoch or opened, u32 seq, u32 ack, u32 ack_bits,
//              u8 recent, u16 recent delay (ACK_DELAY_UNIT_US), u8 chunk count, chunks
//   chunk    = u8 kind (0 unreliable, 1 reliable, 2 older acks), [u32 message id if reliable], u16 len, bytes
//   older acks = up to ACK_EXT_WORDS u32: bit b of word w acks seq ack - 33 - (32 w + b)
//   notice   = u8 tag, u32 0: "I run this protocol version", the answer to a datagram of another version
//
// `epoch` is the sender's connection's (a fresh value each time a side opens one; EPOCH_BIT always set), `peer epoch`
// echoes the receiver's last one seen. Until the sender has seen one, the field is instead `opened` (EPOCH_BIT clear):
// when the sender opened its connection, in milliseconds of its machine's clock, which orders one machine's programs
// (accept_epoch). `recent` is how far back from `ack` the datagram that arrived last is, and its delay how
// long it waited before this one went out (a round-trip sample). A datagram whose tag has the top bit but another
// version is answered with a notice (a notice never is: two versions can't ping-pong); a notice from a peer is the
// channel's Incompatible event. The notice's five bytes never change across versions.
package netcode

import "base:runtime"
import "core:fmt"
import "core:sync"

import "unified:sim"
import "unified:wire"

// How channel_send delivers a message: as it comes (maybe lost, duplicated or reordered), or once and in order.
Delivery :: enum u8 {
	Unreliable,
	Reliable,
}

// What a channel_poll event is.
Event_Kind :: enum u8 {
	Connected, // a connection opened (the peer's first datagram, or our first send to it)
	Disconnected, // it ended: it timed out, the link said so, or the peer started over
	Message,
	Incompatible, // the peer runs another protocol version (its notice came)
}

// One thing channel_poll saw on a peer: a connection opened or ended, a message, or another protocol version.
Event :: struct {
	kind: Event_Kind,
	peer: Peer,
	data: []u8, // valid until the next channel_poll
}

// The connections a channel holds: one for each player of the largest game, and PEERS_SPARE that seat nobody: a peer
// being refused (the session is full), and one opened only to tell a peer its old connection ended (it lives
// DISCONNECT_US). Without them a full session answers nobody else, and a freed seat waits for one to time out.
MAX_PEERS :: sim.MAX_PLAYERS + PEERS_SPARE
PEERS_SPARE :: 4
@(private)
POOL_RESERVE :: 32 // message slots a channel (and a netsim) has from the start (37 kB): what usual traffic holds
@(private)
SENT_RING :: 1024 // per active connection, allocated when it opens
@(private)
MAX_IDS_PER_PACKET :: 64
REL_WINDOW :: 512 // reliable messages in flight past the oldest unacked one
@(private)
ACK_EXT_WORDS :: 8 // the older acks chunk's words at most: 256 seqs beyond a header's 33
@(private)
ACK_SPAN :: 33 + 32 * ACK_EXT_WORDS // seqs one datagram can ack: its ack and the 288 before it
@(private)
ACK_EXT_HOLD_US :: 250_000 // a receiver sends the older acks this long after seqs it can't ack otherwise arrived
@(private)
REL_IN_FLIGHT :: ACK_SPAN - 1 // datagrams with reliable messages past the newest seq the peer acked
REL_RATE :: 1_000_000 // reliable bytes per second to one peer (8 Mbit/s): a 2 MB snapshot in 2 s per hop
REL_BURST :: 32 * MAX_DATAGRAM // reliable bytes to one peer at once (37 kB: fits a default socket buffer)
DISCONNECT_US :: 10_000_000 // silence from a peer that has answered before
// Silence from a peer that never answered. A transport may need seconds to set up the path first (EOS: login, lobby
// search, the P2P connection and its retries), and the client's first hello goes out before that.
FIRST_ANSWER_US :: 30_000_000
@(private)
KEEPALIVE_US :: 250_000
DGRAM_TAG :: u8(0x80 | PROTOCOL_VERSION) // a datagram's first byte
NOTICE_BYTES :: 5 // the version notice: the tag and a zero epoch
HEADER_BYTES :: 25
@(private)
ACK_DELAY_UNIT_US :: 16 // the ack delay's unit (a u16: up to ~1 s; longer saturates and measures nothing)
@(private)
CHUNK_OVERHEAD :: 7 // kind u8, id u32, len u16
MAX_MESSAGE :: MAX_DATAGRAM - HEADER_BYTES - CHUNK_OVERHEAD // the largest message channel_send takes
EPOCH_BIT :: u32(0x8000_0000) // set in every epoch; clear in the header's `opened` (a datagram that echoes no epoch)

// Reliable and unreliable messages to channel peers over any number of links (channel_make); the relay and each
// client own one.
Channel :: struct {
	links:  [dynamic]Link,
	conns:  [MAX_PEERS]Conn,
	events: [dynamic]Event,
	polled: int, // how many of `events` the last poll returned (the rest came after it: channel_send's Connected)
	rx:     [MAX_DATAGRAM]u8,
	stats:  Channel_Stats,
	arena:  runtime.Arena, // event payloads, reset by each poll
	tx:     wire.Writer,
	pool:   Slot_Pool, // the queued messages' and early reliable messages' bytes
	ended:  Ended_Epochs,
}

// The peers' epochs of the last ENDED_EPOCHS connections dropped (channel_drop) or replaced by the peer starting over:
// a connection that ended so never comes back. A datagram of one is never read, so a Hello it resent before its Leave,
// arriving after it, seats nobody, and a straggler of a replaced connection never ends the one that replaced it.
@(private)
Ended_Epochs :: struct {
	conns: [ENDED_EPOCHS]struct {
		link:  int,
		epoch: u32, // 0: none
	},
	next:  int,
}

@(private)
ENDED_EPOCHS :: 2 * MAX_PEERS // every connection ending at once, twice: a whole session leaving, and its stragglers

// A channel's datagrams and bytes sent and received since it was made, and its reliable resends (Client_Stats.net).
Channel_Stats :: struct {
	datagrams_sent, datagrams_recv, bytes_sent, bytes_recv, resends: int,
}

// A reliable message queued to a peer, held until a datagram carrying it is acked.
Rel_Msg :: struct {
	id:        u32,
	data:      Pooled,
	last_sent: i64, // µs; 0 = never sent
	acked:     bool,
}

// A datagram we sent: its seq, when, and the reliable messages an ack of it delivers (a connection keeps SENT_RING).
Sent_Packet :: struct {
	at:    i64,
	seq:   u32,
	n_ids: u16,
	valid: bool,
	ids:   [MAX_IDS_PER_PACKET]u32,
}

// One channel peer's connection: the (link, link peer) it maps to, both epochs, its send and receive state. Reset, not
// freed, when it ends: its buffers serve the next connection on that peer.
Conn :: struct {
	used:        bool, // the (link, lpeer) mapping is assigned
	link:        int,
	lpeer:       Peer,
	active:      bool,
	epoch:       u32, // ours, sent in every datagram
	peer_epoch:  u32, // theirs (0: none seen yet)
	opened:      u32, // when we opened it (opened_ms), sent in place of peer_epoch until we have it
	peer_opened: u32, // when the peer opened its side, from its first datagrams (peer_known: it sent one)
	peer_known:  bool,
	last_recv:   i64,
	last_sent:   i64,
	// send side
	next_seq:    u32,
	sent:        []Sent_Packet, // SENT_RING records while active, nil otherwise
	rel_out:     [dynamic]Rel_Msg,
	next_rel_id: u32,
	unrel_out:   [dynamic]Pooled,
	srtt_us:     f64,
	acked_max:   u32, // the newest of our seqs the peer acked (0: none)
	// Seqs of datagrams with reliable messages, newer than acked_max (a FIFO of REL_IN_FLIGHT, allocated with `sent`)
	rel_seqs:    []u32,
	rel_first:   int,
	rel_count:   int,
	rtt_last_us: f64, // the latest round-trip sample (valid once rtt_samples > 0)
	rtt_samples: int, // round-trip samples taken (a new one each time it moves)
	// receive side
	have_recv:   bool,
	recv_max:    u32,
	recent:      u32, // the seq that arrived last (any, an old one too)
	recent_at:   i64, // when it did (the delay we send with it)
	recv_bits:   [1 + ACK_EXT_WORDS]u32, // bit i: seq recv_max - 1 - i arrived (word 0 goes in the header)
	low_since:   u32, // the oldest seq that arrived since our last datagram (have_since: any did)
	have_since:  bool,
	ext_until:   i64, // our datagrams carry the older acks until then
	rel_bucket:  i64, // reliable bytes we may send now (refilled at REL_RATE up to REL_BURST)
	rel_fill_us: i64, // when the bucket was last refilled
	ack_pending: bool,
	rel_next:    u32,
	rel_early:   map[u32]Pooled, // ids rel_next+1 ..< rel_next+REL_WINDOW that arrived early
}

// Creates an empty channel with no links; the relay and each client own one. Free it with channel_destroy.
channel_make :: proc() -> ^Channel {
	channel := new(Channel)
	channel.tx = wire.writer_make(MAX_DATAGRAM)
	pool_reserve(&channel.pool, POOL_RESERVE)
	// the base, at the process's first channel: the clock and an address (ASLR), so another process, or this program
	// restarted, counts somewhere else
	sync.atomic_compare_exchange_strong(&epochs_opened, 0, (u32(now_us()) ~ u32(uintptr(channel) >> 4)) | 1)
	return channel
}

// The connections the process's channels have opened, counted from a base (channel_make). Each new
// connection's epoch is the next count through mix31, a bijection: no two connections of one process ever share an
// epoch, whichever channel opened them. (A per-channel seed from the clock and the channel's address repeats when a
// channel freed and made again lands at the same address with a matching clock: the new connection then reads as the
// old one, or as ended, and is never heard.)
@(private)
epochs_opened: u32

// Adds a link; the channel owns it from now on (closed by channel_destroy). Returns its index.
channel_add_link :: proc(channel: ^Channel, link: Link) -> int {
	append(&channel.links, link)
	return len(channel.links) - 1
}

// Frees every connection, closes every link the channel owns, and frees the channel.
channel_destroy :: proc(channel: ^Channel) {
	for &conn in channel.conns {
		conn_reset(channel, &conn)
		conn_free(&conn)
	}
	delete(channel.events)
	for &link in channel.links {
		link_close(&link)
	}
	delete(channel.links)
	delete(channel.tx.buf)
	runtime.arena_destroy(&channel.arena)
	pool_destroy(&channel.pool)
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
	conn_reset(channel, conn)
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
@(private)
channel_account :: proc(channel: ^Channel, peer: Peer) -> (account: Account, ok: bool) {
	if int(peer) < 0 || int(peer) >= MAX_PEERS || !channel.conns[peer].used {
		return
	}
	conn := &channel.conns[peer]
	return link_account(&channel.links[conn.link], conn.lpeer)
}

// Whether `peer`'s connection is open: false once it ended (timed out, dropped after a goodbye) until the peer opens a
// new one.
channel_connected :: proc(channel: ^Channel, peer: Peer) -> bool {
	return int(peer) >= 0 && int(peer) < MAX_PEERS && channel.conns[peer].active
}

// Forgets a peer at once (no Disconnected event): after it said goodbye, or when a newer connection replaced it. Its
// last datagram acks what arrived (the goodbye), so a leaving peer finishes at once. The connection never comes
// back: a datagram of it arriving later (a resend, a duplicate, a reordered one) is never read, and opens a new
// connection only to tell the peer this one ended (it echoes ours, so the peer heard from us).
channel_drop :: proc(channel: ^Channel, peer: Peer, now: i64) {
	if int(peer) < 0 || int(peer) >= MAX_PEERS {
		return
	}
	if conn := &channel.conns[peer]; conn.active {
		builder := Packet_Builder {
			w = channel.tx,
		}
		begin_packet(&builder, conn, now)
		end_packet(channel, &builder, conn, peer, now)
		channel.tx = builder.w
		ended_add(channel, conn.link, conn.peer_epoch)
	}
	conn_release(channel, peer)
}

// Remembers a peer's epoch on `link` as ended (0: none to remember): its datagrams are never read again.
@(private)
ended_add :: proc(channel: ^Channel, link: int, epoch: u32) {
	if epoch != 0 {
		channel.ended.conns[channel.ended.next] = {link, epoch}
		channel.ended.next = (channel.ended.next + 1) % ENDED_EPOCHS
	}
}

// Whether `epoch` is a peer's on `link` whose connection ended for good (ended_add).
@(private)
epoch_ended :: proc(channel: ^Channel, link: int, epoch: u32) -> bool {
	for ended in channel.ended.conns {
		if ended.epoch == epoch && ended.link == link && epoch != 0 {
			return true
		}
	}
	return false
}

// Starts over with a link's peer, as a restarted program would: whatever connection to it is open ends without a word,
// and the next channel_send opens a new one that echoes no epoch of the peer's. Returns the channel Peer (assigned
// again when the old mapping was freed; -1 when none is free).
channel_reopen :: proc(channel: ^Channel, link: int, link_peer: Peer) -> Peer {
	peer := channel_peer(channel, link, link_peer)
	if peer >= 0 {
		conn := &channel.conns[peer]
		conn_reset(channel, conn)
		conn.used, conn.link, conn.lpeer = true, link, link_peer
	}
	return peer
}

// Ends a connection and frees its mapping, telling the link it may reuse the peer number.
@(private)
conn_release :: proc(channel: ^Channel, peer: Peer) {
	conn := &channel.conns[peer]
	used, link, link_peer := conn.used, conn.link, conn.lpeer
	conn_reset(channel, conn)
	if used {
		link_forget(&channel.links[link], link_peer)
	}
}

@(private)
arena_bytes :: proc(channel: ^Channel, bytes: []u8) -> []u8 {
	clone := make([]u8, len(bytes), runtime.arena_allocator(&channel.arena))
	copy(clone, bytes)
	return clone
}

// Empties a connection, its slots back to the pool. Its queues and sent ring keep their memory for the next
// connection on this channel peer (conn_free frees them).
@(private)
conn_reset :: proc(channel: ^Channel, conn: ^Conn) {
	for message in conn.rel_out {
		pool_release(&channel.pool, message.data)
	}
	for held in conn.unrel_out {
		pool_release(&channel.pool, held)
	}
	for _, held in conn.rel_early {
		pool_release(&channel.pool, held)
	}
	rel_out, unrel_out, rel_early, sent, rel_seqs :=
		conn.rel_out, conn.unrel_out, conn.rel_early, conn.sent, conn.rel_seqs
	clear(&rel_out)
	clear(&unrel_out)
	clear(&rel_early)
	conn^ = {}
	conn.rel_out, conn.unrel_out, conn.rel_early, conn.sent, conn.rel_seqs =
		rel_out, unrel_out, rel_early, sent, rel_seqs
}

@(private)
conn_free :: proc(conn: ^Conn) {
	delete(conn.rel_out)
	delete(conn.unrel_out)
	delete(conn.rel_early)
	delete(conn.sent)
	delete(conn.rel_seqs)
	conn^ = {}
}

@(private)
conn_open :: proc(channel: ^Channel, peer: Peer, now: i64) -> ^Conn {
	conn := &channel.conns[peer]
	if !conn.active {
		link, link_peer := conn.link, conn.lpeer
		conn_reset(channel, conn)
		conn.used = true
		conn.link = link
		conn.lpeer = link_peer
		conn.active = true
		if conn.sent == nil {
			conn.sent = make([]Sent_Packet, SENT_RING)
			conn.rel_seqs = make([]u32, REL_IN_FLIGHT)
		} else {
			for &record in conn.sent {
				record = {} // a seq of the previous connection is not one of this one's
			}
		}
		conn.last_recv = now
		conn.rel_bucket, conn.rel_fill_us = REL_BURST, now
		conn.next_seq = 1
		conn.srtt_us = 100_000
		conn.epoch = mix31(sync.atomic_add(&epochs_opened, 1) + 1) | EPOCH_BIT
		conn.opened = opened_ms(now)
		append(&channel.events, Event{kind = .Connected, peer = peer})
	}
	return conn
}

// A connection's opening time as a datagram carries it: milliseconds of the caller's clock (now_us: the machine's
// monotonic clock, shared by its programs), 31 bits (it wraps after 24 days; newer_opened compares across a wrap).
@(private)
opened_ms :: proc(now: i64) -> u32 {
	return u32(now / 1000) & ~EPOCH_BIT
}

// Whether a datagram's opening time `a` is later than `b` (31-bit serial order: right while they are within 12 days of
// each other).
newer_opened :: proc(a, b: u32) -> bool {
	diff := (a - b) & ~EPOCH_BIT
	return diff != 0 && diff < EPOCH_BIT / 2
}

// A bijective mix of the low 31 bits (murmur3's finalizer, each step kept to 31 bits; the top bit is EPOCH_BIT's):
// consecutive counters give unrelated epochs.
@(private)
mix31 :: proc(x: u32) -> u32 {
	hash := x & ~EPOCH_BIT
	hash ~= hash >> 16
	hash = (hash * 0x85EBCA6B) & ~EPOCH_BIT
	hash ~= hash >> 13
	hash = (hash * 0xC2B2AE35) & ~EPOCH_BIT
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
		append(&conn.rel_out, Rel_Msg{id = conn.next_rel_id, data = pool_put(&channel.pool, data)})
		conn.next_rel_id += 1
	} else {
		append(&conn.unrel_out, pool_put(&channel.pool, data))
	}
	return true
}

// The latest round-trip sample to `peer` (a datagram sent until its ack came, less the time the peer held it) and how
// many were taken (0: none yet; a caller averaging them takes one each time the count moves). The peer acks every
// datagram with the next one it sends, so from its first answer on this is a fresh measure of the path.
channel_rtt :: proc(channel: ^Channel, peer: Peer) -> (us: f64, samples: int) {
	if int(peer) < 0 || int(peer) >= MAX_PEERS || !channel.conns[peer].active {
		return 0, 0
	}
	return channel.conns[peer].rtt_last_us, channel.conns[peer].rtt_samples
}

// How long `peer`'s connection has been silent at `now`: since a datagram of it was last read (max(i64): it is not
// open).
@(private)
channel_silence_us :: proc(channel: ^Channel, peer: Peer, now: i64) -> i64 {
	if int(peer) < 0 || int(peer) >= MAX_PEERS || !channel.conns[peer].active {
		return max(i64)
	}
	return now - channel.conns[peer].last_recv
}

// True when every reliable message to `peer` has been acknowledged.
channel_idle :: proc(channel: ^Channel, peer: Peer) -> bool {
	return len(channel.conns[peer].rel_out) == 0
}

// Receives everything pending on every link and returns the events (valid until the next poll), the ones raised
// since the last poll first (a Connected from channel_send opening a connection).
channel_poll :: proc(channel: ^Channel, now: i64) -> []Event {
	remove_range(&channel.events, 0, channel.polled)
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
				known := channel_find(channel, link_index, from)
				switch version_check(channel.rx[:size]) {
				case .Notice:
					if known >= 0 {
						append(&channel.events, Event{kind = .Incompatible, peer = known})
					}
				case .Other_Version:
					notice := [NOTICE_BYTES]u8{DGRAM_TAG, 0, 0, 0, 0}
					link_send(&link, from, notice[:])
				case .Garbage:
				}
				// No connection for it, and an endpoint we don't know yet is forgotten.
				if known < 0 {
					link_forget(&link, from)
				}
				continue
			}
			if epoch_ended(channel, link_index, header.epoch) {
				// Of a connection that said goodbye. One that echoes our epoch still talks to it: a new connection
				// (unread, in accept_epoch) tells it the old one ended. Anything else is dropped unread: one that
				// echoes none was sent before the peer heard from us (its Hello again), and a connection open on
				// this address is a newer one, which it must not end.
				known := channel_find(channel, link_index, from)
				if header.echo == 0 || (known >= 0 && channel.conns[known].active) {
					if known < 0 {
						link_forget(&link, from)
					}
					continue
				}
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
		timeout: i64 = conn.peer_epoch != 0 ? DISCONNECT_US : FIRST_ANSWER_US
		if conn.active && now - conn.last_recv > timeout {
			conn_release(channel, Peer(i))
			append(&channel.events, Event{kind = .Disconnected, peer = Peer(i)})
		}
	}
	channel.polled = len(channel.events)
	return channel.events[:]
}

// A round-trip sample: our datagram `seq` arrived last at the peer, which held it `held_us` before sending the
// datagram that says so. Taken from every datagram that names one, acked before or not: under jitter a datagram of
// the peer's that comes late names an arrival a faster one already acked, and skipping those would keep only the
// fast return paths (a round trip read short).
@(private)
rtt_sample :: proc(conn: ^Conn, seq: u32, now: i64, held_us: i64) {
	record := &conn.sent[seq % SENT_RING]
	if seq == 0 || record.seq != seq {
		return // never sent on this connection, or too old for the ring
	}
	if rtt := f64(now - record.at - held_us); rtt >= 0 {
		conn.srtt_us += (rtt - conn.srtt_us) * 0.125
		conn.rtt_last_us = rtt
		conn.rtt_samples += 1
	}
}

// Marks a datagram of ours received: its reliable messages are delivered.
@(private)
seq_acked :: proc(conn: ^Conn, seq: u32) {
	record := &conn.sent[seq % SENT_RING]
	if !record.valid || record.seq != seq {
		return
	}
	record.valid = false
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
	epoch, echo, seq, ack, ack_bits: u32, // echo: 0 when the datagram echoes no epoch
	opened:                          u32, // when echo is 0: when the sender opened its connection (opened_ms)
	recent:                          u32, // the seq that arrived last at the peer (0: none)
	recent_us:                       i64, // how long it waited there (-1: no round-trip sample)
	n_chunks:                        int,
	body:                            int, // offset of the first chunk
}

// The datagram header, if it is one of ours (this protocol version).
@(private)
read_header :: proc(bytes: []u8) -> (header: Dgram_Header, ok: bool) {
	reader := wire.reader_make(bytes)
	if wire.r_u8(&reader) != DGRAM_TAG {
		return
	}
	header.epoch = wire.r_u32(&reader)
	if echo_or_opened := wire.r_u32(&reader); echo_or_opened & EPOCH_BIT != 0 {
		header.echo = echo_or_opened
	} else {
		header.opened = echo_or_opened
	}
	header.seq = wire.r_u32(&reader)
	header.ack = wire.r_u32(&reader)
	header.ack_bits = wire.r_u32(&reader)
	back := u32(wire.r_u8(&reader))
	delay := wire.r_u16(&reader)
	header.recent = header.ack - back
	header.recent_us = delay == max(u16) || back > 32 ? -1 : i64(delay) * ACK_DELAY_UNIT_US
	header.n_chunks = int(wire.r_u8(&reader))
	header.body = reader.pos
	return header, reader.ok && header.epoch & EPOCH_BIT != 0
}

@(private)
Version_Check :: enum u8 {
	Garbage, // not ours at all
	Other_Version, // a datagram of another protocol version: answer with a notice
	Notice, // a peer's notice of its version, which is not ours
}

// What a datagram read_header refused is: a version notice, a datagram of another version, or neither.
@(private)
version_check :: proc(bytes: []u8) -> Version_Check {
	if len(bytes) < NOTICE_BYTES || bytes[0] & 0x80 == 0 || bytes[0] == DGRAM_TAG {
		return .Garbage
	}
	if bytes[1] | bytes[2] | bytes[3] | bytes[4] == 0 {
		return len(bytes) == NOTICE_BYTES ? .Notice : .Garbage
	}
	return .Other_Version
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
		take_acks(channel, conn, header, now)
	}
	note_seq(conn, header.seq, now)
	reader := wire.reader_make(bytes)
	reader.pos = header.body
	read_chunks(channel, conn, from, &reader, header.n_chunks, header.ack)
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
	if old.active &&
	   old.peer_epoch != 0 &&
	   old.peer_epoch != header.epoch &&
	   header.echo == 0 &&
	   old.peer_known &&
	   !newer_opened(header.opened, old.peer_opened) {
		// A connection opened before the open one, that never heard from us: a stale datagram of the link peer's
		// previous program (its first Hello, delayed or duplicated), arriving after the next program's connection is
		// live. Dropped unread while the open one lasts; it must not end it. (Two of one person's machines order by
		// two clocks: the later machine whose clock reads earlier gets in once the open connection times out.)
		return nil, false
	}
	if old.active && old.peer_epoch != 0 && old.peer_epoch != header.epoch {
		// The peer started over: end the old connection; this datagram opens the new one. On a link that numbers a
		// person, not a socket (EOS), the old connection's last datagrams and the new one's first can arrive in one
		// poll: the old one's messages read in this poll go with it (a Leave there must not end the new connection,
		// which has its peer number; its Disconnected empties its seat), and it never comes back (a straggler of it
		// must not end the new one in turn).
		for i := len(channel.events) - 1; i >= 0; i -= 1 {
			if channel.events[i].peer == from && channel.events[i].kind == .Message {
				ordered_remove(&channel.events, i)
			}
		}
		ended_add(channel, old.link, old.peer_epoch)
		link, link_peer := old.link, old.lpeer
		conn_reset(channel, old)
		old.used, old.link, old.lpeer = true, link, link_peer
		append(&channel.events, Event{kind = .Disconnected, peer = from})
	}
	conn := conn_open(channel, from, now)
	conn.last_recv = now
	conn.peer_epoch = header.epoch
	if header.echo == 0 {
		conn.peer_opened, conn.peer_known = header.opened, true
	}
	return conn, true
}

// Our sequence numbers that the peer has received: mark their reliable messages acked and drop the
// acknowledged prefix of the reliable queue.
@(private)
take_acks :: proc(channel: ^Channel, conn: ^Conn, header: Dgram_Header, now: i64) {
	ack, ack_bits := header.ack, header.ack_bits
	conn.acked_max = max(conn.acked_max, min(ack, conn.next_seq - 1))
	if header.recent_us >= 0 {
		rtt_sample(conn, header.recent, now, header.recent_us)
	}
	seq_acked(conn, ack)
	for bit in 0 ..< u32(32) {
		if ack_bits & (1 << bit) != 0 && ack > bit + 1 {
			seq_acked(conn, ack - bit - 1)
		}
	}
	release_acked(channel, conn)
}

// The older acks chunk of a datagram whose header acks `ack`: seqs ack - 33 and older.
@(private)
take_older_acks :: proc(channel: ^Channel, conn: ^Conn, ack: u32, words: []u8) {
	reader := wire.reader_make(words)
	for word in 0 ..< min(len(words) / 4, ACK_EXT_WORDS) {
		bits := wire.r_u32(&reader)
		for bit in 0 ..< u32(32) {
			back := 33 + u32(word) * 32 + bit
			if bits & (1 << bit) != 0 && ack > back {
				seq_acked(conn, ack - back)
			}
		}
	}
	release_acked(channel, conn)
}

// Drops the acknowledged prefix of the reliable queue.
@(private)
release_acked :: proc(channel: ^Channel, conn: ^Conn) {
	k := 0
	for k < len(conn.rel_out) && conn.rel_out[k].acked {
		pool_release(&channel.pool, conn.rel_out[k].data)
		k += 1
	}
	if k > 0 {
		remove_range(&conn.rel_out, 0, k)
	}
}

// Records the peer's sequence number for our acks (and when its newest arrived, for the ack delay).
@(private)
note_seq :: proc(conn: ^Conn, seq: u32, now: i64) {
	conn.recent, conn.recent_at = seq, now
	if !conn.have_since || seq < conn.low_since {
		conn.low_since, conn.have_since = seq, true
	}
	if !conn.have_recv || seq > conn.recv_max {
		if conn.have_recv {
			shift := seq - conn.recv_max
			recv_bits_shift(&conn.recv_bits, shift)
			recv_bits_set(&conn.recv_bits, shift - 1) // the previous newest
		} else {
			conn.recv_bits = {}
		}
		conn.recv_max = seq
		conn.have_recv = true
	} else if seq < conn.recv_max {
		recv_bits_set(&conn.recv_bits, conn.recv_max - seq - 1)
	}
}

// Moves the received seqs' bits `shift` seqs back (the newest seq moved on by that much).
@(private)
recv_bits_shift :: proc(bits: ^[1 + ACK_EXT_WORDS]u32, shift: u32) {
	words, bit := int(min(shift / 32, 1 + ACK_EXT_WORDS)), shift % 32
	for w := len(bits) - 1; w >= 0; w -= 1 {
		from := w - words
		value: u32
		if from >= 0 {
			value = bits[from] << bit
			if bit != 0 && from >= 1 {
				value |= bits[from - 1] >> (32 - bit)
			}
		}
		bits[w] = value
	}
}

@(private)
recv_bits_set :: proc(bits: ^[1 + ACK_EXT_WORDS]u32, index: u32) {
	if index < 32 * len(bits) {
		bits[index / 32] |= 1 << (index % 32)
	}
}

// Delivers the datagram's chunks: unreliable ones at once, reliable ones in id order (early ones wait
// within REL_WINDOW; duplicates and ids beyond the window are dropped).
@(private)
read_chunks :: proc(channel: ^Channel, conn: ^Conn, from: Peer, reader: ^wire.Reader, n_chunks: int, ack: u32) {
	for _ in 0 ..< n_chunks {
		kind := wire.r_u8(reader)
		id: u32
		if kind == 1 {
			id = wire.r_u32(reader)
		}
		data := wire.r_bytes(reader, int(wire.r_u16(reader)))
		if !reader.ok || kind > 2 {
			return
		}
		if kind == 2 {
			if ack != 0 do take_older_acks(channel, conn, ack, data)
			continue
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
				conn.rel_early[id] = pool_put(&channel.pool, data)
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
				data = arena_bytes(channel, pool_bytes(&channel.pool, early)),
			})
			pool_release(&channel.pool, early)
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
begin_packet :: proc(builder: ^Packet_Builder, conn: ^Conn, now: i64) {
	clear(&builder.w.buf)
	builder.count = 0
	builder.sp = {}
	back, delay := u8(0), max(u16) // no sample
	if conn.have_recv && conn.recv_max - conn.recent <= 32 {
		back = u8(conn.recv_max - conn.recent)
		delay = u16(min((now - conn.recent_at) / ACK_DELAY_UNIT_US, i64(max(u16))))
	}
	wire.w_u8(&builder.w, DGRAM_TAG)
	wire.w_u32(&builder.w, conn.epoch)
	wire.w_u32(&builder.w, conn.peer_epoch != 0 ? conn.peer_epoch : conn.opened)
	wire.w_u32(&builder.w, conn.next_seq)
	wire.w_u32(&builder.w, conn.have_recv ? conn.recv_max : 0)
	wire.w_u32(&builder.w, conn.recv_bits[0])
	wire.w_u8(&builder.w, back)
	wire.w_u16(&builder.w, delay)
	wire.w_u8(&builder.w, 0) // chunk count, patched in end_packet
	assert(len(builder.w.buf) == HEADER_BYTES)
}

@(private)
end_packet :: proc(channel: ^Channel, builder: ^Packet_Builder, conn: ^Conn, peer: Peer, now: i64) {
	// Seqs older than the header's 33 arrived since our last datagram (a burst, or reordered): ack them for a while.
	if conn.have_since && conn.have_recv && conn.recv_max - conn.low_since > 32 {
		conn.ext_until = now + ACK_EXT_HOLD_US
	}
	conn.have_since = false
	if now < conn.ext_until {
		words := 0
		for w in 1 ..< len(conn.recv_bits) {
			if conn.recv_bits[w] != 0 do words = w
		}
		if words > 0 && len(builder.w.buf) + 3 + 4 * words <= MAX_DATAGRAM && builder.count < 255 {
			wire.w_u8(&builder.w, 2)
			wire.w_u16(&builder.w, u16(4 * words))
			for w in 1 ..= words {
				wire.w_u32(&builder.w, conn.recv_bits[w])
			}
			builder.count += 1
		}
	}
	builder.w.buf[HEADER_BYTES - 1] = u8(builder.count)
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
		begin_packet(&builder, &conn, now)
		fits :: proc(builder: ^Packet_Builder, size: int) -> bool {
			return len(builder.w.buf) + size <= MAX_DATAGRAM && builder.count < 255 // a u8 chunk count
		}
		for held in conn.unrel_out {
			bytes := pool_bytes(&channel.pool, held)
			if !fits(&builder, 3 + len(bytes)) {
				end_packet(channel, &builder, &conn, peer, now)
				begin_packet(&builder, &conn, now)

			}
			wire.w_u8(&builder.w, 0)
			wire.w_u16(&builder.w, u16(len(bytes)))
			wire.w_bytes(&builder.w, bytes)
			builder.count += 1
			pool_release(&channel.pool, held)
		}
		clear(&conn.unrel_out)
		if elapsed := now - conn.rel_fill_us; elapsed > 0 {
			conn.rel_bucket = min(REL_BURST, conn.rel_bucket + elapsed * REL_RATE / 1_000_000)
			conn.rel_fill_us = now
		}
		for &message in conn.rel_out {
			if message.id - conn.rel_out[0].id >= REL_WINDOW {
				break // the receiver would drop it: wait for acks
			}
			if message.acked || (message.last_sent != 0 && now - message.last_sent < rto) {
				continue
			}
			data := pool_bytes(&channel.pool, message.data)
			if conn.rel_bucket < i64(CHUNK_OVERHEAD + len(data)) {
				break // paced: the rest goes as the bucket refills
			}
			if !fits(&builder, CHUNK_OVERHEAD + len(data)) || builder.sp.n_ids == MAX_IDS_PER_PACKET {
				end_packet(channel, &builder, &conn, peer, now)
				begin_packet(&builder, &conn, now)

			}
			if builder.sp.n_ids == 0 && !rel_room(&conn) {
				break // as many reliable datagrams in flight as one ack covers: wait for it
			}
			if message.last_sent != 0 {
				channel.stats.resends += 1
			}
			wire.w_u8(&builder.w, 1)
			wire.w_u32(&builder.w, message.id)
			wire.w_u16(&builder.w, u16(len(data)))
			wire.w_bytes(&builder.w, data)
			builder.count += 1
			builder.sp.ids[builder.sp.n_ids] = message.id
			builder.sp.n_ids += 1
			message.last_sent = now
			conn.rel_bucket -= i64(CHUNK_OVERHEAD + len(data))
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
