// The tick: systems 1-11 of spec/GAME.md, in that order. Formulas use only + - * / sqrt on f32, written
// in a fixed evaluation order; the build keeps FP contraction off.
#include <cmath>

#include "game/game.h"
#include "game/pool.h"
#include "game/tables.h"

namespace game {

using phys::Vec3;

// ---- spawning helpers (also used by setup) -------------------------------------------------------

phys::BodyRef spawn_item_body(phys::World& world, int i) {
    Vec3 pos{item_x(i), 1.0f, item_z(i)};
    if (item_is_barrel(i)) return world.add_capsule(pos, 0.4f, 0.3f, 1.0f, phys::CAT_BARREL, false, true);
    return world.add_dynamic_box(pos, 0.5f, 1.0f, phys::CAT_CRATE);
}

void reset_player(State& s, int p) {
    Player& pl = s.players[p];
    pl = Player{};
    pl.active = 1;
    pl.hp = PLAYER_HP;
    pl.move_speed = PLAYER_SPEED;
    pl.fire_interval = FIRE_INTERVAL;
    pl.x = PLAYER_START_X[p];
    pl.y = PLAYER_START_Y;
    pl.z = PLAYER_START_Z[p];
}

void spawn_player_body(State& s, phys::World& world, int p) {
    Player& pl = s.players[p];
    pl.body = world.add_capsule({PLAYER_START_X[p], PLAYER_START_Y, PLAYER_START_Z[p]}, PLAYER_RADIUS, 0.45f, 1.0f,
                                phys::CAT_PLAYER, true, false);
    pl.alive = 1;
    pl.hp = PLAYER_HP;
    pl.x = PLAYER_START_X[p];
    pl.y = PLAYER_START_Y;
    pl.z = PLAYER_START_Z[p];
}

void spawn_enemy(State& s) {
    u32 k = xorshift32(s.rng) % 8u;
    f32 jx = (f32)(xorshift32(s.rng) % 1000u) / 1000.0f * 2.0f - 1.0f;
    f32 jz = (f32)(xorshift32(s.rng) % 1000u) / 1000.0f * 2.0f - 1.0f;
    u32 roll = xorshift32(s.rng) % 10u;
    u8 kind = roll < 7u ? GRUNT : (roll < 9u ? RUNNER : BRUTE);
    int slot = pool_alloc(s.enemy_pool);
    UNI_CHECK(slot >= 0, "enemy pool exhausted");
    Enemy& e = s.enemies[slot];
    e = Enemy{};
    e.x = SPAWN_RING * RING_C[k] + jx;
    e.z = SPAWN_RING * RING_S[k] + jz;
    e.hp = ENEMY_SPECS[kind].hp;
    e.kind = kind;
    e.alive = 1;
}

static void kill_player(State& s, phys::World& world, int p) {
    Player& pl = s.players[p];
    world.destroy_body(pl.body);
    pl.body = phys::BodyRef{};
    pl.alive = 0;
    pl.respawn_timer = RESPAWN_TICKS;
    pl.dash_ticks = 0;
}

static void damage_player(State& s, phys::World& world, int p, i32 damage) {
    Player& pl = s.players[p];
    pl.hp -= damage;
    if (pl.hp <= 0) kill_player(s, world, p);
}

static void add_xp(State& s, int p, i32 xp) {
    Player& pl = s.players[p];
    pl.xp += xp;
    for (;;) {
        i32 threshold = 10 + pl.level * 5;
        if (pl.xp < threshold) break;
        pl.xp -= threshold;
        pl.level += 1;
        pl.pending_levelups += 1;
    }
}

static f32 dist2(f32 ax, f32 az, f32 bx, f32 bz) {
    f32 dx = ax - bx;
    f32 dz = az - bz;
    f32 a = dx * dx;
    f32 b = dz * dz;
    return a + b;
}

// Nearest alive player to (x, z), lowest index on ties; -1 if none.
static int nearest_player(const State& s, f32 x, f32 z) {
    int best = -1;
    f32 best_d2 = INFINITY;
    for (int p = 0; p < MAX_PLAYERS; ++p) {
        const Player& pl = s.players[p];
        if (!pl.alive) continue;
        f32 d2 = dist2(pl.x, pl.z, x, z);
        if (d2 < best_d2) {
            best = p;
            best_d2 = d2;
        }
    }
    return best;
}

// ---- spatial grid --------------------------------------------------------------------------------

static i32 cell_coord(f32 v) {
    i32 c = (i32)((v + ARENA_HALF) * 0.5f);
    if (c < 0) c = 0;
    if (c > GRID - 1) c = GRID - 1;
    return c;
}

static void build_grid(const State& s, Scratch& g) {
    for (int c = 0; c < GRID_CELLS; ++c) {
        g.cell_count[c] = 0;
        g.cell_fill[c] = 0;
    }
    const int n = s.enemy_pool.high_water;
    for (int i = 0; i < n; ++i) {
        const Enemy& e = s.enemies[i];
        if (!e.alive) continue;
        i32 cell = cell_coord(e.z) * GRID + cell_coord(e.x);
        g.cell_of[i] = cell;
        g.cell_count[cell]++;
    }
    i32 acc = 0;
    for (int c = 0; c < GRID_CELLS; ++c) {
        g.cell_start[c] = acc;
        acc += g.cell_count[c];
    }
    for (int i = 0; i < n; ++i) {
        if (!s.enemies[i].alive) continue;
        i32 cell = g.cell_of[i];
        g.items[g.cell_start[cell] + g.cell_fill[cell]++] = i;
    }
}

// Calls fn(j) for every enemy in the 3x3 cells around (x, z): rows outer, columns inner, index order
// within a cell.
template <class Fn>
static void for_neighbours(const Scratch& g, f32 x, f32 z, Fn&& fn) {
    const i32 cx = cell_coord(x);
    const i32 cz = cell_coord(z);
    for (i32 nz = cz - 1; nz <= cz + 1; ++nz) {
        if (nz < 0 || nz >= GRID) continue;
        for (i32 nx = cx - 1; nx <= cx + 1; ++nx) {
            if (nx < 0 || nx >= GRID) continue;
            const i32 cell = nz * GRID + nx;
            const i32 begin = g.cell_start[cell];
            const i32 end = begin + g.cell_count[cell];
            for (i32 k = begin; k < end; ++k) fn(g.items[k]);
        }
    }
}

// ---- 1. players ----------------------------------------------------------------------------------

static void players_system(State& s, phys::World& world, const uni::Input (&inputs)[MAX_PLAYERS]) {
    for (int p = 0; p < MAX_PLAYERS; ++p) {
        Player& pl = s.players[p];
        const uni::Input& in = inputs[p];
        if (in.absent()) { // left (or never joined): the slot goes empty
            if (pl.active) {
                if (pl.alive) world.destroy_body(pl.body);
                pl = Player{};
            }
            continue;
        }
        if (!pl.active) { // joined: first non-absent input
            reset_player(s, p);
            spawn_player_body(s, world, p);
        }
        if (!pl.alive) {
            if (pl.respawn_timer > 0) pl.respawn_timer--;
            if (pl.respawn_timer > 0) {
                pl.prev_buttons = in.buttons;
                continue;
            }
            spawn_player_body(s, world, p);
        }
        if (pl.dash_cooldown > 0) pl.dash_cooldown--;
        bool pressed = (in.buttons & uni::BUTTON_DASH) != 0 && (pl.prev_buttons & uni::BUTTON_DASH) == 0;
        if (pressed && pl.dash_cooldown == 0) {
            pl.dash_ticks = DASH_TICKS;
            pl.dash_cooldown = DASH_COOLDOWN;
        }
        f32 dirx = (f32)in.move_x / 127.0f;
        f32 dirz = (f32)in.move_z / 127.0f;
        f32 vx = dirx * pl.move_speed;
        f32 vz = dirz * pl.move_speed;
        if (pl.dash_ticks > 0) {
            vx = vx * DASH_MULTIPLIER;
            vz = vz * DASH_MULTIPLIER;
            pl.dash_ticks--;
        }
        Vec3 v = world.linear_velocity(pl.body);
        world.set_linear_velocity(pl.body, {vx, v.y, vz});
        pl.prev_buttons = in.buttons;
    }
}

// ---- 2. level-up ---------------------------------------------------------------------------------

static void levelup_system(State& s, const uni::Input (&inputs)[MAX_PLAYERS]) {
    for (int p = 0; p < MAX_PLAYERS; ++p) {
        Player& pl = s.players[p];
        u8 choice = inputs[p].choice;
        if (!pl.active || pl.pending_levelups <= 0 || choice < 1 || choice > 3) continue;
        if (choice == 1) {
            pl.fire_interval = pl.fire_interval >= FIRE_INTERVAL_MIN + 2 ? (u16)(pl.fire_interval - 2) : FIRE_INTERVAL_MIN;
        } else if (choice == 2) {
            pl.damage_bonus += 3;
        } else {
            pl.move_speed = pl.move_speed + 0.5f;
        }
        pl.pending_levelups -= 1;
    }
}

// ---- 3. spawner ----------------------------------------------------------------------------------

static void spawner_system(State& s, u32 t) {
    if (t % SPAWN_PERIOD != 0) return;
    u32 wave = t / WAVE_TICKS;
    u32 n = 4u + wave * 3u;
    if (n > SPAWN_MAX_BATCH) n = SPAWN_MAX_BATCH;
    for (u32 i = 0; i < n; ++i) {
        if ((u32)s.enemy_pool.count >= s.spawn_cap) break;
        spawn_enemy(s);
    }
}

// ---- 4. enemies ----------------------------------------------------------------------------------

static void enemies_system(State& s, phys::World& world, Scratch& g, u32 t) {
    build_grid(s, g);
    const int n = s.enemy_pool.high_water;

    // Phase 1 (Jacobi): velocities from old positions.
    for (int i = 0; i < n; ++i) {
        Enemy& e = s.enemies[i];
        if (!e.alive) continue;
        const EnemySpec& spec = ENEMY_SPECS[e.kind];

        if (((u32)i + t) % 8u == 0u) {
            phys::RayHit hit = world.cast_ray_closest({e.x, 3.0f, e.z}, {0.0f, -3.0f, 0.0f});
            e.climbing = (hit.hit && (hit.category & (phys::CAT_CRATE | phys::CAT_BARREL)) != 0 && hit.point.y > 0.8f)
                             ? 1
                             : 0;
        }
        f32 speed = spec.speed;
        if (e.climbing) speed = speed * 0.5f;

        f32 desx = 0.0f, desz = 0.0f;
        int target = nearest_player(s, e.x, e.z);
        if (target >= 0) {
            f32 dx = s.players[target].x - e.x;
            f32 dz = s.players[target].z - e.z;
            f32 len = std::sqrt(dx * dx + dz * dz);
            if (len > 0.0001f) {
                desx = dx / len * speed;
                desz = dz / len * speed;
            }
        }

        f32 sepx = 0.0f, sepz = 0.0f;
        const f32 xi = e.x, zi = e.z, ri = spec.radius;
        for_neighbours(g, xi, zi, [&](i32 j) {
            if (j == i) return;
            const Enemy& o = s.enemies[j];
            f32 ox = xi - o.x;
            f32 oz = zi - o.z;
            f32 d2 = ox * ox + oz * oz;
            f32 rr = ri + ENEMY_SPECS[o.kind].radius;
            if (d2 < rr * rr && d2 > 0.00000001f) {
                f32 inv = 0.5f / d2;
                sepx = sepx + ox * inv;
                sepz = sepz + oz * inv;
            }
        });
        desx = desx + sepx;
        desz = desz + sepz;

        f32 t1 = e.vx * 0.8f;
        f32 t2 = desx * 0.2f;
        f32 nvx = t1 + t2;
        f32 u1 = e.vz * 0.8f;
        f32 u2 = desz * 0.2f;
        f32 nvz = u1 + u2;

        f32 max_speed = speed * 1.5f;
        f32 s2 = nvx * nvx + nvz * nvz;
        if (s2 > max_speed * max_speed) {
            f32 k = max_speed / std::sqrt(s2);
            nvx = nvx * k;
            nvz = nvz * k;
        }
        g.nvx[i] = nvx;
        g.nvz[i] = nvz;
    }

    // Phase 2: integrate, push out of pillars, clamp to the arena.
    for (int i = 0; i < n; ++i) {
        Enemy& e = s.enemies[i];
        if (!e.alive) continue;
        const f32 r = ENEMY_SPECS[e.kind].radius;
        e.vx = g.nvx[i];
        e.vz = g.nvz[i];
        f32 x = e.x + e.vx * DT;
        f32 z = e.z + e.vz * DT;
        const f32 ext = PILLAR_HALF + r;
        for (int k = 0; k < PILLAR_COUNT; ++k) {
            f32 px = PILLAR_RING * RING_C[k];
            f32 pz = PILLAR_RING * RING_S[k];
            f32 dx = x - px;
            f32 dz = z - pz;
            f32 adx = std::fabs(dx);
            f32 adz = std::fabs(dz);
            if (adx < ext && adz < ext) {
                f32 penx = ext - adx;
                f32 penz = ext - adz;
                if (penx < penz) {
                    x = dx >= 0.0f ? px + ext : px - ext;
                } else {
                    z = dz >= 0.0f ? pz + ext : pz - ext;
                }
            }
        }
        const f32 lim = ARENA_HALF - r;
        if (x < -lim) x = -lim;
        if (x > lim) x = lim;
        if (z < -lim) z = -lim;
        if (z > lim) z = lim;
        e.x = x;
        e.z = z;
    }
}

// ---- 5. contact damage ---------------------------------------------------------------------------

static void contact_system(State& s, phys::World& world) {
    const int n = s.enemy_pool.high_water;
    for (int i = 0; i < n; ++i) {
        Enemy& e = s.enemies[i];
        if (!e.alive) continue;
        if (e.contact_cooldown > 0) e.contact_cooldown--;
        if (e.contact_cooldown > 0) continue;
        const EnemySpec& spec = ENEMY_SPECS[e.kind];
        f32 rr = spec.radius + PLAYER_RADIUS;
        for (int p = 0; p < MAX_PLAYERS; ++p) {
            const Player& pl = s.players[p];
            if (!pl.alive) continue;
            if (dist2(pl.x, pl.z, e.x, e.z) < rr * rr) {
                e.contact_cooldown = CONTACT_COOLDOWN;
                damage_player(s, world, p, spec.damage);
                break;
            }
        }
    }
}

// ---- 6. auto-attack ------------------------------------------------------------------------------

static void attack_system(State& s) {
    const int n = s.enemy_pool.high_water;
    for (int p = 0; p < MAX_PLAYERS; ++p) {
        Player& pl = s.players[p];
        if (!pl.alive) continue;
        if (pl.fire_cooldown > 0) pl.fire_cooldown--;
        if (pl.fire_cooldown > 0) continue;
        int best = -1;
        f32 best_d2 = FIRE_RANGE * FIRE_RANGE;
        for (int i = 0; i < n; ++i) {
            const Enemy& e = s.enemies[i];
            if (!e.alive) continue;
            f32 d2 = dist2(e.x, e.z, pl.x, pl.z);
            if (d2 < best_d2 || (best < 0 && d2 == best_d2)) {
                best = i;
                best_d2 = d2;
            }
        }
        if (best < 0 || pool_full(s.projectile_pool)) continue;
        const Enemy& e = s.enemies[best];
        f32 dx = e.x - pl.x;
        f32 dz = e.z - pl.z;
        f32 len = std::sqrt(dx * dx + dz * dz);
        f32 vx = PROJECTILE_SPEED, vz = 0.0f;
        if (len > 0.0001f) {
            vx = dx / len * PROJECTILE_SPEED;
            vz = dz / len * PROJECTILE_SPEED;
        }
        int slot = pool_alloc(s.projectile_pool);
        Projectile& pr = s.projectiles[slot];
        pr = Projectile{};
        pr.x = pl.x;
        pr.y = pl.y;
        pr.z = pl.z;
        pr.vx = vx;
        pr.vz = vz;
        pr.damage = BASE_DAMAGE + pl.damage_bonus;
        pr.life = PROJECTILE_LIFE;
        pr.alive = 1;
        pr.owner = (u8)p;
        pl.fire_cooldown = pl.fire_interval;
    }
}

// ---- 7. projectiles ------------------------------------------------------------------------------

static int barrel_by_body(const State& s, phys::BodyRef body) {
    for (int i = 0; i < ITEM_COUNT; ++i) {
        const Item& it = s.items[i];
        if (it.alive && it.kind == BARREL && it.body.index1 == body.index1 && it.body.generation == body.generation)
            return i;
    }
    return -1;
}

static void kill_projectile(State& s, int j) {
    s.projectiles[j].alive = 0;
    pool_free(s.projectile_pool, j);
}

static void projectiles_system(State& s, phys::World& world, Scratch& g) {
    build_grid(s, g); // enemies moved in system 4
    const int n = s.projectile_pool.high_water;
    for (int j = 0; j < n; ++j) {
        Projectile& pr = s.projectiles[j];
        if (!pr.alive) continue;
        const f32 ox = pr.x, oz = pr.z;
        pr.x = pr.x + pr.vx * DT;
        pr.z = pr.z + pr.vz * DT;

        int hit_enemy = -1;
        for_neighbours(g, pr.x, pr.z, [&](i32 i) {
            const Enemy& e = s.enemies[i];
            if (e.hp <= 0 || (hit_enemy >= 0 && i > hit_enemy)) return;
            f32 rr = ENEMY_SPECS[e.kind].radius + PROJECTILE_RADIUS;
            if (dist2(pr.x, pr.z, e.x, e.z) < rr * rr) hit_enemy = i;
        });
        if (hit_enemy >= 0) {
            s.enemies[hit_enemy].hp -= pr.damage;
            kill_projectile(s, j);
            continue;
        }

        phys::RayHit hit = world.cast_ray_closest({ox, pr.y, oz}, {pr.x - ox, 0.0f, pr.z - oz});
        if (hit.hit) {
            if (hit.category & phys::CAT_BARREL) {
                int b = barrel_by_body(s, hit.body);
                if (b >= 0) s.items[b].hp -= pr.damage;
            }
            kill_projectile(s, j);
            continue;
        }

        pr.life--;
        if (pr.life == 0) kill_projectile(s, j);
    }
}

// ---- 8. barrels and explosions -------------------------------------------------------------------

static void blast_body(phys::World& world, phys::BodyRef body, Vec3 c) {
    Vec3 p = world.position(body);
    f32 dx = p.x - c.x;
    f32 dz = p.z - c.z;
    f32 d = std::sqrt(dx * dx + dz * dz);
    if (!(d < EXPLOSION_RADIUS)) return;
    f32 hx = 0.0f, hz = 0.0f;
    if (d > 0.0001f) {
        hx = dx / d;
        hz = dz / d;
    }
    f32 a = hx * hx;
    f32 b = 0.5f * 0.5f;
    f32 cz = hz * hz;
    f32 len = std::sqrt(a + b + cz);
    f32 dirx = hx / len, diry = 0.5f / len, dirz = hz / len;
    f32 mag = EXPLOSION_IMPULSE * (1.0f - d / EXPLOSION_RADIUS);
    world.apply_impulse_at_center(body, {dirx * mag, diry * mag, dirz * mag});
}

static void explode(State& s, phys::World& world, int barrel) {
    Item& it = s.items[barrel];
    const Vec3 c = world.position(it.body);
    for (int i = 0; i < ITEM_COUNT; ++i)
        if (i != barrel && s.items[i].alive) blast_body(world, s.items[i].body, c);
    for (int p = 0; p < MAX_PLAYERS; ++p)
        if (s.players[p].alive) blast_body(world, s.players[p].body, c);

    const int n = s.enemy_pool.high_water;
    const f32 r2 = EXPLOSION_RADIUS * EXPLOSION_RADIUS;
    for (int i = 0; i < n; ++i) {
        Enemy& e = s.enemies[i];
        if (e.alive && dist2(e.x, e.z, c.x, c.z) < r2) e.hp -= EXPLOSION_ENEMY_DAMAGE;
    }
    const f32 pr2 = EXPLOSION_PLAYER_RADIUS * EXPLOSION_PLAYER_RADIUS;
    for (int p = 0; p < MAX_PLAYERS; ++p) {
        const Player& pl = s.players[p];
        if (pl.alive && dist2(pl.x, pl.z, c.x, c.z) < pr2) damage_player(s, world, p, EXPLOSION_PLAYER_DAMAGE);
    }

    world.destroy_body(it.body);
    it.body = phys::BodyRef{};
    it.alive = 0;
    it.hp = 0;
    it.respawn_timer = BARREL_RESPAWN;
    s.barrels_exploded++;
}

static void barrels_system(State& s, phys::World& world) {
    for (int i = 0; i < ITEM_COUNT; ++i) {
        Item& it = s.items[i];
        if (it.kind != BARREL) continue;
        if (!it.alive) {
            if (it.respawn_timer > 0 && --it.respawn_timer == 0) {
                it.body = spawn_item_body(world, i);
                it.hp = BARREL_HP;
                it.alive = 1;
            }
            continue;
        }
        if (it.hp <= 0) explode(s, world, i);
    }
}

// ---- 9. deaths and XP ----------------------------------------------------------------------------

static void deaths_system(State& s) {
    const int n = s.enemy_pool.high_water;
    for (int i = 0; i < n; ++i) {
        Enemy& e = s.enemies[i];
        if (!e.alive || e.hp > 0) continue;
        const i32 xp = ENEMY_SPECS[e.kind].xp;
        const f32 x = e.x, z = e.z;
        e.alive = 0;
        pool_free(s.enemy_pool, i);
        s.enemies_killed++;
        int slot = pool_alloc(s.gem_pool);
        if (slot >= 0) {
            Gem& gem = s.gems[slot];
            gem = Gem{};
            gem.x = x;
            gem.z = z;
            gem.xp = xp;
            gem.alive = 1;
        } else {
            int p = nearest_player(s, x, z);
            if (p >= 0) add_xp(s, p, xp);
        }
    }

    const f32 pick2 = GEM_PICKUP_RADIUS * GEM_PICKUP_RADIUS;
    const int gn = s.gem_pool.high_water;
    for (int g = 0; g < gn; ++g) {
        Gem& gem = s.gems[g];
        if (!gem.alive) continue;
        for (int p = 0; p < MAX_PLAYERS; ++p) {
            const Player& pl = s.players[p];
            if (pl.alive && dist2(pl.x, pl.z, gem.x, gem.z) < pick2) {
                add_xp(s, p, gem.xp);
                gem.alive = 0;
                pool_free(s.gem_pool, g);
                break;
            }
        }
    }
}

// ---- 10-11. physics and read-back ----------------------------------------------------------------

static void readback(State& s, const phys::World& world) {
    for (int p = 0; p < MAX_PLAYERS; ++p) {
        Player& pl = s.players[p];
        if (!pl.alive) continue;
        Vec3 pos = world.position(pl.body);
        pl.x = pos.x;
        pl.y = pos.y;
        pl.z = pos.z;
    }
}

void step(State& s, phys::World& world, Scratch& scratch, const uni::Input (&inputs)[MAX_PLAYERS]) {
    const u32 t = s.tick;
    players_system(s, world, inputs);
    levelup_system(s, inputs);
    spawner_system(s, t);
    enemies_system(s, world, scratch, t);
    contact_system(s, world);
    attack_system(s);
    projectiles_system(s, world, scratch);
    barrels_system(s, world);
    deaths_system(s);
    world.step(DT, SUBSTEPS);
    readback(s, world);
    s.tick = t + 1;
}

} // namespace game
