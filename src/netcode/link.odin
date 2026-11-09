// Datagram links: the unreliable bottom layer under the channel (channel.odin), and the interface
// a transport implements (loopback and UDP here, EOS P2P in its own package). A link moves whole
// datagrams of at most MAX_DATAGRAM bytes between peers it numbers itself, without blocking.
// Reliability, ordering, acks, keepalives and timeouts are the channel's job, the same on every
// link. netsim.odin wraps any link with simulated latency and loss.
package netcode

import "core:mem"
import "core:sync"
import "core:time"

// A link's own number for a remote endpoint (>= 0). A client-side link talks to one peer, 0.
Peer :: distinct i32

// Fits EOS P2P packets (1170 bytes) and every common UDP path.
MAX_DATAGRAM :: 1152

Link_Event_Kind :: enum u8 {
	Connected,
	Disconnected, // the transport knows the peer is gone (the channel then drops it at once)
}

Link :: struct {
	data:   rawptr,
	// Queues one datagram to `to`. Losing it is allowed.
	send:   proc(data: rawptr, to: Peer, bytes: []u8),
	// Returns the next received datagram (copied into buf), or ok = false when there is none.
	// A datagram from a new remote endpoint gets a new Peer number.
	recv:   proc(data: rawptr, buf: []u8) -> (n: int, from: Peer, ok: bool),
	close:  proc(data: rawptr),
	// Optional: transport-level connection events (nil: the channel's own timeouts only).
	event:  proc(data: rawptr) -> (peer: Peer, kind: Link_Event_Kind, ok: bool),
	// Optional: the channel is done with `peer` (it timed out, left, or sent garbage); a link that
	// numbers remote endpoints itself (UDP) frees the number for the next endpoint.
	forget: proc(data: rawptr, peer: Peer),
}

link_send :: proc(l: ^Link, to: Peer, bytes: []u8) {
	l.send(l.data, to, bytes)
}

link_recv :: proc(l: ^Link, buf: []u8) -> (n: int, from: Peer, ok: bool) {
	return l.recv(l.data, buf)
}

link_forget :: proc(l: ^Link, peer: Peer) {
	if l.forget != nil {
		l.forget(l.data, peer)
	}
}

link_close :: proc(l: ^Link) {
	if l.close != nil {
		l.close(l.data)
	}
}

// Monotonic microseconds: the time base every *_step call takes.
now_us :: proc() -> i64 {
	return time.tick_now()._nsec / 1000
}

// Sleeps until `wake_us` (a now_us value); returns at once if it has passed.
sleep_until :: proc(wake_us: i64) {
	if d := wake_us - now_us(); d > 0 {
		time.sleep(time.Duration(d) * time.Microsecond)
	}
}

// --- loopback --------------------------------------------------------------------------------------

Datagram :: struct {
	from:  Peer,
	at:    i64, // netsim: delivery time (µs); loopback: unused
	bytes: []u8,
}

// In-process hub: endpoint i has an inbox that other threads append to under a mutex.
Hub :: struct {
	inboxes: []Inbox,
}

Inbox :: struct {
	mu:    sync.Mutex,
	queue: [dynamic]Datagram,
}

hub_create :: proc(endpoints: int) -> ^Hub {
	h := new(Hub)
	h.inboxes = make([]Inbox, endpoints)
	return h
}

hub_destroy :: proc(h: ^Hub) {
	for &ib in h.inboxes {
		for d in ib.queue {
			delete(d.bytes)
		}
		delete(ib.queue)
	}
	delete(h.inboxes)
	free(h)
}

Loop_Link :: struct {
	hub:  ^Hub,
	self: Peer,
	recv: [dynamic]Datagram, // swapped out of the inbox in one lock
	head: int,
}

loopback_link :: proc(h: ^Hub, self: Peer) -> Link {
	ll := new(Loop_Link)
	ll.hub = h
	ll.self = self
	return {data = ll, send = loop_send, recv = loop_recv, close = loop_close}
}

@(private)
loop_send :: proc(data: rawptr, to: Peer, bytes: []u8) {
	ll := (^Loop_Link)(data)
	if int(to) < 0 || int(to) >= len(ll.hub.inboxes) {
		return
	}
	ib := &ll.hub.inboxes[to]
	copy_ := make([]u8, len(bytes), context.allocator)
	mem.copy_non_overlapping(raw_data(copy_), raw_data(bytes), len(bytes))
	sync.guard(&ib.mu)
	append(&ib.queue, Datagram{from = ll.self, bytes = copy_})
}

@(private)
loop_recv :: proc(data: rawptr, buf: []u8) -> (n: int, from: Peer, ok: bool) {
	ll := (^Loop_Link)(data)
	if ll.head >= len(ll.recv) {
		for d in ll.recv {
			delete(d.bytes)
		}
		clear(&ll.recv)
		ll.head = 0
		ib := &ll.hub.inboxes[ll.self]
		sync.guard(&ib.mu)
		ll.recv, ib.queue = ib.queue, ll.recv
	}
	if ll.head >= len(ll.recv) {
		return
	}
	d := ll.recv[ll.head]
	ll.head += 1
	n = copy(buf, d.bytes)
	return n, d.from, true
}

@(private)
loop_close :: proc(data: rawptr) {
	ll := (^Loop_Link)(data)
	for d in ll.recv {
		delete(d.bytes)
	}
	delete(ll.recv)
	free(ll)
}
