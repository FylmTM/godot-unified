#include "net/client.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

#include "core/json.h"
#include "core/platform.h"
#include "net/clock.h"

namespace net {

namespace {
constexpr u64 RELAY_SILENCE_US = 10'000'000;
constexpr u64 LINGER_US = 3'000'000;
constexpr double CATCH_UP_TICKS = 8.0;
constexpr int MAX_STEPS_PER_PASS = 32;
constexpr usize TIME_WINDOW = 120; // ~2 s of relay packets
constexpr usize RTT_WINDOW = 64;

int delay_for_rtt(double rtt_us) {
    double ticks = std::ceil((rtt_us / 1000.0 / 2.0 + 8.0) / 16.667);
    return (int)std::clamp(ticks, 1.0, 6.0);
}
} // namespace

std::string to_json(const ClientResult& r) {
    uni::JsonWriter j;
    j.begin_object();
    j.key("player").value(r.player);
    j.key("final_tick").value(r.final_tick);
    j.key("checksums").begin_array();
    for (auto& [t, cs] : r.checksums) j.begin_array().value(t).hex64(cs).end_array();
    j.end_array();
    j.key("rollbacks").value(r.rollbacks);
    j.key("rollback_depth_avg").value(r.rollbacks ? (double)r.rollback_depth_sum / (double)r.rollbacks : 0.0);
    j.key("rollback_depth_max").value(r.rollback_depth_max);
    j.key("stall_ticks").value(r.stall_ticks);
    j.key("resimulated_ticks").value(r.resimulated_ticks);
    j.key("desyncs").value(0);
    j.key("delay").value(r.delay);
    j.key("rtt_ms").value(r.rtt_ms);
    if (r.joined_at_tick) j.key("joined_from_snapshot_tick").value(r.joined_at_tick);
    j.key("ok").value(r.ok);
    if (!r.error.empty()) j.key("error").value(r.error);
    j.end_object();
    return j.str();
}

Client::Client(const ClientConfig& config, std::unique_ptr<Host> host, const Address& relay)
    : cfg_(config), host_(std::move(host)), relay_addr_(relay) {
    records_.resize(RECORD_RING);
    finals_.resize(FINAL_RING);
    my_inputs_.resize(FINAL_RING);
    relay_ = host_->connect(relay_addr_);
}

Client::~Client() = default;

ClientResult Client::run() {
    std::vector<Event> events;
    last_relay_packet_ = uni::platform::now_us();
    u64 done_at = 0;
    for (;;) {
        u64 now = uni::platform::now_us();
        events.clear();
        host_->poll(events);
        for (const Event& e : events) on_event(e);
        if (!result_.error.empty()) return result_;
        now = uni::platform::now_us();
        if (phase_ != Phase::Done && now - last_relay_packet_ > RELAY_SILENCE_US) {
            result_.error = cfg_.label + ": relay silent for 10 s";
            return result_;
        }
        if (phase_ == Phase::Running) {
            reconcile();
            schedule(now);
            serve_snapshot();
            update_delay(now);
            if (verified_ >= cfg_.ticks) {
                result_.final_tick = verified_;
                result_.ok = true;
                DoneMsg d;
                d.final_tick = verified_;
                std::vector<u8> bytes = encode(d);
                host_->send(relay_, bytes.data(), bytes.size(), Delivery::Reliable);
                phase_ = Phase::Done;
                done_at = now;
            }
        }
        if (phase_ == Phase::Done) {
            // Make sure our last checksums and Done are acknowledged before going away.
            if (host_->reliable_idle(relay_) || now - done_at > LINGER_US) break;
        } else {
            send_inputs(now);
        }
        u64 wait = 1000;
        if (phase_ == Phase::Running && next_tick_at_ > now) wait = std::min<u64>(wait, next_tick_at_ - now);
        uni::platform::sleep_us((u32)std::max<u64>(wait, 200));
    }
    result_.delay = delay_;
    result_.rtt_ms = rtt_ewma_us_ < 0 ? 0.0 : rtt_ewma_us_ / 1000.0;
    host_->disconnect(relay_);
    return result_;
}

// ---- events --------------------------------------------------------------------------------------

void Client::on_event(const Event& e) {
    if (e.peer != relay_) return;
    if (e.kind == Event::Kind::Connected) {
        HelloMsg h;
        h.player = cfg_.player;
        h.late_join = cfg_.late_join ? 1 : 0;
        std::vector<u8> bytes = encode(h);
        host_->send(relay_, bytes.data(), bytes.size(), Delivery::Reliable);
        last_relay_packet_ = uni::platform::now_us();
        if (u64 rtt = host_->handshake_rtt_us(relay_)) { // seeds the input delay before the first Final
            rtt_ewma_us_ = (double)rtt;
            rtt_samples_.push_back((double)rtt);
        }
        return;
    }
    if (e.kind == Event::Kind::Disconnected) {
        if (phase_ != Phase::Done) result_.error = cfg_.label + ": disconnected from the relay";
        return;
    }
    last_relay_packet_ = uni::platform::now_us();
    Msg type;
    if (!msg_type(e.data, type)) return;
    switch (type) {
    case Msg::Welcome: {
        if (!decode(e.data, welcome_) || phase_ != Phase::Connecting) return;
        me_ = welcome_.player;
        result_.player = me_;
        if (cfg_.ticks == 0 || cfg_.ticks > welcome_.ticks) cfg_.ticks = welcome_.ticks;
        script_ = std::make_unique<game::Script>(welcome_.seed, me_);
        sim_ = std::make_unique<sim::Sim>();
        ring_ = std::make_unique<sim::Ring>();
        start_us_ = welcome_.start_us;
        if (welcome_.join_tick == 0) {
            sim_->setup(welcome_.seed, welcome_.initial_players);
            phase_ = Phase::WaitStart;
            if (start_us_ >= 0) begin_running(0);
        } else {
            phase_ = Phase::WaitSnapshot;
        }
        return;
    }
    case Msg::Start: {
        StartMsg m;
        if (!decode(e.data, m)) return;
        start_us_ = m.start_us;
        if (phase_ == Phase::WaitStart) begin_running(0);
        return;
    }
    case Msg::Final: {
        FinalMsg m;
        if (decode(e.data, m)) on_final(m);
        return;
    }
    case Msg::SnapshotRequest: {
        SnapshotRequestMsg m;
        if (decode(e.data, m)) snapshot_request_ = m;
        return;
    }
    case Msg::Snapshot: {
        SnapshotMsg m;
        if (decode(e.data, m) && phase_ == Phase::WaitSnapshot) on_snapshot(m);
        return;
    }
    default:
        return;
    }
}

void Client::on_final(const FinalMsg& m) {
    const u64 now = uni::platform::now_us();
    if (m.echo_client_time_us != 0 && now > m.echo_client_time_us + m.echo_hold_us) {
        double rtt = (double)(now - m.echo_client_time_us - m.echo_hold_us);
        rtt_ewma_us_ = rtt_ewma_us_ < 0.0 ? rtt : rtt_ewma_us_ * 0.9 + rtt * 0.1;
        rtt_samples_.push_back(rtt);
        if (rtt_samples_.size() > RTT_WINDOW) rtt_samples_.pop_front();
    }
    offset_samples_.push_back((double)m.relay_time_us - (double)now);
    if (offset_samples_.size() > TIME_WINDOW) offset_samples_.pop_front();
    if (m.input_ack > input_ack_) input_ack_ = m.input_ack;

    if (phase_ != Phase::Running && phase_ != Phase::Done) return;
    for (usize i = 0; i < m.ticks.size(); ++i) {
        u32 t = m.first_tick + (u32)i;
        if (t <= frontier_ || have_final(t) || t >= verified_ + FINAL_RING) continue;
        finals_[t % FINAL_RING] = FinalSlot{t, m.ticks[i]};
    }
    while (have_final(frontier_ + 1)) frontier_++;
    if (have_final(frontier_)) last_final_ = finals_[frontier_ % FINAL_RING].inputs;
}

void Client::on_snapshot(const SnapshotMsg& m) {
    sim_ = std::make_unique<sim::Sim>();
    std::string err;
    if (!sim_->load_portable(m.snapshot.data(), m.snapshot.size(), err)) {
        result_.error = cfg_.label + ": " + err;
        return;
    }
    UNI_CHECK(sim_->tick() == m.tick, "snapshot says tick %u, block says %u", m.tick, sim_->tick());
    result_.joined_at_tick = m.tick;
    finals_[m.tick % FINAL_RING] = FinalSlot{m.tick, m.inputs_at_tick};
    last_final_ = m.inputs_at_tick;
    std::fprintf(stderr, "%s: restored snapshot of tick %u (%zu bytes), checksum %s\n", cfg_.label.c_str(), m.tick,
                 m.snapshot.size(), uni::hex16(sim_->checksum()).c_str());
    begin_running(m.tick);
}

void Client::begin_running(u32 tick) {
    local_ = verified_ = frontier_ = last_generated_ = clock_ = tick;
    clock_synced_ = false;
    if (tick == 0) {
        for (int p = 0; p < uni::MAX_PLAYERS; ++p)
            last_final_.players[p] = p < welcome_.initial_players ? uni::Input{} : uni::ABSENT_INPUT;
        sending_ = true;
    } else {
        sending_ = false; // a joiner starts sending once it has caught up with the relay clock
    }
    if (rtt_ewma_us_ >= 0.0) delay_ = delay_for_rtt(rtt_ewma_us_);
    const u64 now = uni::platform::now_us();
    next_delay_update_ = now + 1'000'000;
    next_tick_at_ = now;
    phase_ = Phase::Running;
}

// ---- simulation ----------------------------------------------------------------------------------

uni::TickInputs Client::best_inputs(u32 t) const {
    if (have_final(t)) {
        uni::TickInputs in = finals_[t % FINAL_RING].inputs;
        in.replaced = 0;
        return in;
    }
    uni::TickInputs in = last_final_; // remote players: last finalized input, repeated
    in.replaced = 0;
    const MyInput& mine = my_inputs_[t % FINAL_RING];
    if (me_ >= 0 && mine.tick == t) in.players[me_] = mine.input;
    return in;
}

void Client::simulate(u32 t) {
    Record& r = records_[t % RECORD_RING];
    r.tick = t;
    r.used = best_inputs(t);
    sim_->step(r.used);
    UNI_ASSERT(sim_->tick() == t);
    r.checksum = sim_->checksum();
}

void Client::step_forward() {
    const u32 t = local_ + 1;
    sim_->save(ring_->at(local_));
    simulate(t);
    local_ = t;
}

void Client::reconcile() {
    const u32 upto = std::min(frontier_, local_);
    if (upto <= verified_) return;
    u32 wrong = 0;
    for (u32 t = verified_ + 1; t <= upto; ++t) {
        const Record& r = records_[t % RECORD_RING];
        UNI_ASSERT(r.tick == t);
        if (!r.used.same_inputs(finals_[t % FINAL_RING].inputs)) {
            wrong = t;
            break;
        }
    }
    if (wrong) {
        UNI_CHECK(ring_->has(wrong - 1), "rollback target tick %u is not in the ring", wrong - 1);
        sim_->restore(ring_->at(wrong - 1));
        for (u32 t = wrong; t <= local_; ++t) {
            if (t > wrong) sim_->save(ring_->at(t - 1));
            simulate(t);
        }
        const u32 depth = local_ - wrong + 1;
        result_.rollbacks++;
        result_.rollback_depth_sum += depth;
        result_.rollback_depth_max = std::max(result_.rollback_depth_max, depth);
        result_.resimulated_ticks += depth;
    }
    for (u32 t = verified_ + 1; t <= upto; ++t) verify(t);
    verified_ = upto;
}

void Client::verify(u32 t) {
    if (t % 16 != 0) return;
    const Record& r = records_[t % RECORD_RING];
    UNI_CHECK(r.tick == t, "no record for verified tick %u", t);
    result_.checksums.emplace_back(t, r.checksum);
    ChecksumMsg m;
    m.tick = t;
    m.checksum = r.checksum;
    std::vector<u8> bytes = encode(m);
    host_->send(relay_, bytes.data(), bytes.size(), Delivery::Reliable);
}

// ---- inputs and timing ---------------------------------------------------------------------------

void Client::generate_inputs(u32 upto) {
    if (!sending_) return;
    if (upto > cfg_.ticks) upto = cfg_.ticks;
    if (upto <= last_generated_) return; // the delay shrank: the first input sent for a tick stands
    for (u32 t = last_generated_ + 1; t < upto; ++t) my_inputs_[t % FINAL_RING] = MyInput{t, last_input_};
    last_input_ = script_->input(upto, sim_->levelup_pending(me_));
    my_inputs_[upto % FINAL_RING] = MyInput{upto, last_input_};
    last_generated_ = upto;
}

void Client::send_inputs(u64 now) {
    if (phase_ == Phase::Connecting || me_ < 0) return;
    // A packet per new input, else one per tick (keeps acks and the RTT/time-sync samples flowing).
    if (last_generated_ == last_sent_generated_ && (double)(now - last_input_send_) < TICK_US) return;
    last_sent_generated_ = last_generated_;
    InputMsg m;
    m.client_time_us = now;
    m.ack_final = frontier_;
    u32 first = input_ack_ + 1;
    if (last_generated_ + 1 > (u32)MAX_INPUTS_PER_PACKET)
        first = std::max(first, last_generated_ + 1 - (u32)MAX_INPUTS_PER_PACKET);
    m.first_tick = first;
    for (u32 t = first; t <= last_generated_; ++t) {
        const MyInput& mi = my_inputs_[t % FINAL_RING];
        if (mi.tick != t) break;
        m.inputs.push_back(mi.input);
    }
    std::vector<u8> bytes = encode(m);
    host_->send(relay_, bytes.data(), bytes.size(), Delivery::Unreliable);
    last_input_send_ = now;
}

double Client::est_relay_tick(u64 now) const {
    if (offset_samples_.empty()) return (double)local_;
    // The packet that travelled fastest bounds the offset best; add back the minimum one-way delay.
    double best = *std::max_element(offset_samples_.begin(), offset_samples_.end());
    double rtt_min = rtt_samples_.empty() ? 0.0 : *std::min_element(rtt_samples_.begin(), rtt_samples_.end());
    double relay_now = (double)now + best + rtt_min / 2.0;
    return (relay_now - (double)start_us_) / TICK_US;
}

void Client::update_delay(u64 now) {
    if (now < next_delay_update_) return;
    next_delay_update_ += 1'000'000;
    if (rtt_ewma_us_ < 0.0) return;
    int target = delay_for_rtt(rtt_ewma_us_);
    if (target > delay_) delay_++;
    if (target < delay_) delay_--;
}

// Two clocks: `clock_` is the time-synced tick (relay tick + delay, slewed 2%), which drives input
// sampling: the input for clock_ + delay is generated as the clock passes each tick. `local_` is the
// predicted simulation, which follows clock_ but never runs more than PREDICTION_CAP ticks past the
// verified frame. Keeping input sampling on the clock while the simulation is capped matters: if inputs
// were only generated as local_ advances, a capped client's inputs reach the relay after the tolerance,
// the relay then finalizes only on its timer, and the client stays capped (seen under the `bad` profile).
void Client::schedule(u64 now) {
    const double target = est_relay_tick(now) + (double)delay_;
    const double error = target - (double)clock_; // > 0: behind the relay clock
    int opportunities = 0;
    if (!clock_synced_ || error > CATCH_UP_TICKS) {
        // Start, a late joiner, or a long hiccup: jump instead of slewing.
        if (target > (double)clock_) clock_ = std::min(cfg_.ticks, (u32)target);
        clock_synced_ = true;
        next_tick_at_ = now + (u64)TICK_US;
        generate_inputs(clock_ + (u32)delay_);
    } else if (error < -CATCH_UP_TICKS) {
        next_tick_at_ = std::max<u64>(next_tick_at_, now + (u64)TICK_US); // far ahead: wait
    } else {
        if (now > next_tick_at_ + 250'000) next_tick_at_ = now; // descheduled for a while: don't burst
        // 2% faster or slower to converge on relay tick + delay; scheduling only, never the sim.
        const double rate = error > 0.5 ? 1.02 : (error < -0.5 ? 0.98 : 1.0);
        while (now >= next_tick_at_ && opportunities < 8) {
            next_tick_at_ += (u64)(TICK_US / rate);
            if (clock_ < cfg_.ticks) clock_++;
            ++opportunities;
            generate_inputs(clock_ + (u32)delay_);
        }
    }
    if (!sending_ && local_ + 2 >= clock_) { // a joiner caught up: start playing
        sending_ = true;
        last_generated_ = std::max(last_generated_, local_);
        generate_inputs(clock_ + (u32)delay_);
    }
    // Advance the predicted simulation towards the clock, within the prediction cap.
    for (int steps = 0; local_ < clock_ && steps < MAX_STEPS_PER_PASS; ++steps) {
        if (local_ - verified_ >= PREDICTION_CAP) break;
        // A joiner still fast-forwarding uses finalized inputs only (no point predicting old ticks).
        if (!sending_ && !have_final(local_ + 1)) break;
        step_forward();
        reconcile();
    }
    if (opportunities > 0 && local_ < clock_ && local_ - verified_ >= PREDICTION_CAP)
        result_.stall_ticks += (u64)opportunities;
}

void Client::serve_snapshot() {
    if (!snapshot_request_ || verified_ < snapshot_request_->min_tick || !have_final(verified_)) return;
    SnapshotMsg m;
    m.for_player = snapshot_request_->for_player;
    m.tick = verified_;
    m.inputs_at_tick = finals_[verified_ % FINAL_RING].inputs;
    if (verified_ == local_) {
        m.snapshot = sim_->encode_portable();
    } else {
        UNI_CHECK(ring_->has(verified_), "verified tick %u is not in the ring", verified_);
        m.snapshot = sim::Sim::encode_portable(ring_->at(verified_));
    }
    std::vector<u8> bytes = encode(m);
    host_->send(relay_, bytes.data(), bytes.size(), Delivery::Reliable);
    std::fprintf(stderr, "%s: sent snapshot of tick %u (%zu bytes) for player %d\n", cfg_.label.c_str(), verified_,
                 m.snapshot.size(), (int)m.for_player);
    snapshot_request_.reset();
}

} // namespace net
