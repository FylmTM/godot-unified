#include "sim/sim.h"

#include <cstring>

#include "core/bytes.h"

namespace sim {

static constexpr char SNAP_MAGIC[4] = {'U', 'N', 'I', 'S'};
static constexpr u16 SNAP_VERSION = 1;

Snapshot::Snapshot() : state(std::make_unique<game::State>()) {
    std::memset(state.get(), 0, sizeof(game::State));
    state->tick = 0xFFFFFFFFu; // empty
}

Sim::Sim()
    : state_(std::make_unique<game::State>()), world_(std::make_unique<phys::World>()),
      scratch_(std::make_unique<game::Scratch>()) {
    std::memset(state_.get(), 0, sizeof(game::State));
}

Sim::~Sim() = default;

void Sim::setup(u64 seed, int players) { game::setup(*state_, *world_, seed, players); }

void Sim::step(const uni::TickInputs& inputs) { game::step(*state_, *world_, *scratch_, inputs.players); }

u64 Sim::checksum() const { return game::checksum(*state_, *world_); }

void Sim::save(Snapshot& out) {
    std::memcpy(out.state.get(), state_.get(), sizeof(game::State));
    world_->save(out.physics);
}

void Sim::restore(const Snapshot& in) {
    std::memcpy(state_.get(), in.state.get(), sizeof(game::State));
    UNI_CHECK(world_->restore(in.physics), "b3World_RestoreState failed");
}

bool Sim::levelup_pending(int player) const { return state_->players[player].pending_levelups > 0; }

std::vector<u8> Sim::encode_portable() {
    Snapshot snap;
    save(snap);
    return encode_portable(snap);
}

std::vector<u8> Sim::encode_portable(const Snapshot& snap) {
    std::vector<u8> out;
    out.reserve(32 + snap.bytes());
    uni::ByteWriter w(out);
    w.put_bytes(SNAP_MAGIC, 4);
    w.put_u16(SNAP_VERSION);
    w.put_u16(0);
    w.put_u64(game::state_layout_hash());
    w.put_u32((u32)sizeof(game::State));
    w.put_u32((u32)snap.physics.size());
    w.put_bytes(snap.state.get(), sizeof(game::State));
    w.put_bytes(snap.physics.data(), snap.physics.size());
    return out;
}

bool Sim::load_portable(const u8* data, usize size, std::string& error) {
    uni::ByteReader r(data, size);
    const u8* magic = r.get_bytes(4);
    if (!magic || std::memcmp(magic, SNAP_MAGIC, 4) != 0) {
        error = "not a unified snapshot";
        return false;
    }
    u16 version = r.get_u16();
    r.get_u16();
    u64 layout = r.get_u64();
    u32 state_bytes = r.get_u32();
    u32 phys_bytes = r.get_u32();
    if (!r.ok() || version != SNAP_VERSION || layout != game::state_layout_hash() ||
        state_bytes != sizeof(game::State)) {
        error = "snapshot version or state layout mismatch";
        return false;
    }
    const u8* block = r.get_bytes(state_bytes);
    const u8* image = r.get_bytes(phys_bytes);
    if (!block || !image || !r.at_end()) {
        error = "truncated snapshot";
        return false;
    }
    // Build the same tick-0 world first: it primes the geometry registry exactly as the saving process did.
    setup(1, game::MAX_PLAYERS);
    Snapshot snap;
    std::memcpy(snap.state.get(), block, state_bytes);
    snap.physics.assign(image, phys_bytes);
    std::memcpy(state_.get(), snap.state.get(), sizeof(game::State));
    if (!world_->restore(snap.physics)) {
        error = "physics image rejected by b3World_RestoreState";
        return false;
    }
    return true;
}

} // namespace sim
