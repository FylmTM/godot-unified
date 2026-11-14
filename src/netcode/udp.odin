// UDP link over core:net. The relay side binds a port and numbers each new remote endpoint as a
// peer (1, 2, ...), reusing a number once the channel forgets its endpoint; the client side talks
// to one remote endpoint, peer 0. Sockets are non-blocking and polled.
package netcode

import cnet "core:net"

MAX_UDP_PEERS :: MAX_PEERS

Udp_Link :: struct {
	sock:      cnet.UDP_Socket,
	endpoints: [MAX_UDP_PEERS]cnet.Endpoint, // index = peer id
	used:      [MAX_UDP_PEERS]bool,
	fixed:     bool, // client: a single peer (0), packets from elsewhere are dropped
}

// Who can reach a listening socket. `.Local` (127.0.0.1) is for everything on one machine (tests, headless
// sessions, tool runs): the OS firewall never asks about it. `.Lan` (all interfaces) is for hosting players on other
// machines; on Windows the first such listen of each executable shows a firewall prompt.
Udp_Scope :: enum u8 {
	Local,
	Lan,
}

// Relay side: listens on `port` (0: any free port) in `scope`.
udp_listen :: proc(port: int, scope: Udp_Scope) -> (l: Link, ok: bool) {
	addr: cnet.Address = scope == .Lan ? cnet.IP4_Any : cnet.IP4_Loopback
	sock, err := cnet.make_bound_udp_socket(addr, port)
	if err != nil {
		return
	}
	if cnet.set_blocking(sock, false) != nil {
		cnet.close(sock)
		return
	}
	ul := new(Udp_Link)
	ul.sock = sock
	ul.used[0] = true // peer 0 is unused on the relay side
	return {data = ul, send = udp_send, recv = udp_recv, close = udp_close, forget = udp_forget}, true
}

// Client side: an ephemeral local port talking to `remote` (peer 0). A loopback remote gets a loopback socket, so
// a local client never triggers a firewall prompt either.
udp_connect :: proc(remote: cnet.Endpoint) -> (l: Link, ok: bool) {
	local: cnet.Address = cnet.IP4_Any
	switch a in remote.address {
	case cnet.IP4_Address:
		if a[0] == 127 do local = cnet.IP4_Loopback
	case cnet.IP6_Address:
		local = a == cnet.IP6_Loopback ? cnet.IP6_Loopback : cnet.IP6_Any
	}
	sock, err := cnet.make_bound_udp_socket(local, 0)
	if err != nil {
		return
	}
	if cnet.set_blocking(sock, false) != nil {
		cnet.close(sock)
		return
	}
	ul := new(Udp_Link)
	ul.sock = sock
	ul.fixed = true
	ul.endpoints[0] = remote
	ul.used[0] = true
	return {data = ul, send = udp_send, recv = udp_recv, close = udp_close}, true
}

udp_bound_port :: proc(l: ^Link) -> int {
	ul := (^Udp_Link)(l.data)
	ep, err := cnet.bound_endpoint(ul.sock)
	return err == nil ? ep.port : 0
}

@(private)
endpoint_eq :: proc(a, b: cnet.Endpoint) -> bool {
	if a.port != b.port {
		return false
	}
	switch x in a.address {
	case cnet.IP4_Address:
		y, ok := b.address.(cnet.IP4_Address)
		return ok && x == y
	case cnet.IP6_Address:
		y, ok := b.address.(cnet.IP6_Address)
		return ok && x == y
	}
	return false
}

@(private)
udp_send :: proc(data: rawptr, to: Peer, bytes: []u8) {
	ul := (^Udp_Link)(data)
	if int(to) < 0 || int(to) >= MAX_UDP_PEERS || !ul.used[to] || (!ul.fixed && to == 0) {
		return
	}
	// Errors (e.g. a full send buffer, or ICMP-unreachable reported on a later call) are packet
	// loss as far as the channel is concerned.
	_, _ = cnet.send_udp(ul.sock, bytes, ul.endpoints[to])
}

@(private)
udp_recv :: proc(data: rawptr, buf: []u8) -> (n: int, from: Peer, ok: bool) {
	ul := (^Udp_Link)(data)
	// Windows reports an ICMP port-unreachable for an earlier send as WSAECONNRESET on recvfrom of
	// an unconnected UDP socket; skip such errors instead of treating them as "no data".
	for _ in 0 ..< 64 {
		nr, ep, err := cnet.recv_udp(ul.sock, buf)
		if err != nil {
			if err == .Would_Block || err == .Timeout {
				return
			}
			continue
		}
		free_slot := -1
		for e, i in ul.endpoints {
			if !ul.used[i] {
				free_slot = free_slot < 0 ? i : free_slot
			} else if (ul.fixed || i > 0) && endpoint_eq(e, ep) {
				return nr, Peer(i), true
			}
		}
		if ul.fixed || free_slot < 0 {
			continue
		}
		ul.endpoints[free_slot] = ep
		ul.used[free_slot] = true
		return nr, Peer(free_slot), true
	}
	return
}

@(private)
udp_forget :: proc(data: rawptr, peer: Peer) {
	ul := (^Udp_Link)(data)
	if !ul.fixed && peer > 0 && int(peer) < MAX_UDP_PEERS {
		ul.used[peer] = false
		ul.endpoints[peer] = {}
	}
}

@(private)
udp_close :: proc(data: rawptr) {
	ul := (^Udp_Link)(data)
	cnet.close(ul.sock)
	free(ul)
}
