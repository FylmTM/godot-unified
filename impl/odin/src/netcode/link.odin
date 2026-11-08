// Datagram links: the unreliable bottom layer under the channel (channel.odin). A link moves
// whole datagrams between numbered peers, without blocking. Implementations: an in-process
// loopback hub and UDP sockets; netsim.odin wraps either one.
package netcode

import "core:mem"
import "core:sync"
import "core:time"

Peer :: distinct i32

MAX_DATAGRAM :: 1400

Link :: struct {
	data: rawptr,
	// Queues one datagram to `to`. Losing it is allowed.
	send: proc(data: rawptr, to: Peer, bytes: []u8),
	// Returns the next received datagram (copied into buf), or ok = false when there is none.
	recv: proc(data: rawptr, buf: []u8) -> (n: int, from: Peer, ok: bool),
	close: proc(data: rawptr),
}

link_send :: proc(l: ^Link, to: Peer, bytes: []u8) {
	l.send(l.data, to, bytes)
}

link_recv :: proc(l: ^Link, buf: []u8) -> (n: int, from: Peer, ok: bool) {
	return l.recv(l.data, buf)
}

link_close :: proc(l: ^Link) {
	if l.close != nil {
		l.close(l.data)
	}
}

now_tick :: proc() -> time.Tick {
	return time.tick_now()
}

now_us :: proc() -> i64 {
	return time.tick_now()._nsec / 1000
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
