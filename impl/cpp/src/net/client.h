// The rollback client: a verified frame advanced only by finalized inputs and a predicted frame ahead of it
// (own inputs + remote inputs predicted as "last finalized repeated"). New finalized inputs that contradict
// a prediction restore the snapshot before the first wrong tick and re-simulate to the present. Also:
// adaptive input delay, time sync (2% clock slew), the 10-tick prediction cap, checksum reports, and
// snapshot hand-off for late joiners (as provider or as joiner).
#pragma once

#include <deque>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "net/host.h"
#include "net/protocol.h"
#include "sim/sim.h"

namespace net {

struct ClientConfig {
    u8 player = ANY_PLAYER; // requested slot
    bool late_join = false;
    u32 ticks = 0;
    std::string label = "client";
};

struct ClientResult {
    bool ok = false;
    std::string error;
    int player = -1;
    u32 final_tick = 0;
    std::vector<std::pair<u32, u64>> checksums; // verified ticks divisible by 16
    u64 rollbacks = 0;
    u64 rollback_depth_sum = 0;
    u32 rollback_depth_max = 0;
    u64 stall_ticks = 0;
    u64 resimulated_ticks = 0;
    u32 joined_at_tick = 0; // late joiner: the snapshot tick
    int delay = 0;
    double rtt_ms = 0.0;
};

std::string to_json(const ClientResult& r);

class Client {
public:
    Client(const ClientConfig& config, std::unique_ptr<Host> host, const Address& relay);
    ~Client();
    ClientResult run();

private:
    enum class Phase { Connecting, WaitStart, WaitSnapshot, Running, Done };

    struct Record { // per simulated tick
        u32 tick = 0;
        uni::TickInputs used;
        u64 checksum = 0;
    };
    struct FinalSlot {
        u32 tick = 0;
        uni::TickInputs inputs;
    };
    struct MyInput {
        u32 tick = 0;
        uni::Input input;
    };

    void on_event(const Event& e);
    void on_final(const FinalMsg& m);
    void on_snapshot(const SnapshotMsg& m);
    void begin_running(u32 tick);
    bool have_final(u32 t) const { return finals_[t % FINAL_RING].tick == t; }
    uni::TickInputs best_inputs(u32 t) const;
    void simulate(u32 t);
    void step_forward();
    void reconcile();
    void verify(u32 t);
    void generate_inputs(u32 upto);
    void send_inputs(u64 now);
    void schedule(u64 now);
    void update_delay(u64 now);
    void serve_snapshot();
    double est_relay_tick(u64 now) const;

    static constexpr u32 FINAL_RING = 512;
    static constexpr u32 RECORD_RING = 64;
    static constexpr u32 PREDICTION_CAP = 10;

    ClientConfig cfg_;
    std::unique_ptr<Host> host_;
    Address relay_addr_;
    PeerId relay_ = NO_PEER;
    Phase phase_ = Phase::Connecting;
    WelcomeMsg welcome_;
    i64 start_us_ = -1;
    int me_ = -1;

    std::unique_ptr<sim::Sim> sim_;
    std::unique_ptr<sim::Ring> ring_;
    std::unique_ptr<game::Script> script_;
    std::vector<Record> records_;
    std::vector<FinalSlot> finals_;
    std::vector<MyInput> my_inputs_;
    uni::TickInputs last_final_; // the finalized set at the frontier: prediction source
    u32 frontier_ = 0;           // contiguous finalized ticks received
    u32 verified_ = 0;
    u32 local_ = 0; // predicted tick (the sim's tick)
    u32 clock_ = 0; // time-synced tick that drives input sampling (see schedule())
    bool clock_synced_ = false;
    u32 last_sent_generated_ = 0;
    u32 last_generated_ = 0;
    uni::Input last_input_;
    bool sending_ = false;
    u32 input_ack_ = 0;
    std::optional<SnapshotRequestMsg> snapshot_request_;

    // time sync
    int delay_ = 1;
    u64 next_delay_update_ = 0;
    double rtt_ewma_us_ = -1.0;
    std::deque<double> rtt_samples_;
    std::deque<double> offset_samples_; // relay_time - client_time at receipt
    u64 next_tick_at_ = 0;
    u64 last_input_send_ = 0;
    u64 last_relay_packet_ = 0;

    ClientResult result_;
};

} // namespace net
