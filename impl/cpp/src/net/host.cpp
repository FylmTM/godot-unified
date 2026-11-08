#include "net/host.h"

#include <cstring>

#include "core/bytes.h"
#include "core/platform.h"

namespace net {

namespace {
constexpr u8 MAGIC = 0xD7;
constexpr u8 K_CONNECT = 1, K_ACCEPT = 2, K_DATA = 3, K_BYE = 4;
constexpr u8 F_UNRELIABLE = 0, F_RELIABLE = 1, F_RELIABLE_LAST = 2;
constexpr usize FRAGMENT_BYTES = 1100;
constexpr usize DATAGRAM_BUDGET = 1200;
constexpr u32 WINDOW = 256;
constexpr u32 MAX_EARLY = 8192;
constexpr u64 CONNECT_RETRY_US = 100'000;
constexpr u64 KEEPALIVE_US = 250'000;
constexpr usize HEADER_BYTES = 1 + 1 + 4;
constexpr usize DATA_HEADER_BYTES = HEADER_BYTES + 8;

u64 splitmix(u64& s) {
    u64 z = (s += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
} // namespace

Host::Host(std::unique_ptr<DatagramSocket> socket, bool accept_incoming)
    : socket_(std::move(socket)), accept_incoming_(accept_incoming),
      token_rng_(uni::platform::now_us() ^ ((u64)socket_->local_address().port << 40)) {}

Host::~Host() {
    for (auto& [id, p] : peers_) {
        if (!p->connected) continue;
        std::vector<u8> bye;
        write_header(bye, K_BYE, *p);
        socket_->send_to(p->addr, bye.data(), bye.size());
    }
}

Host::Peer* Host::find(PeerId id) {
    auto it = peers_.find(id);
    return it == peers_.end() ? nullptr : it->second.get();
}

const Host::Peer* Host::find(PeerId id) const {
    auto it = peers_.find(id);
    return it == peers_.end() ? nullptr : it->second.get();
}

Host::Peer* Host::find_addr(const Address& a) {
    for (auto& [id, p] : peers_)
        if (p->addr == a) return p.get();
    return nullptr;
}

Host::Peer& Host::add_peer(const Address& a, u32 token) {
    auto p = std::make_unique<Peer>();
    p->id = next_id_++;
    p->addr = a;
    p->token = token;
    Peer& ref = *p;
    peers_[ref.id] = std::move(p);
    return ref;
}

PeerId Host::connect(const Address& addr) {
    u32 token = (u32)splitmix(token_rng_) | 1u;
    Peer& p = add_peer(addr, token);
    p.last_recv_us = uni::platform::now_us();
    return p.id;
}

void Host::write_header(std::vector<u8>& out, u8 kind, const Peer& p) {
    out.clear();
    uni::ByteWriter w(out);
    w.put_u8(MAGIC);
    w.put_u8(kind);
    w.put_u32(p.token);
}

void Host::write_data_header(std::vector<u8>& out, Peer& p) {
    write_header(out, K_DATA, p);
    uni::ByteWriter w(out);
    u32 bits = 0;
    for (u32 i = 0; i < 32; ++i)
        if (p.early.count(p.next_expected + 1 + i)) bits |= 1u << i;
    w.put_u32(p.next_expected);
    w.put_u32(bits);
    p.ack_due = false;
}

void Host::raw_send(Peer& p, const std::vector<u8>& datagram, u64 now) {
    socket_->send_to(p.addr, datagram.data(), datagram.size());
    p.last_send_us = now;
}

void Host::send(PeerId peer, const u8* data, usize size, Delivery delivery) {
    Peer* p = find(peer);
    if (!p) return;
    u64 now = uni::platform::now_us();
    if (delivery == Delivery::Unreliable) {
        UNI_CHECK(size + DATA_HEADER_BYTES + 3 <= MAX_DATAGRAM, "unreliable message of %zu bytes is too big", size);
        if (!p->connected) return;
        write_data_header(scratch_, *p);
        uni::ByteWriter w(scratch_);
        w.put_u8(F_UNRELIABLE);
        w.put_u16((u16)size);
        w.put_bytes(data, size);
        raw_send(*p, scratch_, now);
        return;
    }
    usize off = 0;
    do {
        usize n = size - off < FRAGMENT_BYTES ? size - off : FRAGMENT_BYTES;
        Fragment f;
        f.seq = p->next_seq++;
        f.last = off + n == size;
        f.data.assign(data + off, data + off + n);
        p->unacked.push_back(std::move(f));
        off += n;
    } while (off < size);
    service(*p, now);
}

void Host::disconnect(PeerId peer) {
    Peer* p = find(peer);
    if (!p) return;
    if (p->connected) {
        std::vector<u8> bye;
        write_header(bye, K_BYE, *p);
        socket_->send_to(p->addr, bye.data(), bye.size());
        socket_->send_to(p->addr, bye.data(), bye.size());
    }
    peers_.erase(peer);
}

u64 Host::handshake_rtt_us(PeerId peer) const {
    const Peer* p = find(peer);
    return p ? p->handshake_rtt_us : 0;
}

bool Host::reliable_idle(PeerId peer) const {
    const Peer* p = find(peer);
    return !p || p->unacked.empty();
}

void Host::drop_peer(PeerId id, std::vector<Event>& events) {
    peers_.erase(id);
    events.push_back(Event{Event::Kind::Disconnected, id, {}});
}

void Host::poll(std::vector<Event>& events) {
    u64 now = uni::platform::now_us();
    Address from;
    std::vector<u8> buf;
    while (socket_->recv_from(from, buf)) handle(from, buf.data(), buf.size(), events, now);

    std::vector<PeerId> dead;
    for (auto& [id, p] : peers_) {
        if (now - p->last_recv_us > TIMEOUT_US && now > p->last_recv_us) {
            dead.push_back(id);
            continue;
        }
        if (!p->connected) {
            if (!accept_incoming_ && now - p->last_connect_us >= CONNECT_RETRY_US) {
                std::vector<u8> c;
                write_header(c, K_CONNECT, *p);
                socket_->send_to(p->addr, c.data(), c.size());
                p->last_connect_us = now;
            }
            continue;
        }
        service(*p, now);
    }
    for (PeerId id : dead) drop_peer(id, events);
}

void Host::service(Peer& p, u64 now) {
    if (!p.connected) return;
    bool sent = false;
    std::vector<u8>& pkt = scratch_;
    pkt.clear();
    if (!p.unacked.empty()) {
        const u32 base = p.unacked.front().seq;
        for (Fragment& f : p.unacked) {
            if (f.seq >= base + WINDOW) break;
            if (f.sent_us != 0 && now - f.sent_us < p.rto_us) continue;
            usize need = 1 + 4 + 2 + f.data.size();
            if (!pkt.empty() && pkt.size() + need > DATAGRAM_BUDGET) {
                raw_send(p, pkt, now);
                sent = true;
                pkt.clear();
            }
            if (pkt.empty()) write_data_header(pkt, p);
            uni::ByteWriter w(pkt);
            w.put_u8(f.last ? F_RELIABLE_LAST : F_RELIABLE);
            w.put_u32(f.seq);
            w.put_u16((u16)f.data.size());
            w.put_bytes(f.data.data(), f.data.size());
            f.sent_us = now;
            f.sends++;
        }
    }
    if (!pkt.empty()) {
        raw_send(p, pkt, now);
        sent = true;
    }
    if (!sent && (p.ack_due || now - p.last_send_us >= KEEPALIVE_US)) {
        write_data_header(pkt, p);
        raw_send(p, pkt, now);
    }
}

void Host::process_acks(Peer& p, u32 ack, u32 bits, u64 now) {
    auto sample = [&](const Fragment& f) {
        if (f.sends != 1) return; // Karn: only unambiguous samples
        f32 rtt = (f32)(now - f.sent_us);
        p.srtt_us = p.srtt_us == 0.0f ? rtt : p.srtt_us * 0.875f + rtt * 0.125f;
        u64 rto = (u64)(p.srtt_us * 1.5f) + 15'000;
        p.rto_us = rto < 20'000 ? 20'000 : (rto > 1'000'000 ? 1'000'000 : rto);
    };
    while (!p.unacked.empty() && p.unacked.front().seq < ack) {
        sample(p.unacked.front());
        p.unacked.pop_front();
    }
    if (bits == 0) return;
    for (auto it = p.unacked.begin(); it != p.unacked.end();) {
        u32 d = it->seq - ack; // >= 0 here
        if (d >= 1 && d <= 32 && (bits & (1u << (d - 1)))) {
            sample(*it);
            it = p.unacked.erase(it);
        } else if (d > 32) {
            break;
        } else {
            ++it;
        }
    }
}

void Host::handle(const Address& from, const u8* data, usize size, std::vector<Event>& events, u64 now) {
    uni::ByteReader r(data, size);
    u8 magic = r.get_u8();
    u8 kind = r.get_u8();
    u32 token = r.get_u32();
    if (!r.ok() || magic != MAGIC) return;
    Peer* p = find_addr(from);
    switch (kind) {
    case K_CONNECT: {
        if (!accept_incoming_) return;
        if (p && p->token != token) { // the same address reconnected
            drop_peer(p->id, events);
            p = nullptr;
        }
        if (!p) {
            p = &add_peer(from, token);
            p->connected = true;
            p->last_recv_us = now;
            events.push_back(Event{Event::Kind::Connected, p->id, {}});
        }
        p->last_recv_us = now;
        std::vector<u8> acc;
        write_header(acc, K_ACCEPT, *p);
        socket_->send_to(from, acc.data(), acc.size());
        return;
    }
    case K_ACCEPT:
        if (!p || p->token != token || p->connected) return;
        p->connected = true;
        p->handshake_rtt_us = now > p->last_connect_us ? now - p->last_connect_us : 0;
        p->last_recv_us = now;
        events.push_back(Event{Event::Kind::Connected, p->id, {}});
        service(*p, now);
        return;
    case K_DATA:
        if (!p || p->token != token || !p->connected) return;
        p->last_recv_us = now;
        handle_data(*p, data + HEADER_BYTES, size - HEADER_BYTES, events, now);
        return;
    case K_BYE:
        if (p && p->token == token) drop_peer(p->id, events);
        return;
    default:
        return;
    }
}

void Host::handle_data(Peer& p, const u8* data, usize size, std::vector<Event>& events, u64 now) {
    uni::ByteReader r(data, size);
    u32 ack = r.get_u32();
    u32 bits = r.get_u32();
    if (!r.ok()) return;
    process_acks(p, ack, bits, now);
    while (r.ok() && !r.at_end()) {
        u8 type = r.get_u8();
        if (type == F_UNRELIABLE) {
            u16 len = r.get_u16();
            const u8* bytes = r.get_bytes(len);
            if (!bytes) return;
            events.push_back(Event{Event::Kind::Message, p.id, std::vector<u8>(bytes, bytes + len)});
            continue;
        }
        if (type != F_RELIABLE && type != F_RELIABLE_LAST) return;
        u32 seq = r.get_u32();
        u16 len = r.get_u16();
        const u8* bytes = r.get_bytes(len);
        if (!bytes) return;
        p.ack_due = true;
        if (seq < p.next_expected || seq >= p.next_expected + MAX_EARLY || p.early.count(seq)) continue;
        Fragment f;
        f.seq = seq;
        f.last = type == F_RELIABLE_LAST;
        f.data.assign(bytes, bytes + len);
        p.early.emplace(seq, std::move(f));
        for (auto it = p.early.find(p.next_expected); it != p.early.end(); it = p.early.find(p.next_expected)) {
            p.assembling.insert(p.assembling.end(), it->second.data.begin(), it->second.data.end());
            if (it->second.last) {
                events.push_back(Event{Event::Kind::Message, p.id, std::move(p.assembling)});
                p.assembling.clear();
            }
            p.early.erase(it);
            p.next_expected++;
        }
    }
}

} // namespace net
