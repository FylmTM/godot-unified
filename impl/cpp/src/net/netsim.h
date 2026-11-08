// Network simulator: a DatagramSocket decorator that delays, drops, duplicates and reorders datagrams in
// both directions, driven by a seeded RNG (the fate of every datagram is reproducible; arrival timing
// follows the real monotonic clock). It sits below the reliability layer, so reliable messages see the
// same loss as unreliable ones.
#pragma once

#include <functional>
#include <queue>
#include <string>

#include "net/socket.h"

namespace net {

struct Profile {
    const char* name = "ideal";
    f32 latency_ms = 0.0f; // one way
    f32 jitter_ms = 0.0f;  // uniform +-
    f32 loss = 0.0f;
    f32 duplicate = 0.0f;
    f32 reorder = 0.0f;

    bool ideal() const { return latency_ms == 0.0f && loss == 0.0f && duplicate == 0.0f && reorder == 0.0f; }
};

// ideal | wan | bad (spec/CORE.md §3). Returns false for an unknown name.
bool profile_by_name(const std::string& name, Profile& out);

class NetSimSocket final : public DatagramSocket {
public:
    NetSimSocket(std::unique_ptr<DatagramSocket> inner, const Profile& profile, u64 seed);

    void send_to(const Address& to, const u8* data, usize size) override;
    bool recv_from(Address& from, std::vector<u8>& data) override;
    Address local_address() const override { return inner_->local_address(); }

    struct Stats {
        u64 sent = 0, dropped = 0, duplicated = 0, reordered = 0;
    };
    const Stats& stats() const { return stats_; }

private:
    struct Pending {
        u64 due_us;
        u64 order; // FIFO among equal due times
        Address addr;
        std::vector<u8> data;
        bool operator>(const Pending& o) const { return due_us != o.due_us ? due_us > o.due_us : order > o.order; }
    };
    using Queue = std::priority_queue<Pending, std::vector<Pending>, std::greater<Pending>>;

    struct Direction {
        Queue queue;
        u64 last_fifo_due = 0;
    };
    void schedule(Direction& dir, const Address& addr, const u8* data, usize size, u64 now);
    void pump(u64 now);
    f32 uniform(); // [0, 1)

    std::unique_ptr<DatagramSocket> inner_;
    Profile profile_;
    u64 rng_;
    u64 order_ = 0;
    Direction out_, in_;
    Stats stats_;
};

} // namespace net
