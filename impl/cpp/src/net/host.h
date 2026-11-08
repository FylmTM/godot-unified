// Host: connections plus a minimal reliable channel over datagrams (sequence numbers, cumulative ack +
// 32-bit ack bitfield, RTO-based resend, fragmentation of large messages, in-order delivery).
//
// Datagram: magic u8, kind u8 (CONNECT/ACCEPT/DATA/BYE), token u32, then for DATA: ack u32 (next expected
// reliable seq), ack_bits u32 (bit i = seq ack+1+i received), and frames until the end:
//   0 unreliable: len u16, bytes          1/2 reliable fragment (2 = last): seq u32, len u16, bytes
#pragma once

#include <deque>
#include <map>
#include <memory>
#include <unordered_map>

#include "net/socket.h"
#include "net/transport.h"

namespace net {

class Host final : public Transport {
public:
    // accept_incoming: relay side (answers CONNECT); otherwise connect() opens connections.
    Host(std::unique_ptr<DatagramSocket> socket, bool accept_incoming);
    ~Host() override;

    PeerId connect(const Address& addr);
    void send(PeerId peer, const u8* data, usize size, Delivery delivery) override;
    void poll(std::vector<Event>& events) override;
    void disconnect(PeerId peer) override;

    // No reliable data waiting for an ack.
    bool reliable_idle(PeerId peer) const;
    // Round trip of the CONNECT/ACCEPT exchange (client side), 0 if unknown: the first RTT sample.
    u64 handshake_rtt_us(PeerId peer) const;
    Address local_address() const { return socket_->local_address(); }

    static constexpr u64 TIMEOUT_US = 8'000'000;

private:
    struct Fragment {
        u32 seq;
        bool last;
        std::vector<u8> data;
        u64 sent_us = 0; // 0 = never sent
        u32 sends = 0;
    };
    struct Peer {
        PeerId id;
        Address addr;
        u32 token;
        bool connected = false;
        u64 last_recv_us = 0;
        u64 last_connect_us = 0;
        u64 handshake_rtt_us = 0;
        u64 last_send_us = 0;
        // reliable send
        u32 next_seq = 0;
        std::deque<Fragment> unacked; // ascending seq
        f32 srtt_us = 0.0f;
        u64 rto_us = 200'000;
        // reliable receive
        u32 next_expected = 0;
        std::map<u32, Fragment> early;
        std::vector<u8> assembling;
        bool ack_due = false;
    };

    Peer* find(PeerId id);
    const Peer* find(PeerId id) const;
    Peer* find_addr(const Address& a);
    Peer& add_peer(const Address& a, u32 token);
    void handle(const Address& from, const u8* data, usize size, std::vector<Event>& events, u64 now);
    void handle_data(Peer& p, const u8* data, usize size, std::vector<Event>& events, u64 now);
    void process_acks(Peer& p, u32 ack, u32 bits, u64 now);
    void service(Peer& p, u64 now);
    void write_header(std::vector<u8>& out, u8 kind, const Peer& p);
    void write_data_header(std::vector<u8>& out, Peer& p);
    void raw_send(Peer& p, const std::vector<u8>& datagram, u64 now);
    void drop_peer(PeerId id, std::vector<Event>& events);

    std::unique_ptr<DatagramSocket> socket_;
    bool accept_incoming_;
    std::unordered_map<PeerId, std::unique_ptr<Peer>> peers_;
    std::vector<PeerId> pending_disconnects_;
    PeerId next_id_ = 1;
    u64 token_rng_;
    std::vector<u8> scratch_;
};

} // namespace net
