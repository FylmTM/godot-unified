// UDP link over core:net. The relay side binds a port and numbers each new remote endpoint as a
// peer (1, 2, ...), reusing a number once the channel forgets its endpoint; the client side talks
// to one remote endpoint, peer 0. Sockets are non-blocking and polled.
package netcode

import cnet "core:net"

@(private)
MAX_UDP_PEERS :: MAX_PEERS

// A UDP link's state (udp_listen, udp_connect): its non-blocking socket and the endpoints it numbered as peers.
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
udp_listen :: proc(port: int, scope: Udp_Scope) -> (link: Link, ok: bool) {
	address: cnet.Address = scope == .Lan ? cnet.IP4_Any : cnet.IP4_Loopback
	sock, err := cnet.make_bound_udp_socket(address, port)
	if err != nil {
		return
	}
	if cnet.set_blocking(sock, false) != nil {
		cnet.close(sock)
		return
	}
	udp := new(Udp_Link)
	udp.sock = sock
	udp.used[0] = true // peer 0 is unused on the relay side
	return {
			data   = udp,
			send   = udp_send,
			recv   = udp_recv,
			close  = udp_close,
			forget = udp_forget,
		}, true
}

// Client side: an ephemeral local port talking to `remote` (peer 0). A loopback remote gets a loopback socket, so
// a local client never triggers a firewall prompt either.
udp_connect :: proc(remote: cnet.Endpoint) -> (link: Link, ok: bool) {
	local: cnet.Address = cnet.IP4_Any
	switch address in remote.address {
	case cnet.IP4_Address:
		if address[0] == 127 do local = cnet.IP4_Loopback
	case cnet.IP6_Address:
		local = address == cnet.IP6_Loopback ? cnet.IP6_Loopback : cnet.IP6_Any
	}
	sock, err := cnet.make_bound_udp_socket(local, 0)
	if err != nil {
		return
	}
	if cnet.set_blocking(sock, false) != nil {
		cnet.close(sock)
		return
	}
	udp := new(Udp_Link)
	udp.sock = sock
	udp.fixed = true
	udp.endpoints[0] = remote
	udp.used[0] = true
	return {
			data  = udp,
			send  = udp_send,
			recv  = udp_recv,
			close = udp_close,
		}, true
}

// The local port a UDP link's socket is bound to (0 if unknown): after udp_listen(0, ...) it is the port
// to tell clients (the lobby code, a headless session's clients).
udp_bound_port :: proc(link: ^Link) -> int {
	udp := (^Udp_Link)(link.data)
	endpoint, err := cnet.bound_endpoint(udp.sock)
	return err == nil ? endpoint.port : 0
}

@(private)
endpoint_eq :: proc(a, b: cnet.Endpoint) -> bool {
	if a.port != b.port {
		return false
	}
	switch address in a.address {
	case cnet.IP4_Address:
		other, ok := b.address.(cnet.IP4_Address)
		return ok && address == other
	case cnet.IP6_Address:
		other, ok := b.address.(cnet.IP6_Address)
		return ok && address == other
	}
	return false
}

@(private)
udp_send :: proc(data: rawptr, to: Peer, bytes: []u8) {
	udp := (^Udp_Link)(data)
	if int(to) < 0 || int(to) >= MAX_UDP_PEERS || !udp.used[to] || (!udp.fixed && to == 0) {
		return
	}
	// Errors (e.g. a full send buffer, or ICMP-unreachable reported on a later call) are packet
	// loss as far as the channel is concerned.
	_, _ = cnet.send_udp(udp.sock, bytes, udp.endpoints[to])
}

@(private)
udp_recv :: proc(data: rawptr, buf: []u8) -> (size: int, from: Peer, ok: bool) {
	udp := (^Udp_Link)(data)
	// Windows reports an ICMP port-unreachable for an earlier send as WSAECONNRESET on recvfrom of
	// an unconnected UDP socket; skip such errors instead of treating them as "no data".
	for _ in 0 ..< 64 {
		received, endpoint, err := cnet.recv_udp(udp.sock, buf)
		if err != nil {
			if err == .Would_Block || err == .Timeout {
				return
			}
			continue
		}
		free_slot := -1
		for known, i in udp.endpoints {
			if !udp.used[i] {
				free_slot = free_slot < 0 ? i : free_slot
			} else if (udp.fixed || i > 0) && endpoint_eq(known, endpoint) {
				return received, Peer(i), true
			}
		}
		if udp.fixed || free_slot < 0 {
			continue
		}
		udp.endpoints[free_slot] = endpoint
		udp.used[free_slot] = true
		return received, Peer(free_slot), true
	}
	return
}

@(private)
udp_forget :: proc(data: rawptr, peer: Peer) {
	udp := (^Udp_Link)(data)
	if !udp.fixed && peer > 0 && int(peer) < MAX_UDP_PEERS {
		udp.used[peer] = false
		udp.endpoints[peer] = {}
	}
}

@(private)
udp_close :: proc(data: rawptr) {
	udp := (^Udp_Link)(data)
	cnet.close(udp.sock)
	free(udp)
}
