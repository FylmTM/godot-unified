//! The game systems, run in the spec order by `Game::step`. Float expressions use only
//! `+ - * / sqrt`, written in a fixed order (Rust never contracts to FMA).
#![allow(clippy::assign_op_pattern)]

use crate::consts::*;
use crate::grid::Grid;
use crate::rng::xorshift32;
use crate::state::*;
use crate::world::{create_barrel, create_player_body, key, pillar_center};
use box3d_sys::{World, v3};
use simcore::{BUTTON_DASH, DT, InputSet, MAX_PLAYERS};

// --- players ------------------------------------------------------------------------------------

/// A player slot becomes active (joins): fresh stats and a body at its start position.
pub fn join_player(s: &mut State, w: &mut World, p: usize) {
    let pl = &mut s.players[p];
    *pl = Player { active: 1, ..Player::default() };
    pl.fire_interval = FIRE_INTERVAL;
    pl.move_speed = PLAYER_SPEED;
    spawn_player(s, w, p);
}

fn spawn_player(s: &mut State, w: &mut World, p: usize) {
    let pl = &mut s.players[p];
    pl.body = create_player_body(w, p);
    pl.pos = PLAYER_START[p];
    pl.hp = PLAYER_HP;
    pl.alive = 1;
    pl.respawn = 0;
    pl.dash_ticks = 0;
}

fn kill_player(s: &mut State, w: &mut World, p: usize) {
    let pl = &mut s.players[p];
    if pl.alive != 0 {
        w.destroy_body(key(pl.body));
    }
    pl.body = BodyRef::default();
    pl.alive = 0;
    pl.respawn = RESPAWN_TICKS;
    pl.dash_ticks = 0;
}

/// Players at HP <= 0 die (body destroyed, respawn timer set).
fn reap_players(s: &mut State, w: &mut World) {
    for p in 0..MAX_PLAYERS {
        if s.players[p].alive != 0 && s.players[p].hp <= 0 {
            kill_player(s, w, p);
        }
    }
}

/// System 1: join/leave from the absent flag, respawn countdown, velocity and dash.
pub fn players(s: &mut State, w: &mut World, inputs: &InputSet) {
    for (p, inp) in inputs.iter().enumerate() {
        if inp.is_absent() {
            if s.players[p].active != 0 {
                if s.players[p].alive != 0 {
                    w.destroy_body(key(s.players[p].body));
                }
                s.players[p] = Player::default();
            }
            continue;
        }
        if s.players[p].active == 0 {
            join_player(s, w, p);
        }
        if s.players[p].alive == 0 {
            let pl = &mut s.players[p];
            pl.respawn = pl.respawn.saturating_sub(1);
            pl.prev_buttons = inp.buttons;
            if pl.respawn > 0 {
                continue;
            }
            spawn_player(s, w, p);
        }
        let pl = &mut s.players[p];
        if pl.dash_cooldown > 0 {
            pl.dash_cooldown -= 1;
        }
        let pressed = inp.buttons & BUTTON_DASH != 0 && pl.prev_buttons & BUTTON_DASH == 0;
        pl.prev_buttons = inp.buttons;
        if pressed && pl.dash_cooldown == 0 {
            pl.dash_ticks = DASH_TICKS;
            pl.dash_cooldown = DASH_COOLDOWN;
        }
        let dir_x = inp.move_x as f32 / 127.0;
        let dir_z = inp.move_z as f32 / 127.0;
        let mut vx = dir_x * pl.move_speed;
        let mut vz = dir_z * pl.move_speed;
        if pl.dash_ticks > 0 {
            pl.dash_ticks -= 1;
            vx = vx * DASH_MULT;
            vz = vz * DASH_MULT;
        }
        let body = key(pl.body);
        let vy = w.linear_velocity(body).y;
        w.set_linear_velocity(body, v3(vx, vy, vz));
    }
}

/// System 2: one pending level-up per tick, chosen by the input.
pub fn level_up(s: &mut State, inputs: &InputSet) {
    for (p, inp) in inputs.iter().enumerate() {
        let pl = &mut s.players[p];
        if pl.active == 0 || pl.pending_levelups == 0 {
            continue;
        }
        match inp.choice {
            1 => pl.fire_interval = pl.fire_interval.saturating_sub(2).max(FIRE_INTERVAL_MIN),
            2 => pl.damage_bonus += 3,
            3 => pl.move_speed = pl.move_speed + 0.5,
            _ => continue,
        }
        pl.pending_levelups -= 1;
    }
}

