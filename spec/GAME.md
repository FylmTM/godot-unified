# Survivor: the test game for the core

A small top-down co-op survivor game that exercises everything the core must handle: 1–4 players, waves of up to
**1200 enemies**, projectiles, Box3D rigid bodies (crates, barrels), explosions, pickups, a level-up choice, death and
respawn, joining and leaving, a lobby and match resets. Code: `games/survivor/simulation/survivor/`. Units: metres,
seconds; the tick rate is **64 Hz** (`DT = 1/64` exactly) and every time constant is written in seconds and
converted to whole ticks at compile time. The plane is XZ, Y is up.

M2 changes (decided autonomously 2026-11-09, pending developer review): 64 Hz and seconds, `rng_below` instead of
`% n`, presence from the relay, phases with a start circle, events, the HUD view.

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
  created when the slot becomes present, at their start spot `(±1.5, 1, ±1.5)` in order (+,+) (−,+) (+,−) (−,−),
  inside the start circle.

## Input (per player per tick)

- `move_x, move_z`: i8 in −127..127. The movement direction is `(move_x, move_z) / 127` (not normalized; the
  scripted inputs only produce lengths ≤ 1).
- `buttons`: bit 0 = dash (edge-triggered).
- Presence is not in the input: the tick's `present` set (from the relay) says who is in the game. A slot that becomes
  present joins (body at its start spot, fresh progress, `player_joined`); one that stops being present leaves (body
  destroyed, progress reset, `player_left`).
- `choice`: 0 = none, 1..3 = the level-up option picked (consumed when a level-up is pending).

## Phases

`phase` (in the state, with `match_tick`, `over_tick`, `wave`, `matches`, `circle_radius`):

- **lobby** (tick 0, and after every reset): no spawner, no enemies; `circle_radius = 3.5` (the start circle at the
  arena centre). The match starts on the tick (after the physics step) where any alive present player's centre is
  more than 3.5 m from the centre in XZ: `phase = match`, `match_tick = t`, `matches += 1`, `match_started`.
- **match**: waves as below, `wave = (t − match_tick) / WAVE_TICKS`. When every present player is dead at the same
  time: `phase = over`, `over_tick = t`, `match_over` (value = seconds survived). When nobody is present: reset.
- **over**: dead players don't count down their respawn; after `OVER_HOLD_S = 5` s the world resets: every dynamic
  body is destroyed, then items (in index order) and present players (at their start spots, fresh progress,
  `player_respawned`) are recreated; enemies, projectiles and gems are cleared; `phase = lobby`.

## Constants (seconds)

Respawn 3 s; barrel respawn 10 s; dash 0.125 s, cooldown 1.5 s; contact cooldown 0.5 s; fire interval 0.3125 s
(level-up −0.03125 s, min 0.09375 s); spawn every 0.3125 s; wave 10 s; projectile life 1 s; climb check every
0.125 s; over hold 5 s; start circle 3.5 m. Speeds are per second (`·DT` per tick).

## Systems (run in this order every tick)

1. **Players:**
   - Velocity = `dir · 6.0` (m/s, y kept from physics).
   - Dash: on the press edge, if the dash cooldown is 0, multiply velocity by 3 for 0.125 s; cooldown 1.5 s.
   - Set the body's linear velocity.
   - Dead players have no body and count down `respawn` = 3 s (not while `over`), then respawn at their start spot
     with full HP (`player_respawned`). HP max 100.
2. **Level-up:** if the player has `pending_levelups > 0` and `choice ∈ 1..3`, apply option
   1 = fire rate (interval −0.03125 s, min 0.09375 s), 2 = damage +3, 3 = move speed +0.5, then `pending_levelups −= 1`.
3. **Spawner** (match only): every 0.3125 s after `match_tick`, spawn `n = min(4 + wave·3, 40)` enemies while
   alive enemies < 1200.
   - Spawn position: on the ring of radius 27, using the angle table above with
     `k = rng_below(8)`, `jitter = rng_below(1000) / 1000 · 2 − 1` added to x and z.
   - Enemy kinds by `rng_below(10)`:
     - 0..6 → grunt: HP 10, speed 2.0, radius 0.4, contact damage 5
     - 7..8 → runner: HP 6, speed 3.2, radius 0.35, damage 3
     - 9 → brute: HP 40, speed 1.2, radius 0.7, damage 12
   - The RNG is the state block's `sim.Rng` (xorshift32, seeded from the session seed); `rng_below` is unbiased.
