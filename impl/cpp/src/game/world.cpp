// World setup (spec/GAME.md "World", in creation order) and the checksum.
#include <bit>
#include <cstring>

#include "core/hash.h"
#include "game/game.h"
#include "game/pool.h"
#include "game/tables.h"

namespace game {

void setup(State& s, phys::World& world, u64 seed, int players) {
    UNI_CHECK(players >= 1 && players <= MAX_PLAYERS, "players must be 1..%d", MAX_PLAYERS);
    std::memset(&s, 0, sizeof(State));
    s.seed = seed;
    s.rng = (u32)seed == 0 ? 1u : (u32)seed;
    s.spawn_cap = MAX_ENEMIES;
    s.initial_players = (u32)players;
    pool_reset(s.enemy_pool);
    pool_reset(s.projectile_pool);
    pool_reset(s.gem_pool);

    // Ground, then the walls (+x, -x, +z, -z) whose inner faces are at +-30, 3 m high, 1 m thick.
    world.add_static_box({0.0f, -0.5f, 0.0f}, {32.0f, 0.5f, 32.0f});
    world.add_static_box({30.5f, 1.5f, 0.0f}, {0.5f, 1.5f, 31.0f});
    world.add_static_box({-30.5f, 1.5f, 0.0f}, {0.5f, 1.5f, 31.0f});
    world.add_static_box({0.0f, 1.5f, 30.5f}, {31.0f, 1.5f, 0.5f});
    world.add_static_box({0.0f, 1.5f, -30.5f}, {31.0f, 1.5f, 0.5f});
    for (int k = 0; k < PILLAR_COUNT; ++k)
        world.add_static_box({PILLAR_RING * RING_C[k], 1.5f, PILLAR_RING * RING_S[k]}, {PILLAR_HALF, 1.5f, PILLAR_HALF});

    for (int i = 0; i < ITEM_COUNT; ++i) {
        Item& it = s.items[i];
        it.kind = item_is_barrel(i) ? BARREL : CRATE;
        it.hp = item_is_barrel(i) ? BARREL_HP : 0;
        it.alive = 1;
        it.body = spawn_item_body(world, i);
    }

    for (int p = 0; p < MAX_PLAYERS; ++p) {
        if (p < players) {
            reset_player(s, p);
            spawn_player_body(s, world, p);
        }
    }

    // Prime the geometry registry: hull blobs get their registry ids in this fixed order in every
    // process, so physics images restore anywhere (see physics.h).
    phys::Snapshot prime;
    world.save(prime);
}

void prespawn(State& s, int count, int cap) {
    s.spawn_cap = (u32)cap;
    for (int i = 0; i < count && (u32)s.enemy_pool.count < s.spawn_cap; ++i) spawn_enemy(s);
}

namespace {
struct BodyHashWriter {
    u8* p;
    void f(f32 v) {
        u32 bits = v == 0.0f ? 0u : std::bit_cast<u32>(v); // -0.0 -> +0.0
        std::memcpy(p, &bits, 4);
        p += 4;
    }
    void body(const phys::BodyState& b) {
        f(b.pos.x), f(b.pos.y), f(b.pos.z);
        f(b.qx), f(b.qy), f(b.qz), f(b.qs);
        f(b.lin.x), f(b.lin.y), f(b.lin.z);
        f(b.ang.x), f(b.ang.y), f(b.ang.z);
    }
};
} // namespace

u64 checksum(const State& s, const phys::World& world) {
    uni::Hasher h;
    h.update(&s, sizeof(State)); // padding-free little-endian block: its bytes are the canonical form
    u8 buf[(MAX_PLAYERS + ITEM_COUNT) * 13 * 4];
    BodyHashWriter w{buf};
    for (int p = 0; p < MAX_PLAYERS; ++p)
        if (s.players[p].alive) w.body(world.body_state(s.players[p].body));
    for (int i = 0; i < ITEM_COUNT; ++i)
        if (s.items[i].alive) w.body(world.body_state(s.items[i].body));
    h.update(buf, (usize)(w.p - buf));
    return h.digest();
}

} // namespace game