// --- enemies ------------------------------------------------------------------------------------

pub fn spawn_enemy(s: &mut State, x: f32, z: f32, kind: u8) -> Option<Handle> {
    let h = s.enemies.alloc()?;
    let e = &mut s.enemies;
    let i = h.index as usize;
    e.px[i] = x;
    e.pz[i] = z;
    e.vx[i] = 0.0;
    e.vz[i] = 0.0;
    e.hp[i] = KINDS[kind as usize].hp;
    e.kind[i] = kind;
    e.climbing[i] = 0;
    e.contact_cd[i] = 0;
    Some(h)
}

fn kind_from_roll(roll: u32) -> u8 {
    match roll {
        0..=6 => 0,
        7..=8 => 1,
        _ => 2,
    }
}

/// System 3: every 20 ticks spawn `min(4 + wave * 3, 40)` enemies on the ring while below the cap.
pub fn spawner(s: &mut State, t: u32) {
    if !t.is_multiple_of(SPAWN_EVERY) {
        return;
    }
    let wave = t / WAVE_TICKS;
    let n = (4 + wave * 3).min(SPAWN_MAX_BATCH);
    for _ in 0..n {
        if s.enemies.count >= s.enemy_limit {
            break;
        }
        let k = (xorshift32(&mut s.rng) % 8) as usize;
        let jitter = (xorshift32(&mut s.rng) % 1000) as f32 / 1000.0 * 2.0 - 1.0;
        let kind = kind_from_roll(xorshift32(&mut s.rng) % 10);
        let x = SPAWN_RING * COS[k] + jitter;
        let z = SPAWN_RING * SIN[k] + jitter;
        spawn_enemy(s, x, z, kind);
    }
}

fn nearest_alive_player(s: &State, x: f32, z: f32) -> Option<(usize, f32, f32, f32)> {
    let mut best = None;
    let mut best_d2 = f32::INFINITY;
    for (p, pl) in s.players.iter().enumerate() {
        if pl.alive == 0 {
            continue;
        }
        let dx = pl.pos[0] - x;
        let dz = pl.pos[2] - z;
        let d2 = dx * dx + dz * dz;
        if d2 < best_d2 {
            best_d2 = d2;
            best = Some((p, dx, dz, d2));
        }
    }
    best
}

/// System 4: enemy steering (Jacobi: phase 1 from old positions, phase 2 integrates), pillar
/// push-out, arena clamp, and the every-8-ticks climb ray.
pub fn enemies(s: &mut State, w: &World, grid: &mut Grid, nv: &mut [[f32; 2]], t: u32) {
    grid.build(&s.enemies);
    for i in 0..MAX_ENEMIES {
        if s.enemies.alive[i] == 0 {
            continue;
        }
        let e = &s.enemies;
        let kd = KINDS[e.kind[i] as usize];
        let (x, z) = (e.px[i], e.pz[i]);
        let climbing = if (i as u32 + t).is_multiple_of(CLIMB_EVERY) {
            let hit = w.cast_ray_closest(v3(x, CLIMB_RAY_Y, z), v3(0.0, -CLIMB_RAY_Y, 0.0), RAY_MASK);
            let kind = hit.map(|h| h.user_id & !0xFFFF_FFFF);
            let c = matches!(kind, Some(UID_CRATE) | Some(UID_BARREL)) && hit.unwrap().point.y > CLIMB_MIN_Y;
            c as u8
        } else {
            e.climbing[i]
        };
        let speed = if climbing != 0 { kd.speed * 0.5 } else { kd.speed };

        let (mut desx, mut desz) = (0.0f32, 0.0f32);
        if let Some((_, dx, dz, _)) = nearest_alive_player(s, x, z) {
            let len = (dx * dx + dz * dz).sqrt();
            if len > 0.0001 {
                desx = dx / len * speed;
                desz = dz / len * speed;
            }
        }
        let (mut sepx, mut sepz) = (0.0f32, 0.0f32);
        grid.for_each_near(x, z, |j| {
            if j == i {
                return;
            }
            let ox = x - e.px[j];
            let oz = z - e.pz[j];
            let d2 = ox * ox + oz * oz;
            let rr = kd.radius + KINDS[e.kind[j] as usize].radius;
            if d2 < rr * rr && d2 > 0.00000001 {
                let inv = 0.5 / d2;
                sepx = sepx + ox * inv;
                sepz = sepz + oz * inv;
            }
        });
        desx = desx + sepx;
        desz = desz + sepz;
        let mut nvx = e.vx[i] * 0.8 + desx * 0.2;
        let mut nvz = e.vz[i] * 0.8 + desz * 0.2;
        let max = speed * 1.5;
        let s2 = nvx * nvx + nvz * nvz;
        if s2 > max * max {
            let k = max / s2.sqrt();
            nvx = nvx * k;
            nvz = nvz * k;
        }
        nv[i] = [nvx, nvz];
        s.enemies.climbing[i] = climbing;
    }
    let e = &mut s.enemies;
    for i in 0..MAX_ENEMIES {
        if e.alive[i] == 0 {
            continue;
        }
        let r = KINDS[e.kind[i] as usize].radius;
        e.vx[i] = nv[i][0];
        e.vz[i] = nv[i][1];
        let mut x = e.px[i] + e.vx[i] * DT;
        let mut z = e.pz[i] + e.vz[i] * DT;
        for k in 0..8 {
            let (cx, cz) = pillar_center(k);
            let dx = x - cx;
            let dz = z - cz;
            let ex = PILLAR_HALF[0] + r;
            let ez = PILLAR_HALF[2] + r;
            let ax = if dx < 0.0 { -dx } else { dx };
            let az = if dz < 0.0 { -dz } else { dz };
            if ax < ex && az < ez {
                if ex - ax < ez - az {
                    x = if dx >= 0.0 { cx + ex } else { cx - ex };
                } else {
                    z = if dz >= 0.0 { cz + ez } else { cz - ez };
                }
            }
        }
        let lim = ARENA - r;
        e.px[i] = clampf(x, -lim, lim);
        e.pz[i] = clampf(z, -lim, lim);
    }
}