4. **Enemies** (kinematic, no physics bodies; same spatial-grid approach as the archived benchmark A: cell 2 m over the 60×60 arena,
   counting sort, items in index order):
   - Target = the nearest alive player (lowest index on ties).
   - Desired = `normalize(target − pos) · speed`, then add separation from neighbours in the 3×3 cells within
     `r_i + r_j`: `push · 0.5 / d2` per neighbour.
   - Blend `v = v·0.8 + desired·0.2`, clamp the speed to `speed·1.5`, then `pos += v·DT`.
   - Then push the enemy out of pillars: if its centre is inside a pillar's half extents + r, move it out along the
     smaller-penetration axis. Clamp to the arena `±(30 − r)`.
   - Phase 1 computes all velocities from old positions; phase 2 integrates (Jacobi).
   - Every 0.125 s per enemy (`(i + t) % 8 == 0`), cast a ray down from y = 3 at the enemy (`b3World_CastRayClosest`).
     If it hits a dynamic crate or barrel top above y 0.8, the enemy is "climbing" and its speed is halved until the
     next cast.
5. **Contact damage:** an enemy within `r + 0.45` of an alive player deals its damage if that enemy's own contact
   cooldown is 0, then sets the cooldown to 0.5 s. A player at HP ≤ 0 dies: body destroyed, respawn timer set.
6. **Auto-attack:** each alive player with `fire_cooldown == 0` fires at the nearest enemy within 14 m (lowest index
   on ties).
   - The projectile spawns at the player's position with velocity `normalize(enemy − player) · 16` and lives 1 s.
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
   - `barrel_exploded` (entity = item index + 1).
   - 10 s later a new barrel spawns at its original grid spot, which is physics churn inside rollback windows.
9. **Deaths and XP:**
   - An enemy at HP ≤ 0 is removed (swap-remove is **not** allowed, because it reorders; use a free list with stable
     indices) and drops a gem worth grunt 1 / runner 1 / brute 5 XP.
   - Max 1024 gems; if full, the XP goes straight to the nearest player.
   - Gems within 1.5 m of an alive player are collected by the lowest-index such player.
   - Level threshold `10 + level·5`. Reaching it increments `level` and `pending_levelups` (`level_up`, value = the new
     level). Enemy deaths emit `enemy_died`, collected gems `gem_collected`.
10. **Physics step:** `b3World_Step(DT, 4)`.
12. **Phases** (above), after the read-back.
11. Read back player and barrel positions as needed by the next tick.

## Events (for the view)

`player_died`, `player_respawned`, `enemy_died`, `barrel_exploded`, `gem_collected`, `level_up`, `match_started`,
`match_over`, `player_joined`, `player_left` (`EVENT_NAMES`, indexed by `Event_Kind`). Player events carry `slot`
and entity = slot; item events entity = item index + 1; enemy and gem events the table handle key. Enemies keep
`spawn_tick` and `hit_tick`, gems `spawn_tick`, for view effects.

## HUD

`survivor.hud(state, tick) -> Hud`: phase and its name, tick, match time (s), wave (1-based in a match), enemies
alive, circle radius, matches, and per slot: present, alive, hp, hp_max, xp, xp_next, level, pending level-ups,
respawn seconds. The Godot host adds `local_slot` and player names (from the netcode roster).

## Scripted inputs (for `sim`, `synctest`, `session`, tests)

Deterministic per player and stateless: `r` = a 64-bit integer hash of (seed, player, 24-tick block), so any tick can
be asked for in any order:
- `move` = one of 8 directions from the angle table times 127 (as i8, truncated), or (0,0) when `r % 9 == 8`
- dash when `r % 13 == 0`
- `choice = (r % 3) + 1` when a level-up is pending, else 0

Offline modes make slots `< players` present from tick 1. In `session` mode each client generates its own player's
inputs this way and sends them through the netcode. T4 compares against the relay's log, not against `sim`.

## Expected scale

Scripted players leave the circle within a second; within 3600 ticks there are matches with a few hundred enemies,
game overs and resets. `bench --enemies 1000` pre-spawns to 1000 and holds there (the match never ends in bench) to
measure the rollback cost. `tests/survivor` adds a scenario that forces barrel explosions, deaths, respawns and
resets every few ticks, checked by sync-test and by a networked session under the `bad` profile.
