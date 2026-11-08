# Survivor-lite: the headless test game for the core

A small top-down co-op survivor game that exercises everything the core must handle: 1–4 players, waves of up to
**1200 enemies**, projectiles, Box3D rigid bodies (crates, barrels), explosions, pickups, a level-up choice, death and
respawn. No rendering. Units: metres, ticks (60 Hz). The plane is XZ, Y is up.

Implementations follow this behaviour faithfully but write it idiomatically. Constants are exact; rule order is
exact where it says so (it affects results). Formulas use only `+ − × ÷ sqrt` on f32. Anything not specified (e.g.
how a table is laid out) is up to the implementation, as long as it's deterministic.

## World (created before tick 0, in this order)

- Ground: a static box, half extents (32, 0.5, 32) at (0, −0.5, 0). Walls: four static boxes enclosing the 60×60 arena
  (inner faces at x = ±30, z = ±30, height 3, thickness 1).
- 8 static pillars: boxes half (1, 1.5, 1) at angles k·45° on a ring of radius 14: `(14·c_k, 1.5, 14·s_k)`. Use this
  table, not trig: `c = [1, 0.70710677, 0, −0.70710677, −1, −0.70710677, 0, 0.70710677]`, `s = [0, 0.70710677, 1,
  0.70710677, 0, −0.70710677, −1, −0.70710677]`.
- 32 crates (dynamic boxes, half 0.5, density 1) and 8 barrels (dynamic capsules r 0.4, center1 (0,−0.3,0),
  center2 (0,0.3,0), density 1), on a 5×8 grid. Item `i = 0..39`: `x = (i % 8)·4 − 14`, `z = (i / 8)·4 − 8`, y = 1.
  Barrels are the items where `i % 5 == 2`; the rest are crates. Barrels have 30 HP.
- Players `p = 0..3`: dynamic capsules (r 0.45, center1 (0,−0.45,0), center2 (0,0.45,0)), rotation locked, sleep off,
  at `(±4, 1, ±4)` in order (+,+) (−,+) (+,−) (−,−). Only `players` (CLI) slots are active at start; the rest are
  absent (no body) until they join.

## Input (per player per tick)

- `move_x, move_z`: i8 in −127..127. The movement direction is `(move_x, move_z) / 127` (not normalized; the
  scripted inputs only produce lengths ≤ 1).
- `buttons`: bit 0 = dash (edge-triggered), bit 7 = absent.
- `choice`: 0 = none, 1..3 = the level-up option picked (consumed when a level-up is pending).

## Systems (run in this order every tick)

1. **Players:**
   - Velocity = `dir · 6.0` (m/s, y kept from physics).
   - Dash: on the press edge, if the dash cooldown is 0, multiply velocity by 3 for 8 ticks; cooldown 90 ticks.
   - Set the body's linear velocity.
   - Dead players have no body and count down `respawn = 180` ticks, then respawn at their start position with full
     HP. HP max 100.
2. **Level-up:** if the player has `pending_levelups > 0` and `choice ∈ 1..3`, apply option
   1 = fire rate (`fire_interval −= 2`, min 6), 2 = damage +3, 3 = move speed +0.5, then `pending_levelups −= 1`.
3. **Spawner:** waves. At tick `t`, `wave = t / 600`, and spawn `n = min(4 + wave·3, 40)` enemies every 20 ticks while
   alive enemies < 1200.
   - Spawn position: on the ring of radius 27, using the angle table above with
     `k = rng() % 8`, `jitter = (rng() % 1000) / 1000 · 2 − 1` added to x and z.
   - Enemy kinds by `rng() % 10`:
     - 0..6 → grunt: HP 10, speed 2.0, radius 0.4, contact damage 5
     - 7..8 → runner: HP 6, speed 3.2, radius 0.35, damage 3
     - 9 → brute: HP 40, speed 1.2, radius 0.7, damage 12
   - `rng` is the state block's xorshift32 (seed from the CLI; 0 → 1).