#[inline]
fn clampf(v: f32, lo: f32, hi: f32) -> f32 {
    if v < lo {
        lo
    } else if v > hi {
        hi
    } else {
        v
    }
}

// --- combat -------------------------------------------------------------------------------------

/// System 5: contact damage, one hit per enemy per 30-tick cooldown, lowest-index player first.
pub fn contact_damage(s: &mut State, w: &mut World) {
    for i in 0..MAX_ENEMIES {
        if s.enemies.alive[i] == 0 {
            continue;
        }
        if s.enemies.contact_cd[i] > 0 {
            s.enemies.contact_cd[i] -= 1;
            continue;
        }
        let kd = KINDS[s.enemies.kind[i] as usize];
        let (x, z) = (s.enemies.px[i], s.enemies.pz[i]);
        let reach = kd.radius + PLAYER_RADIUS;
        for pl in s.players.iter_mut() {
            if pl.alive == 0 || pl.hp <= 0 {
                continue;
            }
            let dx = pl.pos[0] - x;
            let dz = pl.pos[2] - z;
            if dx * dx + dz * dz < reach * reach {
                pl.hp -= kd.damage;
                s.enemies.contact_cd[i] = CONTACT_COOLDOWN;
                break;
            }
        }
    }
    reap_players(s, w);
}

/// System 6: each alive player with a cold weapon fires at the nearest enemy within 14 m.
pub fn auto_attack(s: &mut State) {
    for p in 0..MAX_PLAYERS {
        let pl = s.players[p];
        if pl.alive == 0 {
            continue;
        }
        if pl.fire_cooldown > 0 {
            s.players[p].fire_cooldown -= 1;
            continue;
        }
        let (px, pz) = (pl.pos[0], pl.pos[2]);
        let mut best = None;
        let mut best_d2 = FIRE_RANGE * FIRE_RANGE;
        let e = &s.enemies;
        for i in 0..MAX_ENEMIES {
            if e.alive[i] == 0 || e.hp[i] <= 0 {
                continue;
            }
            let dx = e.px[i] - px;
            let dz = e.pz[i] - pz;
            let d2 = dx * dx + dz * dz;
            if d2 < best_d2 {
                best_d2 = d2;
                best = Some((dx, dz));
            }
        }
        let Some((dx, dz)) = best else { continue };
        let Some(h) = s.projectiles.alloc() else { continue };
        let len = (dx * dx + dz * dz).sqrt();
        let (vx, vz) = if len > 0.0001 {
            (dx / len * PROJECTILE_SPEED, dz / len * PROJECTILE_SPEED)
        } else {
            (PROJECTILE_SPEED, 0.0)
        };
        let j = h.index as usize;
        let pr = &mut s.projectiles;
        pr.px[j] = px;
        pr.py[j] = pl.pos[1];
        pr.pz[j] = pz;
        pr.vx[j] = vx;
        pr.vz[j] = vz;
        pr.life[j] = PROJECTILE_LIFE;
        pr.damage[j] = PROJECTILE_DAMAGE + pl.damage_bonus as i32;
        pr.owner[j] = p as u8;
        s.players[p].fire_cooldown = pl.fire_interval;
    }
}

