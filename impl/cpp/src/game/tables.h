// Gameplay constants and tables shared by the game's translation units.
#pragma once

#include "game/state.h"

namespace game {

// Angle table for k * 45 degrees (no trig in the sim).
inline constexpr f32 RING_C[8] = {1.0f, 0.70710677f, 0.0f, -0.70710677f, -1.0f, -0.70710677f, 0.0f, 0.70710677f};
inline constexpr f32 RING_S[8] = {0.0f, 0.70710677f, 1.0f, 0.70710677f, 0.0f, -0.70710677f, -1.0f, -0.70710677f};

constexpr f32 ARENA_HALF = 30.0f;
constexpr f32 PILLAR_RING = 14.0f;
constexpr f32 PILLAR_HALF = 1.0f;

constexpr i32 PLAYER_HP = 100;
constexpr f32 PLAYER_SPEED = 6.0f;
constexpr f32 PLAYER_RADIUS = 0.45f;
constexpr f32 DASH_MULTIPLIER = 3.0f;
constexpr u16 DASH_TICKS = 8;
constexpr u16 DASH_COOLDOWN = 90;
constexpr u16 RESPAWN_TICKS = 180;
constexpr u16 FIRE_INTERVAL = 20;
constexpr u16 FIRE_INTERVAL_MIN = 6;
constexpr f32 FIRE_RANGE = 14.0f;
constexpr f32 PROJECTILE_SPEED = 16.0f;
constexpr u16 PROJECTILE_LIFE = 60;
constexpr f32 PROJECTILE_RADIUS = 0.15f;
constexpr i32 BASE_DAMAGE = 5;

inline constexpr f32 PLAYER_START_X[MAX_PLAYERS] = {4.0f, -4.0f, 4.0f, -4.0f};
inline constexpr f32 PLAYER_START_Z[MAX_PLAYERS] = {4.0f, 4.0f, -4.0f, -4.0f};
constexpr f32 PLAYER_START_Y = 1.0f;

constexpr u32 WAVE_TICKS = 600;
constexpr u32 SPAWN_PERIOD = 20;
constexpr u32 SPAWN_MAX_BATCH = 40;
constexpr f32 SPAWN_RING = 27.0f;
constexpr u8 CONTACT_COOLDOWN = 30;

constexpr i32 BARREL_HP = 30;
constexpr u16 BARREL_RESPAWN = 600;
constexpr f32 EXPLOSION_RADIUS = 5.0f;
constexpr f32 EXPLOSION_IMPULSE = 12.0f;
constexpr i32 EXPLOSION_ENEMY_DAMAGE = 25;
constexpr f32 EXPLOSION_PLAYER_RADIUS = 3.0f;
constexpr i32 EXPLOSION_PLAYER_DAMAGE = 15;

constexpr f32 GEM_PICKUP_RADIUS = 1.5f;

struct EnemySpec {
    i32 hp;
    f32 speed;
    f32 radius;
    i32 damage;
    i32 xp;
};
inline constexpr EnemySpec ENEMY_SPECS[3] = {
    {10, 2.0f, 0.4f, 5, 1},  // grunt
    {6, 3.2f, 0.35f, 3, 1},  // runner
    {40, 1.2f, 0.7f, 12, 5}, // brute
};

inline u32 xorshift32(u32& state) {
    u32 x = state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state = x;
    return x;
}

// Item i on the 5 x 8 grid.
inline f32 item_x(int i) { return (f32)((i % 8) * 4 - 14); }
inline f32 item_z(int i) { return (f32)((i / 8) * 4 - 8); }
inline bool item_is_barrel(int i) { return i % 5 == 2; }

// Spawning helpers shared by setup (world.cpp) and the systems (systems.cpp).
void reset_player(State& s, int p);
void spawn_player_body(State& s, phys::World& world, int p);
void spawn_enemy(State& s);
phys::BodyRef spawn_item_body(phys::World& world, int i);

} // namespace game
