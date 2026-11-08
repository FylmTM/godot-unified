// The survivor-lite state block (spec/GAME.md): one pointer-free, padding-free aggregate. Snapshots are a
// memcpy of it, the checksum hashes its bytes, and a portable snapshot ships its bytes as-is (every target
// is little-endian and the layout is fixed by static asserts). Box3D bodies are referenced by BodyRef.
#pragma once

#include <bit>

#include "core/base.h"
#include "core/input.h"
#include "core/pod_check.h"
#include "physics/physics.h"

namespace game {

using uni::Array;

constexpr f32 DT = 0.016666668f;
static_assert(std::bit_cast<u32>(DT) == 0x3C888889u);
constexpr int SUBSTEPS = 4;

constexpr int MAX_PLAYERS = uni::MAX_PLAYERS;
constexpr int MAX_ENEMIES = 1200;
constexpr int MAX_PROJECTILES = 512;
constexpr int MAX_GEMS = 1024;
constexpr int ITEM_COUNT = 40; // 24 crates + 16 barrels on a 5 x 8 grid
constexpr int PILLAR_COUNT = 8;

enum EnemyKind : u8 { GRUNT = 0, RUNNER = 1, BRUTE = 2 };
enum ItemKind : u8 { CRATE = 0, BARREL = 1 };

// -Wpadded as an error: no implicit padding anywhere in the block, so its bytes are fully determined by
// its fields (padding would otherwise carry garbage into checksums and snapshots).
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic error "-Wpadded"
#endif

struct Player {
    phys::BodyRef body; // valid while alive
    f32 x, y, z;        // body position, read back after each physics step
    f32 move_speed;
    i32 hp;
    i32 damage_bonus;
    i32 xp;
    i32 level;
    i32 pending_levelups;
    u16 fire_interval;
    u16 fire_cooldown;
    u16 dash_ticks;
    u16 dash_cooldown;
    u16 respawn_timer;
    u8 active; // slot is in the game (joined, not absent)
    u8 alive;
    u8 prev_buttons; // for the dash edge
    u8 reserved0, reserved1, reserved2;
};

struct Item { // crate or barrel
    phys::BodyRef body;
    i32 hp; // barrels only
    u16 respawn_timer;
    u8 kind; // ItemKind
    u8 alive;
};

struct Enemy {
    f32 x, z;
    f32 vx, vz;
    i32 hp;
    u8 kind; // EnemyKind
    u8 alive;
    u8 climbing;
    u8 contact_cooldown;
};

struct Projectile {
    f32 x, y, z;
    f32 vx, vz;
    i32 damage;
    u16 life;
    u8 alive;
    u8 owner;
};

struct Gem {
    f32 x, z;
    i32 xp;
    u8 alive;
    u8 reserved0, reserved1, reserved2;
};

// Stable-index slot allocator: a LIFO free list threaded through `next_free`. Removing never moves
// another slot (swap-remove would reorder iteration and change results).
template <int N>
struct SlotPool {
    static_assert(N < 0xFFFF);
    Array<u16, N> next_free;
    u16 free_head; // NO_SLOT when empty
    u16 high_water; // slots [0, high_water) have been handed out at least once
    u16 count;      // live slots
    u16 reserved;
};
constexpr u16 NO_SLOT = 0xFFFF;

struct State {
    u64 seed;
    u32 tick; // completed steps; the state after the k-th step is tick k
    u32 rng;  // xorshift32 for the spawner
    u32 spawn_cap;
    u32 initial_players;
    u32 enemies_killed;
    u32 barrels_exploded;
    Array<Player, MAX_PLAYERS> players;
    Array<Item, ITEM_COUNT> items;
    Array<Enemy, MAX_ENEMIES> enemies;
    SlotPool<MAX_ENEMIES> enemy_pool;
    Array<Projectile, MAX_PROJECTILES> projectiles;
    SlotPool<MAX_PROJECTILES> projectile_pool;
    Array<Gem, MAX_GEMS> gems;
    SlotPool<MAX_GEMS> gem_pool;
};

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

static_assert(uni::pod::is_portable_pod<State>(), "State must be a pointer-free POD");
static_assert(sizeof(Player) == 60 && sizeof(Item) == 16 && sizeof(Enemy) == 24 && sizeof(Projectile) == 28 &&
              sizeof(Gem) == 16 && sizeof(phys::BodyRef) == 8);

// Changes whenever the block layout changes; stored in portable snapshots to reject a foreign layout.
constexpr u64 state_layout_hash() {
    u64 h = 1469598103934665603ull;
    const u64 parts[] = {sizeof(State), sizeof(Player), sizeof(Item), sizeof(Enemy), sizeof(Projectile), sizeof(Gem),
                         (u64)MAX_ENEMIES, (u64)MAX_PROJECTILES, (u64)MAX_GEMS, (u64)ITEM_COUNT,
                         offsetof(State, players), offsetof(State, enemies), offsetof(State, gem_pool)};
    for (u64 p : parts) {
        h ^= p;
        h *= 1099511628211ull;
    }
    return h;
}

} // namespace game