4. **Enemies** (kinematic, no physics bodies; same spatial-grid approach as the archived benchmark A: cell 2 m over the 60×60 arena,
   counting sort, items in index order):
   - Target = the nearest alive player (lowest index on ties).
   - Desired = `normalize(target − pos) · speed`, then add separation from neighbours in the 3×3 cells within
     `r_i + r_j`: `push · 0.5 / d2` per neighbour.
   - Blend `v = v·0.8 + desired·0.2`, clamp the speed to `speed·1.5`, then `pos += v·DT`.
   - Then push the enemy out of pillars: if its centre is inside a pillar's half extents + r, move it out along the
     smaller-penetration axis. Clamp to the arena `±(30 − r)`.
   - Phase 1 computes all velocities from old positions; phase 2 integrates (Jacobi).
   - Every 8 ticks per enemy (`(i + t) % 8 == 0`), cast a ray down from y = 3 at the enemy (`b3World_CastRayClosest`).
     If it hits a dynamic crate or barrel top above y 0.8, the enemy is "climbing" and its speed is halved until the
     next cast.
5. **Contact damage:** an enemy within `r + 0.45` of an alive player deals its damage if that enemy's own contact
   cooldown is 0, then sets the cooldown to 30. A player at HP ≤ 0 dies: body destroyed, respawn timer set.
6. **Auto-attack:** each alive player with `fire_cooldown == 0` fires at the nearest enemy within 14 m (lowest index
   on ties).
   - The projectile spawns at the player's position with velocity `normalize(enemy − player) · 16` and lives 60 ticks.
   - `fire_cooldown = fire_interval` (initially 20).
   - Max 512 projectiles (if full, don't fire).
7. **Projectiles** (kinematic): `pos += vel·DT`.
   - Hit test against enemies in the 3×3 grid cells (distance < r + 0.15): first by index wins. Damage = 5 + bonus;
     the projectile dies.
   - Else ray-cast its path segment against physics (`b3World_CastRayClosest` from old to new pos), **ignoring player
     bodies** (Box3D reports a hit for a ray that starts inside a shape, which would kill projectiles on their own
     shooter): if it hits a barrel, the barrel takes the damage; if it hits anything else, the projectile dies.
   - Lifetime 0 → dies.
8. **Barrels and explosions:** a barrel at HP ≤ 0 explodes at its position, in barrel order:
   - For every dynamic body within 5 m (crates, barrels, players): impulse `dir · 12 · (1 − d/5)` applied at its centre
     (`dir` = normalized horizontal + 0.5 up, then normalized).
   - Every enemy within 5 m takes 25 damage.
   - Every player within 3 m takes 15.
   - The barrel's body is destroyed.
   - 600 ticks later a new barrel spawns at its original grid spot, which is physics churn inside rollback windows.
9. **Deaths and XP:**
   - An enemy at HP ≤ 0 is removed (swap-remove is **not** allowed, because it reorders; use a free list with stable
     indices) and drops a gem worth grunt 1 / runner 1 / brute 5 XP.
   - Max 1024 gems; if full, the XP goes straight to the nearest player.
   - Gems within 1.5 m of an alive player are collected by the lowest-index such player.
   - Level threshold `10 + level·5`. Reaching it increments `level` and `pending_levelups`.
10. **Physics step:** `b3World_Step(DT, 4)`.
11. Read back player and barrel positions as needed by the next tick.

## Scripted inputs (for `sim`, `synctest`, `session`, tests)

Deterministic per player, from a per-player xorshift32 seeded `seed·7919 + p + 1`, re-drawn every 24 ticks:
- `move` = one of 8 directions from the angle table times 127 (as i8, truncated), or (0,0) when `r % 9 == 8`
- dash when `r % 13 == 0`
- `choice = (r % 3) + 1` when a level-up is pending, else 0

In `session` mode each client generates its own player's inputs this way and sends them through the netcode. So the
recorded official log equals what `sim` would do only when nothing was replaced by the relay; that's fine, T4 compares
against the log, not against `sim`.

## Expected scale

By tick 3600 (wave 6) there are several hundred enemies alive; `bench --enemies 1000` pre-spawns to 1000 and holds
there (the spawner stops at 1200) to measure the rollback cost.
