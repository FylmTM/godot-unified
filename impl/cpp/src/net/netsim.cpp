#include "net/netsim.h"

#include "core/platform.h"

namespace net {

bool profile_by_name(const std::string& name, Profile& out) {
    if (name == "ideal") {
        out = Profile{};
        return true;
    }
    if (name == "wan") {
        out = Profile{"wan", 50.0f, 15.0f, 0.02f, 0.01f, 0.01f};
        return true;
    }
    if (name == "bad") {
        out = Profile{"bad", 120.0f, 40.0f, 0.08f, 0.03f, 0.05f};
        return true;
    }
    return false;
}

NetSimSocket::NetSimSocket(std::unique_ptr<DatagramSocket> inner, const Profile& profile, u64 seed)
    : inner_(std::move(inner)), profile_(profile), rng_(seed ^ 0x9E3779B97F4A7C15ull) {}

f32 NetSimSocket::uniform() {
    // splitmix64
    u64 z = (rng_ += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    return (f32)(z >> 40) / (f32)(1u << 24);
}

void NetSimSocket::schedule(Direction& dir, const Address& addr, const u8* data, usize size, u64 now) {
    ++stats_.sent;
    if (uniform() < profile_.loss) {
        ++stats_.dropped;
        return;
    }
    int copies = 1;
    if (uniform() < profile_.duplicate) {
        copies = 2;
        ++stats_.duplicated;
    }
    for (int c = 0; c < copies; ++c) {
        f32 delay_ms = profile_.latency_ms + (uniform() * 2.0f - 1.0f) * profile_.jitter_ms;
        if (delay_ms < 0.0f) delay_ms = 0.0f;
        u64 due = now + (u64)(delay_ms * 1000.0f);
        if (uniform() < profile_.reorder) {
            // Held back past later packets, outside the FIFO order.
            ++stats_.reordered;
            due += (u64)((5.0f + uniform() * 35.0f) * 1000.0f);
        } else {
            // In order with the rest of this direction (jitter stretches, it doesn't reorder).
            if (due < dir.last_fifo_due) due = dir.last_fifo_due;
            dir.last_fifo_due = due;
        }
        dir.queue.push(Pending{due, order_++, addr, std::vector<u8>(data, data + size)});
    }
}

void NetSimSocket::pump(u64 now) {
    while (!out_.queue.empty() && out_.queue.top().due_us <= now) {
        const Pending& p = out_.queue.top();
        inner_->send_to(p.addr, p.data.data(), p.data.size());
        out_.queue.pop();
    }
    Address from;
    std::vector<u8> data;
    while (inner_->recv_from(from, data)) schedule(in_, from, data.data(), data.size(), now);
}

void NetSimSocket::send_to(const Address& to, const u8* data, usize size) {
    u64 now = uni::platform::now_us();
    schedule(out_, to, data, size, now);
    pump(now);
}

bool NetSimSocket::recv_from(Address& from, std::vector<u8>& data) {
    u64 now = uni::platform::now_us();
    pump(now);
    if (in_.queue.empty() || in_.queue.top().due_us > now) return false;
    // priority_queue::top is const; the element is popped right after, so moving out is safe.
    Pending& p = const_cast<Pending&>(in_.queue.top());
    from = p.addr;
    data = std::move(p.data);
    in_.queue.pop();
    return true;
}

} // namespace net
