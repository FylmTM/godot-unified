// Datagram links: the unreliable bottom layer under the channel (channel.odin), and the interface
// a transport implements (loopback and UDP here, EOS P2P in its own package). A link moves whole
// datagrams of at most MAX_DATAGRAM bytes between peers it numbers itself, without blocking.
// Reliability, ordering, acks, keepalives and timeouts are the channel's job, the same on every
// link. netsim.odin wraps any link with simulated latency and loss.
package netcode

import "base:runtime"
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

// A platform account a transport vouches for (EOS: "eos" and the product user id): which person is behind a
// peer, whatever the client says. Host-side only: it never enters the sim, the log or the wire to the relay.
Account :: struct {
	platform: string,
	id:       string,
}

Link :: struct {
	data:    rawptr,
	// Queues one datagram to `to`. Losing it is allowed.
	send:    proc(data: rawptr, to: Peer, bytes: []u8),
	// Returns the next received datagram (copied into buf), or ok = false when there is none.
	// A datagram from a new remote endpoint gets a new Peer number.
	recv:    proc(data: rawptr, buf: []u8) -> (size: int, from: Peer, ok: bool),
	close:   proc(data: rawptr),
	// Optional: transport-level connection events (nil: the channel's own timeouts only).
	event:   proc(data: rawptr) -> (peer: Peer, kind: Link_Event_Kind, ok: bool),
	// Optional: the channel is done with `peer` (it timed out, left, or sent garbage); a link that
	// numbers remote endpoints itself (UDP) frees the number for the next endpoint.
	forget:  proc(data: rawptr, peer: Peer),
	// Optional: the account the transport vouches for behind `peer` (ok = false: none, as on LAN and direct UDP).
	// The strings are valid until the next call.
	account: proc(data: rawptr, peer: Peer) -> (account: Account, ok: bool),
}

link_account :: proc(link: ^Link, peer: Peer) -> (account: Account, ok: bool) {
	if link.account == nil {
		return
	}
	return link.account(link.data, peer)
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
		sleep_us(wait_us)
	}
}

// --- loopback --------------------------------------------------------------------------------------

// A datagram in a loopback queue: its bytes are `size` bytes at `offset` of the queue's byte buffer.
@(private)
Loop_Datagram :: struct {
	from:   Peer,
	offset: i32,
	size:   i32,
}

// Datagrams waiting for one endpoint: their headers and bytes, appended by senders and swapped out whole by the
// receiver, so a datagram costs no allocation once the buffers have grown (#262).
@(private)
Loop_Queue :: struct {
	datagrams: [dynamic]Loop_Datagram,
	bytes:     [dynamic]u8,
}

// In-process hub: endpoint i has an inbox that other threads append to under a mutex.
Hub :: struct {
	inboxes:   []Inbox,
	allocator: runtime.Allocator, // every queue's: a queue grown on one thread is swapped to another
}

Inbox :: struct {
	mu:    sync.Mutex,
	queue: Loop_Queue,
}

@(private)
loop_queue_make :: proc(allocator: runtime.Allocator) -> Loop_Queue {
	return {
		datagrams = make([dynamic]Loop_Datagram, 0, 16, allocator),
		bytes     = make([dynamic]u8, 0, 4 * MAX_DATAGRAM, allocator),
	}
}

@(private)
loop_queue_destroy :: proc(queue: ^Loop_Queue) {
	delete(queue.datagrams)
	delete(queue.bytes)
}

// Creates an in-process hub with `endpoints` inboxes for loopback links: the host's own client, headless sessions
// and tests run a relay and its clients in one process over it. Outlives every link made on it.
hub_create :: proc(endpoints: int) -> ^Hub {
	hub := new(Hub)
	hub.allocator = context.allocator
	hub.inboxes = make([]Inbox, endpoints)
	for &inbox in hub.inboxes {
		inbox.queue = loop_queue_make(hub.allocator)
	}
	return hub
}

// Frees the hub and any datagrams still queued; call it after every loopback link on it is closed.
hub_destroy :: proc(hub: ^Hub) {
	for &inbox in hub.inboxes {
		loop_queue_destroy(&inbox.queue)
	}
	delete(hub.inboxes)
	free(hub)
}

Loop_Link :: struct {
	hub:     ^Hub,
	self:    Peer,
	recv:    Loop_Queue, // swapped out of the inbox in one lock
	head:    int,
	account: Account, // what the link vouches for behind every peer (borrowed; empty: none)
}

// A link for endpoint `self` of the hub: a send to Peer i lands in endpoint i's inbox, with no loss or delay
// (wrap it with netsim_wrap for those). Links on different threads may share one hub. `account` (optional, borrowed
// for the link's life): the account it vouches for behind its peers (a host's relay end, for the host's own player).
loopback_link :: proc(hub: ^Hub, self: Peer, account := Account{}) -> Link {
	loop := new(Loop_Link)
	loop.hub = hub
	loop.self = self
	loop.recv = loop_queue_make(hub.allocator)
	loop.account = account
	return {
		data    = loop,
		send    = loop_send,
		recv    = loop_recv,
		close   = loop_close,
		account = account.id == "" ? nil : proc(data: rawptr, peer: Peer) -> (Account, bool) {
			return (^Loop_Link)(data).account, true
		},
	}
}

// Whether endpoint `endpoint`'s inbox holds datagrams its link hasn't taken yet.
@(private)
hub_pending :: proc(hub: ^Hub, endpoint: Peer) -> bool {
	inbox := &hub.inboxes[endpoint]
	sync.guard(&inbox.mu)
	return len(inbox.queue.datagrams) > 0
}

@(private)
loop_send :: proc(data: rawptr, to: Peer, bytes: []u8) {
	loop := (^Loop_Link)(data)
	if int(to) < 0 || int(to) >= len(loop.hub.inboxes) {
		return
	}
	inbox := &loop.hub.inboxes[to]
	sync.guard(&inbox.mu)
	offset := len(inbox.queue.bytes)
	append(&inbox.queue.bytes, ..bytes)
	append(&inbox.queue.datagrams, Loop_Datagram{from = loop.self, offset = i32(offset), size = i32(len(bytes))})
}

@(private)
loop_recv :: proc(data: rawptr, buf: []u8) -> (size: int, from: Peer, ok: bool) {
	loop := (^Loop_Link)(data)
	if loop.head >= len(loop.recv.datagrams) {
		clear(&loop.recv.datagrams)
		clear(&loop.recv.bytes)
		loop.head = 0
		inbox := &loop.hub.inboxes[loop.self]
		sync.guard(&inbox.mu)
		loop.recv, inbox.queue = inbox.queue, loop.recv
	}
	if loop.head >= len(loop.recv.datagrams) {
		return
	}
	datagram := loop.recv.datagrams[loop.head]
	loop.head += 1
	size = copy(buf, loop.recv.bytes[datagram.offset:][:datagram.size])
	return size, datagram.from, true
}

@(private)
loop_close :: proc(data: rawptr) {
	loop := (^Loop_Link)(data)
	loop_queue_destroy(&loop.recv)
	free(loop)
}
