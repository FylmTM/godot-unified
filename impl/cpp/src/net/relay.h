// The Quantum-style input relay: owns the 60 Hz tick clock, collects inputs stamped with their target tick,
// finalizes tick T once every connected player's input for T is in or the clock reaches T + tolerance
// (missing inputs repeat the player's last finalized input, flagged "replaced"), broadcasts finalized
// sets over the unreliable channel (every unacked tick, up to 32 per packet), keeps the official input
// log, compares client checksums, and brokers late joins. No game logic.
#pragma once

#include <atomic>
#include <map>
#include <memory>
#include <string>

#include "core/input_log.h"
#include "net/host.h"
#include "net/protocol.h"

namespace net {

struct RelayConfig {
    u64 seed = 1;
    int initial_players = 1; // the session starts when this many players have said hello
    u32 ticks = 0;           // the session ends at this tick
    u32 tolerance = 6;       // hard tolerance in ticks
    u32 join_lead = 20;      // a late joiner becomes active this many ticks after the current frontier
};

struct RelayResult {
    bool ok = false;
    std::string error;
    u64 desyncs = 0;
    u64 replaced_inputs = 0;
    u32 finalized = 0;
    uni::InputLog log;
};

class Relay {
public:
    Relay(const RelayConfig& config, std::unique_ptr<Host> host);
    ~Relay();

    // Runs the relay loop until every player is done (or gone). Thread-safe to call current_tick()
    // from other threads meanwhile.
    RelayResult run();
    u32 current_tick() const { return current_tick_.load(std::memory_order_relaxed); }

private:
    struct Slot {
        bool used = false;
        bool connected = false;
        bool required = false; // early finalization waits for this player's input
        bool done = false;
        bool awaiting_snapshot = false;
        PeerId peer = NO_PEER;
        u32 active_from = 0xFFFFFFFFu;
        u32 ack_final = 0;
        u32 input_contig = 0;
        u64 client_time_us = 0;
        u64 client_time_at = 0;
        u64 last_send_at = 0;
        u32 sent_upto = 0;
        uni::Input last_final = uni::ABSENT_INPUT;
        std::vector<uni::Input> inputs; // by tick
        std::vector<u8> has;
        u64 snapshot_requested_at = 0;
    };

    i64 now_rel() const;
    int slot_of(PeerId peer) const;
    void on_message(int slot, PeerId peer, const std::vector<u8>& data);
    void on_hello(PeerId peer, const HelloMsg& m);
    void request_snapshot(int joiner);
    void start_session();
    void finalize_ready(i64 relay_tick);
    void finalize(u32 t);
    void send_finals(bool force);

    RelayConfig cfg_;
    std::unique_ptr<Host> host_;
    u64 epoch_us_;
    bool started_ = false;
    i64 start_us_ = -1;
    u32 last_finalized_ = 0;
    Slot slots_[uni::MAX_PLAYERS];
    std::map<u32, std::pair<u64, int>> checksums_; // tick -> (checksum, first reporter)
    RelayResult result_;
    int rotate_ = 0;
    std::atomic<u32> current_tick_{0};
};

} // namespace net
