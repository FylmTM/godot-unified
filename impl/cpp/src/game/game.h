// The survivor-lite game: world setup, the fixed-order tick, the checksum, and the scripted inputs.
#pragma once

#include "core/input.h"
#include "game/state.h"
#include "physics/physics.h"

namespace game {

// Per-tick scratch, rebuilt every tick and never part of the state: the enemy spatial grid
// (2 m cells over the 60 x 60 arena, counting sort, items in index order) and phase-1 velocities.
constexpr int GRID = 30;
constexpr int GRID_CELLS = GRID * GRID;

struct Scratch {
    i32 cell_count[GRID_CELLS];
    i32 cell_start[GRID_CELLS];
    i32 cell_fill[GRID_CELLS];
    i32 cell_of[MAX_ENEMIES];
    i32 items[MAX_ENEMIES];
    f32 nvx[MAX_ENEMIES];
    f32 nvz[MAX_ENEMIES];
};

// Builds the arena in `world` (created empty) and the tick-0 state. `players` slots are active at start.
void setup(State& s, phys::World& world, u64 seed, int players);

// Pre-spawns enemies (bench) and caps the spawner at `cap` alive enemies.
void prespawn(State& s, int count, int cap);

// One fixed step: systems 1-11 of spec/GAME.md in order, then tick += 1.
void step(State& s, phys::World& world, Scratch& scratch, const uni::Input (&inputs)[MAX_PLAYERS]);

// XXH3-64 over the block bytes, then every alive body (players, then items) in entity order.
u64 checksum(const State& s, const phys::World& world);

// Scripted inputs (spec/GAME.md): a per-player xorshift32 seeded seed*7919 + p + 1, re-drawn every 24
// ticks. Random access by tick (rewinds recompute from the seed).
class Script {
public:
    Script(u64 seed, int player);
    // The input for tick k (>= 1). `levelup_pending` comes from the current state of the caller.
    uni::Input input(u32 tick, bool levelup_pending);

private:
    u32 seed_state_;
    u32 rng_;
    i64 draw_ = -1; // index of the current draw
    u32 r_ = 0;
};

} // namespace game
