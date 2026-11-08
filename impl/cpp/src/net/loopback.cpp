#include "net/loopback.h"

namespace net {

class LoopbackSocket final : public DatagramSocket {
public:
    LoopbackSocket(LoopbackHub& hub, u16 port) : hub_(hub), port_(port) {}
    ~LoopbackSocket() override { hub_.close(port_); }

    void send_to(const Address& to, const u8* data, usize size) override {
        hub_.deliver(Address{0, port_}, to, data, size);
    }
    bool recv_from(Address& from, std::vector<u8>& data) override { return hub_.take(port_, from, data); }
    Address local_address() const override { return Address{0, port_}; }

private:
    LoopbackHub& hub_;
    u16 port_;
};

std::unique_ptr<DatagramSocket> LoopbackHub::open(u16 port) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (port == 0) {
        while (boxes_.count(next_port_)) ++next_port_;
        port = next_port_++;
    }
    UNI_CHECK(boxes_.count(port) == 0, "loopback port %u in use", (unsigned)port);
    boxes_[port];
    return std::make_unique<LoopbackSocket>(*this, port);
}

void LoopbackHub::deliver(const Address& from, const Address& to, const u8* data, usize size) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = boxes_.find(to.port);
    if (it == boxes_.end()) return; // nobody there: dropped, like UDP
    it->second.packets.push_back(Packet{from, std::vector<u8>(data, data + size)});
}

bool LoopbackHub::take(u16 port, Address& from, std::vector<u8>& data) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = boxes_.find(port);
    if (it == boxes_.end() || it->second.packets.empty()) return false;
    Packet& p = it->second.packets.front();
    from = p.from;
    data.swap(p.data);
    it->second.packets.pop_front();
    return true;
}

void LoopbackHub::close(u16 port) {
    std::lock_guard<std::mutex> lock(mutex_);
    boxes_.erase(port);
}

} // namespace net