/// System 7: move projectiles; enemy hit (first by index) or else a physics ray along the path.
pub fn projectiles(s: &mut State, w: &World, grid: &mut Grid) {
    grid.build(&s.enemies);
    for j in 0..MAX_PROJECTILES {
        if s.projectiles.alive[j] == 0 {
            continue;
        }
        let pr = &mut s.projectiles;
        let (ox, oy, oz) = (pr.px[j], pr.py[j], pr.pz[j]);
        let nx = ox + pr.vx[j] * DT;
        let nz = oz + pr.vz[j] * DT;
        pr.px[j] = nx;
        pr.pz[j] = nz;
        let damage = pr.damage[j];

        let e = &s.enemies;
        let mut hit = usize::MAX;
        grid.for_each_near(nx, nz, |i| {
            if i >= hit || e.hp[i] <= 0 {
                return;
            }
            let dx = e.px[i] - nx;
            let dz = e.pz[i] - nz;
            let rr = KINDS[e.kind[i] as usize].radius + PROJECTILE_RADIUS;
            if dx * dx + dz * dz < rr * rr {
                hit = i;
            }
        });
        if hit != usize::MAX {
            s.enemies.hp[hit] -= damage;
            s.projectiles.release(j);
            continue;
        }
        if let Some(h) = w.cast_ray_closest(v3(ox, oy, oz), v3(nx - ox, 0.0, nz - oz), RAY_MASK) {
            if h.user_id & !0xFFFF_FFFF == UID_BARREL {
                let b = (h.user_id & 0xFFFF_FFFF) as usize;
                s.barrels[b].hp -= damage;
            }
            s.projectiles.release(j);
            continue;
        }
        let pr = &mut s.projectiles;
        pr.life[j] -= 1;
        if pr.life[j] == 0 {
            pr.release(j);
        }
    }
}

// --- barrels ------------------------------------------------------------------------------------

/// System 8: barrels at HP <= 0 explode in barrel order; destroyed barrels respawn after 600 ticks.
pub fn barrels(s: &mut State, w: &mut World) {
    for b in 0..N_BARRELS {
        let br = s.barrels[b];
        if br.body.live == 0 {
            let left = br.respawn.saturating_sub(1);
            s.barrels[b].respawn = left;
            if left == 0 {
                let item = br.item as usize;
                s.barrels[b].body = create_barrel(w, item, b);
                s.barrels[b].hp = BARREL_HP;
                s.items[item] = s.barrels[b].body;
            }
            continue;
        }
        if br.hp > 0 {
            continue;
        }
        let c = w.position(key(br.body));
        explode(s, w, b, c.x, c.z);
        w.destroy_body(key(br.body));
        s.barrels[b].body = BodyRef::default();
        s.barrels[b].respawn = BARREL_RESPAWN;
        s.items[br.item as usize] = BodyRef::default();
    }
    reap_players(s, w);
}

/// Unit horizontal direction plus 0.5 up, normalized.
fn blast_dir(dx: f32, dz: f32) -> (f32, f32, f32) {
    let hl = (dx * dx + dz * dz).sqrt();
    let (hx, hz) = if hl > 0.0001 { (dx / hl, dz / hl) } else { (0.0, 0.0) };
    let hy = 0.5f32;
    let l = (hx * hx + hy * hy + hz * hz).sqrt();
    (hx / l, hy / l, hz / l)
}

