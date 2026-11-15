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
	recv:   proc(data: rawptr, buf: []u8) -> (size: int, from: Peer, ok: bool),
	close:  proc(data: rawptr),
	// Optional: transport-level connection events (nil: the channel's own timeouts only).
	event:  proc(data: rawptr) -> (peer: Peer, kind: Link_Event_Kind, ok: bool),
	// Optional: the channel is done with `peer` (it timed out, left, or sent garbage); a link that
	// numbers remote endpoints itself (UDP) frees the number for the next endpoint.
	forget: proc(data: rawptr, peer: Peer),
}

// Hands one datagram to the link's transport; the channel calls it and owns resending what is lost.
link_send :: proc(link: ^Link, to: Peer, bytes: []u8) {
	link.send(link.data, to, bytes)
}

// Takes the next datagram the link received, if any, without blocking; the channel drains it on every poll.
link_recv :: proc(link: ^Link, buf: []u8) -> (size: int, from: Peer, ok: bool) {
	return link.recv(link.data, buf)
}

// Tells the link the channel is done with `peer`, so a link that numbers endpoints can reuse it (a no-op if not).
link_forget :: proc(link: ^Link, peer: Peer) {
	if link.forget != nil {
		link.forget(link.data, peer)
	}
}

// Closes the link and frees its transport state; channel_destroy calls it for every link the channel owns.
link_close :: proc(link: ^Link) {
	if link.close != nil {
		link.close(link.data)
	}
}

// Monotonic microseconds: the time base every *_step call takes.
now_us :: proc() -> i64 {
	return time.tick_now()._nsec / 1000
}

// Sleeps until `wake_us` (a now_us value); returns at once if it has passed.
sleep_until :: proc(wake_us: i64) {
	if wait_us := wake_us - now_us(); wait_us > 0 {
		time.sleep(time.Duration(wait_us) * time.Microsecond)
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

// Creates an in-process hub with `endpoints` inboxes for loopback links: the host's own client, headless sessions
// and tests run a relay and its clients in one process over it. Outlives every link made on it.
hub_create :: proc(endpoints: int) -> ^Hub {
	hub := new(Hub)
	hub.inboxes = make([]Inbox, endpoints)
	return hub
}

// Frees the hub and any datagrams still queued; call it after every loopback link on it is closed.
hub_destroy :: proc(hub: ^Hub) {
	for &inbox in hub.inboxes {
		for datagram in inbox.queue {
			delete(datagram.bytes)
		}
		delete(inbox.queue)
	}
	delete(hub.inboxes)
	free(hub)
}

Loop_Link :: struct {
	hub:  ^Hub,
	self: Peer,
	recv: [dynamic]Datagram, // swapped out of the inbox in one lock
	head: int,
}

// A link for endpoint `self` of the hub: a send to Peer i lands in endpoint i's inbox, with no loss or delay
// (wrap it with netsim_wrap for those). Links on different threads may share one hub.
loopback_link :: proc(hub: ^Hub, self: Peer) -> Link {
	loop := new(Loop_Link)
	loop.hub = hub
	loop.self = self
	return {
		data  = loop,
		send  = loop_send,
		recv  = loop_recv,
		close = loop_close,
	}
}

@(private)
loop_send :: proc(data: rawptr, to: Peer, bytes: []u8) {
	loop := (^Loop_Link)(data)
	if int(to) < 0 || int(to) >= len(loop.hub.inboxes) {
		return
	}
	inbox := &loop.hub.inboxes[to]
	copied := make([]u8, len(bytes), context.allocator)
	mem.copy_non_overlapping(raw_data(copied), raw_data(bytes), len(bytes))
	sync.guard(&inbox.mu)
	append(&inbox.queue, Datagram{from = loop.self, bytes = copied})
}

@(private)
loop_recv :: proc(data: rawptr, buf: []u8) -> (size: int, from: Peer, ok: bool) {
	loop := (^Loop_Link)(data)
	if loop.head >= len(loop.recv) {
		for datagram in loop.recv {
			delete(datagram.bytes)
		}
		clear(&loop.recv)
		loop.head = 0
		inbox := &loop.hub.inboxes[loop.self]
		sync.guard(&inbox.mu)
		loop.recv, inbox.queue = inbox.queue, loop.recv
	}
	if loop.head >= len(loop.recv) {
		return
	}
	datagram := loop.recv[loop.head]
	loop.head += 1
	size = copy(buf, datagram.bytes)
	return size, datagram.from, true
}

@(private)
loop_close :: proc(data: rawptr) {
	loop := (^Loop_Link)(data)
	for datagram in loop.recv {
		delete(datagram.bytes)
	}
	delete(loop.recv)
	free(loop)
}
