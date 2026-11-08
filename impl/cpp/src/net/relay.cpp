#include "net/relay.h"

#include <cinttypes>
#include <cstdio>

#include "core/platform.h"
#include "net/clock.h"

namespace net {

namespace {
constexpr u64 LINGER_US = 400'000;          // keep acking after everyone is done
constexpr u64 SNAPSHOT_RETRY_US = 3'000'000; // ask another provider if no snapshot arrives
constexpr u64 IDLE_LIMIT_US = 120'000'000;   // nobody ever connects / everyone vanished
} // namespace

Relay::Relay(const RelayConfig& config, std::unique_ptr<Host> host)
    : cfg_(config), host_(std::move(host)), epoch_us_(uni::platform::now_us()) {
    for (Slot& s : slots_) {
        s.inputs.assign(cfg_.ticks + 2, uni::Input{});
        s.has.assign(cfg_.ticks + 2, 0);
    }
    result_.log.seed = cfg_.seed;
    result_.log.players = (u8)cfg_.initial_players;
}

Relay::~Relay() = default;

i64 Relay::now_rel() const { return (i64)(uni::platform::now_us() - epoch_us_); }

int Relay::slot_of(PeerId peer) const {
    for (int p = 0; p < uni::MAX_PLAYERS; ++p)
        if (slots_[p].used && slots_[p].peer == peer && slots_[p].connected) return p;
    return -1;
}

RelayResult Relay::run() {
    std::vector<Event> events;
    u64 all_done_at = 0;
    u64 last_activity = uni::platform::now_us();
    for (;;) {
        events.clear();
        host_->poll(events);
        for (Event& e : events) {
            last_activity = uni::platform::now_us();
            if (e.kind == Event::Kind::Message) {
                on_message(slot_of(e.peer), e.peer, e.data);
            } else if (e.kind == Event::Kind::Disconnected) {
                int s = slot_of(e.peer);
                if (s >= 0) {
                    slots_[s].connected = false;
                    if (!slots_[s].done)
                        std::fprintf(stderr, "relay: player %d disconnected at tick %u\n", s, last_finalized_);
                }
            }
        }

        bool new_finals = false;
        if (started_) {
            i64 r = relay_tick_at(now_rel(), start_us_);
            current_tick_.store(r < 0 ? 0u : (u32)r, std::memory_order_relaxed);
            u32 before = last_finalized_;
            finalize_ready(r);
            new_finals = last_finalized_ != before;
            for (int p = 0; p < uni::MAX_PLAYERS; ++p) {
                Slot& s = slots_[p];
                if (s.awaiting_snapshot && s.connected &&
                    uni::platform::now_us() - s.snapshot_requested_at > SNAPSHOT_RETRY_US)
                    request_snapshot(p);
            }
        }
        send_finals(new_finals);

        if (started_ && last_finalized_ == cfg_.ticks) {
            bool everyone = true;
            for (const Slot& s : slots_)
                if (s.used && s.connected && !s.done) everyone = false;
            if (everyone) {
                if (all_done_at == 0) all_done_at = uni::platform::now_us();
                if (uni::platform::now_us() - all_done_at > LINGER_US) break;
            }
        }
        if (uni::platform::now_us() - last_activity > IDLE_LIMIT_US) {
            result_.error = "relay: no activity for too long";
            return result_;
        }
        uni::platform::sleep_us(500);
    }
    result_.ok = last_finalized_ == cfg_.ticks;
    result_.finalized = last_finalized_;
    if (!result_.ok) result_.error = "relay: session ended early";
    return result_;
}

void Relay::on_message(int slot, PeerId peer, const std::vector<u8>& data) {
    Msg type;
    if (!msg_type(data, type)) return;
    if (type == Msg::Hello) {
        HelloMsg m;
        if (decode(data, m)) on_hello(peer, m);
        return;
    }
    if (slot < 0) return;
    Slot& s = slots_[slot];
    switch (type) {
    case Msg::Input: {
        InputMsg m;
        if (!decode(data, m)) return;
        s.client_time_us = m.client_time_us;
        s.client_time_at = uni::platform::now_us();
        u32 ack = m.ack_final < last_finalized_ ? m.ack_final : last_finalized_;
        if (!s.awaiting_snapshot && ack > s.ack_final) s.ack_final = ack;
        for (usize i = 0; i < m.inputs.size(); ++i) {
            u32 t = m.first_tick + (u32)i;
            // Late (already finalized) or duplicate inputs are dropped: the first one for a tick wins.
            if (t <= last_finalized_ || t > cfg_.ticks || t < s.active_from || s.has[t]) continue;
            uni::Input in = m.inputs[i];
            in.buttons &= (u8)~uni::BUTTON_ABSENT;
            s.inputs[t] = in;
            s.has[t] = 1;
            s.required = true; // a late joiner counts from its first accepted input
        }
        while (s.input_contig + 1 <= cfg_.ticks && s.has[s.input_contig + 1]) s.input_contig++;
        return;
    }
    case Msg::Checksum: {
        ChecksumMsg m;
        if (!decode(data, m)) return;
        auto it = checksums_.find(m.tick);
        if (it == checksums_.end()) {
            checksums_[m.tick] = {m.checksum, slot};
        } else if (it->second.first != m.checksum) {
            result_.desyncs++;
            std::fprintf(stderr, "relay: DESYNC at tick %u: player %d %016" PRIx64 " vs player %d %016" PRIx64 "\n",
                         m.tick, it->second.second, it->second.first, slot, m.checksum);
        }
        return;
    }
    case Msg::Snapshot: {
        SnapshotMsg m;
        if (!decode(data, m) || m.for_player >= uni::MAX_PLAYERS) return;
        Slot& j = slots_[m.for_player];
        if (!j.used || !j.connected || !j.awaiting_snapshot) return;
        // Forward the bytes unchanged; then stream finalized inputs from tick + 1.
        host_->send(j.peer, data.data(), data.size(), Delivery::Reliable);
        j.awaiting_snapshot = false;
        j.ack_final = m.tick;
        std::fprintf(stderr, "relay: forwarded snapshot of tick %u (%zu bytes) from player %d to player %d\n", m.tick,
                     m.snapshot.size(), slot, (int)m.for_player);
        return;
    }
    case Msg::Done:
        s.done = true;
        return;
    default:
        return;
    }
}

void Relay::on_hello(PeerId peer, const HelloMsg& m) {
    int existing = slot_of(peer);
    if (existing >= 0) return; // reliable channel: a second Hello would be a protocol error; ignore
    const bool late = m.late_join || started_;
    int slot = -1;
    if (m.player < uni::MAX_PLAYERS && !slots_[m.player].used) slot = m.player;
    for (int p = 0; slot < 0 && p < uni::MAX_PLAYERS; ++p)
        if (!slots_[p].used) slot = p;
    if (slot < 0 || (!late && slot >= uni::MAX_PLAYERS)) {
        std::fprintf(stderr, "relay: no free slot for a new player\n");
        host_->disconnect(peer);
        return;
    }
    Slot& s = slots_[slot];
    s.used = true;
    s.connected = true;
    s.peer = peer;
    WelcomeMsg w;
    w.player = (u8)slot;
    w.initial_players = (u8)cfg_.initial_players;
    w.seed = cfg_.seed;
    w.ticks = cfg_.ticks;
    if (!late) {
        s.active_from = 1;
        s.required = true;
        w.join_tick = 0;
        w.start_us = -1;
        std::vector<u8> bytes = encode(w);
        host_->send(peer, bytes.data(), bytes.size(), Delivery::Reliable);
        int joined = 0;
        for (const Slot& o : slots_) joined += o.used ? 1 : 0;
        if (joined >= cfg_.initial_players) start_session();
        return;
    }
    i64 r = relay_tick_at(now_rel(), start_us_);
    u32 base = (u32)(r > (i64)last_finalized_ ? r : (i64)last_finalized_);
    s.active_from = base + cfg_.join_lead;
    s.required = false;
    s.awaiting_snapshot = true;
    w.join_tick = s.active_from;
    w.start_us = start_us_;
    std::vector<u8> bytes = encode(w);
    host_->send(peer, bytes.data(), bytes.size(), Delivery::Reliable);
    std::fprintf(stderr, "relay: player %d joins, active from tick %u (relay tick %lld)\n", slot, s.active_from,
                 (long long)r);
    request_snapshot(slot);
}

void Relay::request_snapshot(int joiner) {
    Slot& j = slots_[joiner];
    j.snapshot_requested_at = uni::platform::now_us();
    // Rotate through the other connected players, starting after the last one asked.
    for (int k = 0; k < uni::MAX_PLAYERS; ++k) {
        int p = (rotate_ + k) % uni::MAX_PLAYERS;
        const Slot& s = slots_[p];
        if (p == joiner || !s.used || !s.connected || s.done || s.awaiting_snapshot) continue;
        rotate_ = p + 1;
        SnapshotRequestMsg m;
        m.min_tick = j.active_from - 1;
        m.for_player = (u8)joiner;
        std::vector<u8> bytes = encode(m);
        host_->send(s.peer, bytes.data(), bytes.size(), Delivery::Reliable);
        return;
    }
}

void Relay::start_session() {
    started_ = true;
    start_us_ = now_rel() + 50'000; // a little lead so Start reaches everyone before tick 1 is due
    StartMsg m;
    m.start_us = start_us_;
    std::vector<u8> bytes = encode(m);
    for (const Slot& s : slots_)
        if (s.used && s.connected) host_->send(s.peer, bytes.data(), bytes.size(), Delivery::Reliable);
    std::fprintf(stderr, "relay: session started with %d players\n", cfg_.initial_players);
}

void Relay::finalize_ready(i64 relay_tick) {
    while (last_finalized_ < cfg_.ticks) {
        const u32 t = last_finalized_ + 1;
        bool all_in = true;
        for (const Slot& s : slots_)
            if (s.used && s.connected && s.required && t >= s.active_from && !s.has[t]) all_in = false;
        if (!all_in && relay_tick < (i64)t + (i64)cfg_.tolerance) return;
        finalize(t);
    }
}

void Relay::finalize(u32 t) {
    uni::TickInputs ti;
    for (int p = 0; p < uni::MAX_PLAYERS; ++p) {
        Slot& s = slots_[p];
        if (!s.used || !s.connected || t < s.active_from) {
            ti.players[p] = uni::ABSENT_INPUT;
        } else if (s.has[t]) {
            ti.players[p] = s.inputs[t];
        } else {
            uni::Input rep = s.last_final;
            if (rep.absent()) rep = uni::Input{}; // a fresh joiner has no input to repeat: idle
            ti.players[p] = rep;
            ti.replaced |= (u8)(1u << p);
            result_.replaced_inputs++;
        }
        s.last_final = ti.players[p];
    }
    result_.log.ticks.push_back(ti);
    last_finalized_ = t;
}

void Relay::send_finals(bool force) {
    const u64 now = uni::platform::now_us();
    for (int p = 0; p < uni::MAX_PLAYERS; ++p) {
        Slot& s = slots_[p];
        if (!s.used || !s.connected) continue;
        if (!force && (double)(now - s.last_send_at) < TICK_US) continue;
        FinalMsg m;
        m.relay_time_us = now_rel();
        m.echo_client_time_us = s.client_time_us;
        m.echo_hold_us = s.client_time_us ? (u32)(now - s.client_time_at) : 0u;
        m.input_ack = last_finalized_ > s.input_contig ? last_finalized_ : s.input_contig;
        m.first_tick = s.ack_final + 1;
        if (!s.awaiting_snapshot && started_) {
            for (u32 t = m.first_tick; t <= last_finalized_ && m.ticks.size() < (usize)MAX_FINALS_PER_PACKET; ++t)
                m.ticks.push_back(result_.log.ticks[t - 1]);
        }
        std::vector<u8> bytes = encode(m);
        host_->send(s.peer, bytes.data(), bytes.size(), Delivery::Unreliable);
        s.last_send_at = now;
        s.sent_upto = last_finalized_;
    }
}

} // namespace net
