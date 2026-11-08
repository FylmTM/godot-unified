// The simulation harness: state block + Box3D world, snapshots (memcpy + fork save), the snapshot ring,
// checksums and the portable snapshot format. Game-agnostic in shape; it calls into game:: for the rules.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "core/input.h"
#include "game/game.h"
#include "physics/physics.h"

namespace sim {

constexpr int RING_SIZE = 16;

struct Snapshot {
    Snapshot();
    std::unique_ptr<game::State> state;
    phys::Snapshot physics;

    u32 tick() const { return state->tick; }
    usize bytes() const { return sizeof(game::State) + physics.size(); }
};

class Sim {
public:
    Sim();
    ~Sim();
    Sim(const Sim&) = delete;
    Sim& operator=(const Sim&) = delete;

    // Builds the tick-0 world. Call once per Sim.
    void setup(u64 seed, int players);
    void step(const uni::TickInputs& inputs);
    u64 checksum() const;

    void save(Snapshot& out);
    void restore(const Snapshot& in);

    // Portable snapshot: "UNIS", version, layout hash, block bytes, physics image bytes.
    std::vector<u8> encode_portable();
    static std::vector<u8> encode_portable(const Snapshot& snap);
    // Replaces this Sim's state with a portable snapshot (setup() must not have been called).
    bool load_portable(const u8* data, usize size, std::string& error);

    game::State& state() { return *state_; }
    const game::State& state() const { return *state_; }
    u32 tick() const { return state_->tick; }
    bool levelup_pending(int player) const;

private:
    std::unique_ptr<game::State> state_;
    std::unique_ptr<phys::World> world_;
    std::unique_ptr<game::Scratch> scratch_;
};

// Snapshots of the last RING_SIZE ticks, indexed by tick.
class Ring {
public:
    Snapshot& at(u32 tick) { return slots_[tick % RING_SIZE]; }
    // True if the slot for `tick` currently holds that tick.
    bool has(u32 tick) { return at(tick).tick() == tick; }

private:
    Snapshot slots_[RING_SIZE];
};

} // namespace sim