fn explode(s: &mut State, w: &mut World, barrel: usize, cx: f32, cz: f32) {
    let r2 = EXPLOSION_RADIUS * EXPLOSION_RADIUS;
    let push = |w: &mut World, body: BodyRef, x: f32, z: f32| {
        let dx = x - cx;
        let dz = z - cz;
        let d2 = dx * dx + dz * dz;
        if d2 < r2 {
            let d = d2.sqrt();
            let (ux, uy, uz) = blast_dir(dx, dz);
            let m = EXPLOSION_IMPULSE * (1.0 - d / EXPLOSION_RADIUS);
            w.apply_impulse_to_center(key(body), v3(ux * m, uy * m, uz * m));
        }
    };
    // Dynamic bodies in entity order: crates and barrels in item order, then players.
    let own_item = s.barrels[barrel].item as usize;
    for i in 0..N_ITEMS {
        let body = s.items[i];
        if body.live == 0 || i == own_item {
            continue;
        }
        let p = w.position(key(body));
        push(w, body, p.x, p.z);
    }
    for pl in s.players.iter() {
        if pl.alive != 0 {
            push(w, pl.body, pl.pos[0], pl.pos[2]);
        }
    }
    let e = &mut s.enemies;
    for i in 0..MAX_ENEMIES {
        if e.alive[i] == 0 {
            continue;
        }
        let dx = e.px[i] - cx;
        let dz = e.pz[i] - cz;
        if dx * dx + dz * dz < r2 {
            e.hp[i] -= EXPLOSION_ENEMY_DAMAGE;
        }
    }
    let pr2 = EXPLOSION_PLAYER_RADIUS * EXPLOSION_PLAYER_RADIUS;
    for pl in s.players.iter_mut() {
        if pl.alive == 0 {
            continue;
        }
        let dx = pl.pos[0] - cx;
        let dz = pl.pos[2] - cz;
        if dx * dx + dz * dz < pr2 {
            pl.hp -= EXPLOSION_PLAYER_DAMAGE;
        }
    }
}

// --- deaths and XP ------------------------------------------------------------------------------

fn add_xp(pl: &mut Player, amount: u32) {
    pl.xp += amount;
    loop {
        let threshold = 10 + pl.level * 5;
        if pl.xp < threshold {
            break;
        }
        pl.xp -= threshold;
        pl.level += 1;
        pl.pending_levelups += 1;
    }
}

/// System 9: dead enemies drop gems (free list, stable indices); gems near players are collected.
pub fn deaths_and_xp(s: &mut State) {
    for i in 0..MAX_ENEMIES {
        if s.enemies.alive[i] == 0 || s.enemies.hp[i] > 0 {
            continue;
        }
        let (x, z) = (s.enemies.px[i], s.enemies.pz[i]);
        let xp = KINDS[s.enemies.kind[i] as usize].xp;
        s.enemies.release(i);
        if let Some(h) = s.gems.alloc() {
            let g = h.index as usize;
            s.gems.px[g] = x;
            s.gems.pz[g] = z;
            s.gems.value[g] = xp;
        } else if let Some((p, ..)) = nearest_alive_player(s, x, z) {
            add_xp(&mut s.players[p], xp as u32);
        }
    }
    let r2 = GEM_PICKUP * GEM_PICKUP;
    for g in 0..MAX_GEMS {
        if s.gems.alive[g] == 0 {
            continue;
        }
        let (x, z) = (s.gems.px[g], s.gems.pz[g]);
        for p in 0..MAX_PLAYERS {
            let pl = &s.players[p];
            if pl.alive == 0 {
                continue;
            }
            let dx = pl.pos[0] - x;
            let dz = pl.pos[2] - z;
            if dx * dx + dz * dz < r2 {
                let v = s.gems.value[g] as u32;
                add_xp(&mut s.players[p], v);
                s.gems.release(g);
                break;
            }
        }
    }
}

/// System 11: read back player positions for the next tick.
pub fn read_back(s: &mut State, w: &World) {
    for pl in s.players.iter_mut() {
        if pl.alive != 0 {
            let p = w.position(key(pl.body));
            pl.pos = [p.x, p.y, p.z];
        }
    }
}

/// `bench`: fill the arena with `n` enemies at pseudo-random positions (bench only).
pub fn prespawn(s: &mut State, n: u32) {
    for _ in 0..n {
        if s.enemies.count >= s.enemy_limit {
            break;
        }
        let x = (xorshift32(&mut s.rng) % 5600) as f32 / 100.0 - 28.0;
        let z = (xorshift32(&mut s.rng) % 5600) as f32 / 100.0 - 28.0;
        let kind = kind_from_roll(xorshift32(&mut s.rng) % 10);
        spawn_enemy(s, x, z, kind);
    }
}
