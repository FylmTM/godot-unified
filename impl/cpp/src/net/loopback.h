// In-process datagram "network": a hub of mailboxes keyed by port. Lossless and instant; wrap the client
// end in a NetSimSocket for latency and loss.
#pragma once

#include <deque>
#include <map>
#include <memory>
#include <mutex>

#include "net/socket.h"

namespace net {

class LoopbackHub {
public:
    // port 0 picks a free one. The hub must outlive its sockets.
    std::unique_ptr<DatagramSocket> open(u16 port = 0);

private:
    friend class LoopbackSocket;
    struct Packet {
        Address from;
        std::vector<u8> data;
    };
    struct Mailbox {
        std::deque<Packet> packets;
    };
    void deliver(const Address& from, const Address& to, const u8* data, usize size);
    bool take(u16 port, Address& from, std::vector<u8>& data);
    void close(u16 port);

    std::mutex mutex_;
    std::map<u16, Mailbox> boxes_;
    u16 next_port_ = 1000;
};

} // namespace net
