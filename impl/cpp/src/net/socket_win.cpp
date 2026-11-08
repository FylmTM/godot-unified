// UDP on Windows (Winsock 2). WSAStartup happens in platform::init().
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mstcpip.h>

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif

#include <cstdio>
#include <cstdlib>

#include "net/socket.h"

namespace net {

namespace {

sockaddr_in to_sockaddr(const Address& a) {
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(a.ip);
    sa.sin_port = htons(a.port);
    return sa;
}

class UdpSocket final : public DatagramSocket {
public:
    explicit UdpSocket(SOCKET s) : s_(s) {}
    ~UdpSocket() override { ::closesocket(s_); }

    void send_to(const Address& to, const u8* data, usize size) override {
        sockaddr_in sa = to_sockaddr(to);
        (void)::sendto(s_, reinterpret_cast<const char*>(data), (int)size, 0, reinterpret_cast<const sockaddr*>(&sa),
                       (int)sizeof sa);
    }

    bool recv_from(Address& from, std::vector<u8>& data) override {
        char buf[MAX_DATAGRAM + 64];
        for (;;) {
            sockaddr_in sa{};
            int len = (int)sizeof sa;
            int n = ::recvfrom(s_, buf, (int)sizeof buf, 0, reinterpret_cast<sockaddr*>(&sa), &len);
            if (n == SOCKET_ERROR) {
                int err = ::WSAGetLastError();
                // An ICMP "port unreachable" for an earlier send surfaces here on Windows; skip it.
                if (err == WSAECONNRESET || err == WSAEMSGSIZE) continue;
                return false; // WSAEWOULDBLOCK or a transient error
            }
            from.ip = ntohl(sa.sin_addr.s_addr);
            from.port = ntohs(sa.sin_port);
            data.assign(reinterpret_cast<u8*>(buf), reinterpret_cast<u8*>(buf) + n);
            return true;
        }
    }

    Address local_address() const override {
        sockaddr_in sa{};
        int len = (int)sizeof sa;
        ::getsockname(s_, reinterpret_cast<sockaddr*>(&sa), &len);
        return Address{ntohl(sa.sin_addr.s_addr), ntohs(sa.sin_port)};
    }

private:
    SOCKET s_;
};

} // namespace

std::unique_ptr<DatagramSocket> open_udp(const Address& bind_addr, std::string& error) {
    SOCKET s = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) {
        error = "socket failed: " + std::to_string(::WSAGetLastError());
        return nullptr;
    }
    u_long nonblocking = 1;
    ::ioctlsocket(s, FIONBIO, &nonblocking);
    // Don't let ICMP port-unreachable reset the socket (WSAECONNRESET on every later recvfrom).
    BOOL report = FALSE;
    DWORD bytes = 0;
    ::WSAIoctl(s, SIO_UDP_CONNRESET, &report, sizeof report, nullptr, 0, &bytes, nullptr, nullptr);
    int buf = 1 << 20;
    ::setsockopt(s, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char*>(&buf), (int)sizeof buf);
    ::setsockopt(s, SOL_SOCKET, SO_SNDBUF, reinterpret_cast<const char*>(&buf), (int)sizeof buf);
    sockaddr_in sa = to_sockaddr(bind_addr);
    if (::bind(s, reinterpret_cast<const sockaddr*>(&sa), (int)sizeof sa) != 0) {
        error = "bind " + to_string(bind_addr) + " failed: " + std::to_string(::WSAGetLastError());
        ::closesocket(s);
        return nullptr;
    }
    return std::make_unique<UdpSocket>(s);
}

std::string to_string(const Address& a) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%u.%u.%u.%u:%u", (a.ip >> 24) & 255u, (a.ip >> 16) & 255u, (a.ip >> 8) & 255u,
                  a.ip & 255u, (unsigned)a.port);
    return buf;
}

bool parse_host_port(const std::string& s, Address& out) {
    usize colon = s.rfind(':');
    if (colon == std::string::npos) return false;
    std::string host = s.substr(0, colon);
    int port = std::atoi(s.c_str() + colon + 1);
    if (port <= 0 || port > 65535) return false;
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    addrinfo* res = nullptr;
    if (::getaddrinfo(host.c_str(), nullptr, &hints, &res) != 0 || !res) return false;
    out.ip = ntohl(reinterpret_cast<sockaddr_in*>(res->ai_addr)->sin_addr.s_addr);
    out.port = (u16)port;
    ::freeaddrinfo(res);
    return true;
}

} // namespace net
