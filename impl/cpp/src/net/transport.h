// The transport interface the netcode talks to (spec/CORE.md §2): send(peer, bytes, unreliable|reliable),
// poll() -> events, connect and disconnect events. Host (host.h) implements it over any DatagramSocket:
// loopback, UDP, or either wrapped in the network simulator.
#pragma once

#include <vector>

#include "core/base.h"

namespace net {

using PeerId = u32;
constexpr PeerId NO_PEER = 0;

enum class Delivery : u8 { Unreliable, Reliable };

struct Event {
    enum class Kind : u8 { Connected, Disconnected, Message };
    Kind kind;
    PeerId peer;
    std::vector<u8> data; // Message only
};

class Transport {
public:
    virtual ~Transport() = default;
    // Unreliable messages must fit one datagram (~1.2 KB); reliable ones may be any size (fragmented,
    // ordered, retransmitted).
    virtual void send(PeerId peer, const u8* data, usize size, Delivery delivery) = 0;
    // Receives, retransmits and acks; appends events in arrival order.
    virtual void poll(std::vector<Event>& events) = 0;
    virtual void disconnect(PeerId peer) = 0;
};

} // namespace net
