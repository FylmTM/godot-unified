// UDP link over core:net. The relay side binds a port and numbers each new remote endpoint as a
// peer (1, 2, ...); the client side talks to one remote endpoint, peer 0. Sockets are
// non-blocking and polled.
package netcode

import cnet "core:net"

RELAY_PEER :: Peer(0)
MAX_UDP_PEERS :: 16

Udp_Link :: struct {
	sock:      cnet.UDP_Socket,
	endpoints: [dynamic]cnet.Endpoint, // index = peer id
	fixed:     bool, // client: a single peer, packets from elsewhere are dropped
}

// Relay side: listens on `port` on all interfaces.
udp_listen :: proc(port: int) -> (l: Link, ok: bool) {
	sock, err := cnet.make_bound_udp_socket(cnet.IP4_Any, port)
	if err != nil {
		return
	}
	if cnet.set_blocking(sock, false) != nil {
		cnet.close(sock)
		return
	}
	ul := new(Udp_Link)
	ul.sock = sock
	append(&ul.endpoints, cnet.Endpoint{}) // peer 0 is unused on the relay side
	return {data = ul, send = udp_send, recv = udp_recv, close = udp_close}, true
}

// Client side: an ephemeral local port talking to `remote` (peer 0).
udp_connect :: proc(remote: cnet.Endpoint) -> (l: Link, ok: bool) {
	any_addr: cnet.Address = cnet.IP4_Any
	if _, is6 := remote.address.(cnet.IP6_Address); is6 {
		any_addr = cnet.IP6_Any
	}
	sock, err := cnet.make_bound_udp_socket(any_addr, 0)
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
	append(&ul.endpoints, remote)
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
	if int(to) < 0 || int(to) >= len(ul.endpoints) || (!ul.fixed && to == 0) {
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
		for e, i in ul.endpoints {
			if (ul.fixed || i > 0) && endpoint_eq(e, ep) {
				return nr, Peer(i), true
			}
		}
		if ul.fixed || len(ul.endpoints) >= MAX_UDP_PEERS {
			continue
		}
		append(&ul.endpoints, ep)
		return nr, Peer(len(ul.endpoints) - 1), true
	}
	return
}

@(private)
udp_close :: proc(data: rawptr) {
	ul := (^Udp_Link)(data)
	cnet.close(ul.sock)
	delete(ul.endpoints)
	free(ul)
}
