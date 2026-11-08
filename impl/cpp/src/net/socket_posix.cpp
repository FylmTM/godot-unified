// UDP on macOS and Linux (BSD sockets).
#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

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
    explicit UdpSocket(int fd) : fd_(fd) {}
    ~UdpSocket() override { ::close(fd_); }

    void send_to(const Address& to, const u8* data, usize size) override {
        sockaddr_in sa = to_sockaddr(to);
        // Best effort, like any datagram: a full buffer or an unreachable peer just drops the packet.
        (void)::sendto(fd_, data, size, 0, reinterpret_cast<const sockaddr*>(&sa), sizeof sa);
    }

    bool recv_from(Address& from, std::vector<u8>& data) override {
        u8 buf[MAX_DATAGRAM + 64];
        for (;;) {
            sockaddr_in sa{};
            socklen_t len = sizeof sa;
            ssize_t n = ::recvfrom(fd_, buf, sizeof buf, 0, reinterpret_cast<sockaddr*>(&sa), &len);
            if (n < 0) {
                if (errno == EINTR) continue;
                return false; // EAGAIN/EWOULDBLOCK, or a transient error (e.g. ECONNREFUSED from ICMP)
            }
            from.ip = ntohl(sa.sin_addr.s_addr);
            from.port = ntohs(sa.sin_port);
            data.assign(buf, buf + n);
            return true;
        }
    }

    Address local_address() const override {
        sockaddr_in sa{};
        socklen_t len = sizeof sa;
        ::getsockname(fd_, reinterpret_cast<sockaddr*>(&sa), &len);
        return Address{ntohl(sa.sin_addr.s_addr), ntohs(sa.sin_port)};
    }

private:
    int fd_;
};

} // namespace

std::unique_ptr<DatagramSocket> open_udp(const Address& bind_addr, std::string& error) {
    int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        error = std::string("socket: ") + std::strerror(errno);
        return nullptr;
    }
    int flags = ::fcntl(fd, F_GETFL, 0);
    ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int buf = 1 << 20;
    ::setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof buf);
    ::setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, sizeof buf);
    sockaddr_in sa = to_sockaddr(bind_addr);
    if (::bind(fd, reinterpret_cast<const sockaddr*>(&sa), sizeof sa) != 0) {
        error = std::string("bind ") + to_string(bind_addr) + ": " + std::strerror(errno);
        ::close(fd);
        return nullptr;
    }
    return std::make_unique<UdpSocket>(fd);
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
