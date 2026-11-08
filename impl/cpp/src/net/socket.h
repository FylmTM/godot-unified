// Datagram sockets: the bottom of the transport stack. Implementations: UDP (socket_posix.cpp /
// socket_win.cpp), in-process loopback (loopback.h) and the network simulator wrapper (netsim.h).
// All are non-blocking and polled.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "core/base.h"

namespace net {

// IPv4 address + port (host byte order). Loopback sockets use ip 0 and the port as an endpoint id.
struct Address {
    u32 ip = 0;
    u16 port = 0;

    friend bool operator==(const Address&, const Address&) = default;
    u64 key() const { return ((u64)ip << 16) | port; }
};

std::string to_string(const Address& a);
// "HOST:PORT" with an IPv4 literal or a resolvable name (IPv4 only).
bool parse_host_port(const std::string& s, Address& out);

constexpr usize MAX_DATAGRAM = 1400;

class DatagramSocket {
public:
    virtual ~DatagramSocket() = default;
    virtual void send_to(const Address& to, const u8* data, usize size) = 0;
    // Non-blocking: returns false when nothing is pending.
    virtual bool recv_from(Address& from, std::vector<u8>& data) = 0;
    virtual Address local_address() const = 0;
};

// Binds a UDP socket (port 0 = ephemeral). Returns null and sets `error` on failure.
std::unique_ptr<DatagramSocket> open_udp(const Address& bind_addr, std::string& error);

} // namespace net
