# Survivor: the test game for the core

Status: draft, pending #12.

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
- 8 static pillars: boxes half (1, 1.5, 1) at angles k·45° on a ring of radius 14: `(14·c_k, 1.5, 14·s_k)`, `{c_k, s_k}` the k-th
  of `dmath.DIR8` (exact table values, not trig).
- 32 crates (dynamic boxes, half 0.5, density 1) and 8 barrels (dynamic capsules r 0.4, center1 (0,−0.3,0),
  center2 (0,0.3,0), density 1), on a 5×8 grid. Item `i = 0..39`: `x = (i % 8)·4 − 14`, `z = (i / 8)·4 − 8`, y = 1,
  except the two spots inside the start circle: crate 19 at (−2, 12) and crate 20 at (2, −12).
  Barrels are the items where `i % 5 == 2`; the rest are crates. Barrels have 30 HP.
- Players: dynamic capsules (r 0.45, center1 (0,−0.45,0), center2 (0,0.45,0)), rotation locked, sleep off,
  created when the player becomes present, at the start spot of their slot `s = 0..3`, `(±1.5, 1, ±1.5)` in order
  (+,+) (−,+) (+,−) (−,−), inside the start circle.

## Input (per player per tick)

- `move_x, move_z`: i8 in −127..127, a stick (`dmath.stick`: each axis −1..1, the length at most 1).
- `buttons: bit_set[Button]`: `Dash` (on the press: `sim.buttons`).
- Presence is not in the input: players are session members (`src/sim/SPEC.md`, Players), held in the state's
  `players: sim.Players(Character, Input, PLAYERS)` (2 · PLAYERS remembered); the library applies joins and leaves before the tick and
  emits `player_joined` / `player_left`. The game's part (system 1): a player who leaves loses their body (an absent
  player owns nothing outside the block) and keeps their progress (level, XP, upgrades, pending level-ups); someone
  new starts fresh; both new and returning players get a body at their slot's start spot with full HP. Everything
  per player is by player, not slot: a player who comes back in another slot is the same player.
- The level-up pick is a command (`src/sim/SPEC.md`, Commands), not input: `Cmd_Pick {upgrade: Upgrade}`, the only
  variant of `Command` (name `"pick"`; `Upgrade` = Fire_Rate, Damage, Move_Speed, the HUD's card order), delivered
  once. The HUD sends it from GDScript on a key (`levelup_1..3`), pad button or click: a `CommandPick` object whose
  `upgrade` is the card's (`Unified.constants.upgrades[i].upgrade`, an `EnumUpgrade` value),
  `Game.send_command(pick)`.

## Phases

`phase` (in the state, with `match_tick`, `over_tick`, `wave`, `matches`, `circle_radius`):

- **lobby** (tick 0, and after every reset): no spawner, no enemies; `circle_radius = 3.5` (the start circle at the
  arena centre). The match starts on the tick (after the physics step) where any alive present player's centre is
  more than 3.5 m from the centre in XZ: `phase = match`, `match_tick = t`, `matches += 1`, `match_started`.
- **match**: waves as below, `wave = (t − match_tick) / wave` (Tuning). When every present player is dead at the same
  time: `phase = over`, `over_tick = t`, `match_over` (value = seconds survived). When nobody is present: reset.
- **over**: dead players don't count down their respawn; after `OVER_HOLD_S = 5` s the world resets: every dynamic
  body is destroyed, every known player's progress starts fresh (absent ones too), then items (in index order) and
  present players (in slot order, at their slots' start spots, `player_respawned`) are recreated; enemies,
  projectiles and gems are cleared; `phase = lobby`.

## Constants (seconds)

Respawn 3 s; barrel respawn 10 s; dash 0.125 s, cooldown 1.5 s; contact cooldown 0.5 s; fire interval 0.3125 s
(level-up −0.03125 s, min 0.09375 s); projectile life 1 s; climb check every
0.125 s; over hold 5 s; start circle 3.5 m. Speeds are per second (`·DT` per tick).

## Tuning (`state.tune`, preset `state.tuning` from the read-only `TUNINGS`)

`init` copies the preset into the state, so a match's tuning is state: shared by every peer, in the checksum and in
snapshots. `survivor bot --set field=value` overrides it in the tick-0 state.

The pace of a match: a spawn burst every `every`, of `n = min(base + per_wave·wave, cap) · (100 + extra·(present − 1))
/ 100` enemies; waves last `wave`; enemy HP is scaled by `(100 + hp·wave) / 100`; XP for the next level is
`xp_first + (level − 1)·xp_step` (levels start at 1).

| | every | base | per_wave | cap | extra | wave | hp | xp_first | xp_step |
|---|---|---|---|---|---|---|---|---|---|
| `play` (the game, `GAME`) | 2 s | 2 | 1 | 20 | 50% | 30 s | 10% | 8 | 4 |
| `stress` (`GAME_STRESS`: headless modes, the end-to-end suite, bench) | 0.3125 s | 4 | 3 | 40 | 0% | 10 s | 0% | 10 | 5 |

`play` was tuned with `survivor bot --players N --seeds 16` (the bot policy in `bot.odin`: orbit the arena, flee the
nearest enemies, collect gems, dash out of contact, level-ups round-robin). Medians (min-max) over 16 seeds:

| players | first level-up | survival (match over) |
|---|---|---|
| 1 | 28 s (17-40) | 273 s (110-361) |
| 2 | 25 s (18-34) | 240 s (167-369) |
| 3 | 21 s (13-39) | 317 s (244-539) |
| 4 | 26 s (12-41) | 354 s (207-600+) |

The same bot under `stress` dies at 16-30 s, half the time before its first level-up. The windowed bot of `uni tool
survivor play_check --window` (circle-strafe, no gem seeking) reached wave 5 and lasted 128 s. `simulation/tests`
guards the targets over 8 seeds (each first level-up in 10-45 s; on average survival > 120 s and wave ≥ 3.5).

## Systems (run in this order every tick)

1. **Players** (present players in slot order):
   - Leaves (body destroyed), then joins and returns (a body at the slot's start spot, full HP; a new player's
     progress is fresh, a returning player's is kept).
   - Velocity = `dir · 6.0` (m/s, y kept from physics).
   - Dash: on the press edge, if the dash cooldown is 0, multiply velocity by 3 for 0.125 s; cooldown 1.5 s.
   - Set the body's linear velocity.
   - Dead players have no body and count down `respawn` = 3 s (not while `over`), then respawn at their slot's
     start spot with full HP (`player_respawned`). HP max 100.
2. **Level-up:** each of the player's picks this tick, in order (see Input): if `pending_levelups > 0`, apply fire
   rate (interval −0.03125 s, min 0.09375 s), damage +3 or move speed +0.5, then `pending_levelups −= 1`; else (or a
   value that is no Upgrade) ignore it.
3. **Spawner** (match only): every `every` after `match_tick`, spawn `n` enemies (Tuning) while alive enemies
   < 1200; their HP is scaled by the wave.
   - Spawn position: on the ring of radius 27, using the angle table above with
     `k = rng_below(8)`, `jitter = rng_below(1000) / 1000 · 2 − 1` added to x and z.
   - Enemy kinds by `rng_below(10)`:
     - 0..6 → grunt: HP 10, speed 2.0, radius 0.4, contact damage 5
     - 7..8 → runner: HP 6, speed 3.2, radius 0.35, damage 3
     - 9 → brute: HP 40, speed 1.2, radius 0.7, damage 12
   - The RNG is the state block's `sim.Rng` stream (SplitMix64, seeded from the session seed); `rng_below` is
     unbiased. A wave is drawn in sequence, so it stays on the stream; the game has no per-entity rolls.
4. **Enemies** (kinematic, no physics bodies; same spatial-grid approach as the archived benchmark A: cell 2 m over the 60×60 arena,
   counting sort, items in index order):
   - Target = the nearest alive player (lowest slot on ties).
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
   - Gems within 1.5 m of an alive player are collected by the lowest-slot such player.
   - Level threshold `xp_first + (level − 1)·xp_step` (Tuning; level starts at 1). Reaching it increments `level`
     and `pending_levelups` (`level_up`). Enemy deaths emit `enemy_died`, collected gems `gem_collected`.
10. **Physics step:** `b3World_Step(DT, 4)`.
12. **Phases** (above), after the read-back.
11. Read back player and barrel positions as needed by the next tick.

## Events (for the view)

One struct per event, in the `Event` union (`src/sim/SPEC.md`, Events; the name is the type name lowercased).
`position` is a `sim.Position` in metres: the body's centre for players and barrels, the ground (y = 0) for enemies
and gems. `player` is a `sim.Player` (GDScript: the player's key).

| Event | Fields |
|---|---|
| `player_joined`, `player_left` (the library's) | `player`, `slot`, `returning` (joined) |
| `player_died`, `player_respawned` | `position`, `player` |
| `match_started` | `position`, `player` (who left the start circle) |
| `match_over` | `duration_s` (the match's length) |
| `level_up` | `position`, `level` (the new level), `player` |
| `enemy_died` | `enemy: Handle(Enemy)`, `position`, `enemy_kind: Enemy_Kind` |
| `gem_collected` | `gem: Handle(Gem)`, `position`, `xp`, `player` (who collected it) |
| `barrel_exploded` | `entity` (the item's view key: item index + 1), `position` |

Enemies keep `spawn_tick` and `hit_tick`, gems `spawn_tick`, for view effects.

## HUD

View code in the extension (`extension/hud.odin`, `hud_of(state, tick) -> Data_Hud`), not in the sim package: the
session data `Data_Hud` (`Unified.data.hud`), pushed every frame: phase, tick, match time (s), wave (1-based in a match),
enemies alive, circle radius, matches, and per slot (`player`: who holds it, a `sim.Player`, GDScript's key; 0 and
not present for an empty slot): present, alive, hp, hp_max, xp, xp_next, level, pending level-ups, respawn seconds.
Player names and the local player come from the session, not the HUD.

## Scripted inputs (for `sim`, `synctest`, `session`, tests)

Deterministic per slot and stateless: `r` = a 64-bit integer hash of (seed, slot, 24-tick block), so any tick can
be asked for in any order:
- `move` = one of 8 directions from the angle table times 127 (as i8, truncated), or (0,0) when `r % 9 == 8`
- dash when `r % 13 == 0`
- commands (`scripted_commands`): a pick of upgrade `r % 3` on the first tick of every block, pending or not (the sim
  ignores it then), so the script depends on (seed, slot, tick) only

Offline modes make slots `< players` present from tick 1 (slot i is member i + 1). In `session` mode each client generates its own player's
inputs this way and sends them through the netcode. A session's check replays the relay's log, not
against `sim`. Barrels sit off the scripted firing lines, so they rarely explode in scripted runs; physics churn
inside rollback windows comes from deaths and respawns instead (and from the forced-explosion scenario below).

## Expected scale

The headless modes run `stress`: scripted players leave the circle within a second; within 3600 ticks there are matches with a few hundred enemies,
game overs and resets. `bench --entities 1000` pre-spawns to 1000 and holds there (the match never ends in bench) to
measure the rollback cost. `simulation/tests` adds a scenario that forces barrel explosions, deaths, respawns and
resets every few ticks, checked by sync-test and by a networked session under the `bad` profile.

## Client (Godot content)

Decided autonomously 2026-11-09, pending developer review.

The Godot side of `games/survivor/`: everything except `simulation/`. Hand-written `.tscn`/`.gd`, no editor needed.

### Layout

```
project.godot          Forward+, 1280x720, canvas_items stretch, InputMap, autoloads, audio buses
export_presets.cfg     "macOS" (universal, thinned by `uni release`) and "Windows Desktop"; library from .out/bin/;
                       the tool scripts are excluded
unified_index.tres     the view index (`uni bake survivor`): each scene view kind's scene
addons/shared/         games/shared, mirrored by uni (git-ignored): flow, settings, menus, HUD panels, tools
addons/unified/        src/godot/tools, mirrored by uni (git-ignored): UnifiedTool, UnifiedValidate, the level exporter
game/survivor.gdextension   entry unified_init, res://.out/bin/libsurvivor.dylib | survivor.dll | libsurvivor.so
game/autoload/         the shared Settings (+ render scale, best time) and Sfx (+ survivor's sounds); Game is the
                       shared one
game/ui/               the HUD; the menu scene (the arena with props behind the shared menu)
game/arena/            level (floor, walls, pillars, lights), start circle, arena (views root, MultiMesh views,
                       camera), follow camera
game/views/            the scene views: player, crate, barrel; multi_view.gd (the MultiMesh views' script)
game/fx/, game/shaders/  event effects; floor, start circle, multi views (toon + hit flash), gem shaders
game/tools/            survivor's own tool steps (validate, ui_walk, coop extend the shared ones), tour, play_check
```

### Flow

The flow is the shared one (`games/shared/SPEC.md`), on the game library's `UnifiedSession` (without the library the
shared LibraryCheck autoload shows "game library failed to load" with Quit). The sim's own phases (lobby → match →
over → lobby) are read from the HUD's session data (`Unified.data.hud.phase`, an `EnumPhase` value); the arena never
reloads between matches.

### View contract (`src/godot/SPEC.md`; `simulation/extension`)

- `view_root`: the arena's `Views` node, set on load, cleared on exit; scene views spawn under it.
- Scene views (`View`): `player`, `crate`, `barrel`, each a scene with a `UnifiedView` marker as the **first**
  child of its root (`kind` = the member lowercased, `unique_name_in_owner`), found through the view index. The
  roots are Node3Ds; the player view reads `player` from its marker. Keys (unique within a kind): a player's
  `sim.player_key` (`player` set; the view lives while the player is present, dead too, and its colour is its
  slot's), an item's index (`entity` = index + 1, `barrel_exploded`'s; a destroyed barrel's view goes, the respawned
  one is new). Each frame the host sets `position` (the body centre; crates and barrels also their physics rotation,
  which player views reset) and calls `_sim_update(position, yaw, alpha)`; `_sim_despawned()` plays the exit
  animation during the linger (the host no longer moves the view) and `_sim_revived()` undoes it.
- View data: the player view's `hp` (`Player_View`; a drop flashes it).
- Session data: `Data_Hud` (HUD above) as `Unified.data.hud`: `phase` an `EnumPhase` value (`EnumPhase.LOBBY`, `MATCH`,
  `OVER`), `players` an Array of Dictionaries. The HUD reads it every frame.
- MultiMesh views (`MultiView`): five `MultiMeshInstance3D`s under the arena's `MultiViews` node, each with a
  `UnifiedMultiView` marker: `grunt`, `runner`, `brute` (Enemy_Kind's order), `projectile`, `gem`; keyed by handle.
  3D transforms (enemies and projectiles face their velocity) + custom data (r = hit flash 0..1, g = age in s), no
  colours; positions on the floor plane (y = 0), the shaders lift the meshes. The host sizes the MultiMeshes.
- Events: the classes `EventPlayerDied`, `EventEnemyDied`, ... (Events above) on `session.sim_event(event, state)`;
  positions as Vector3 in metres, `EventEnemyDied.enemy_kind` an `EnumEnemyKind` value. The host routes a player's
  events to its player view and `barrel_exploded` to its barrel's view; the arena's effects and the HUD's banners
  play on `UnifiedSession.EVENT_CONFIRMED` only.
- Constants: `Data_Constants` (the extension's `CONSTANTS`, its item grid and card details filled from the sim at
  load) as `Unified.constants`: `over_hold_s`, `arena_half`, `start_radius`, `upgrades` ([{upgrade, name, detail}]
  ×3 in Upgrade order, the level-up cards; `upgrade` is the Pick's, an `EnumUpgrade` value) and `items`
  ([{position, kind}] ×40, spawn body centres, `kind` an `EnumItemKind` value; the menu backdrop uses them); the tick
  rate is `Unified.tick_hz`. GDScript never copies a sim number (the effects' 5 m blast radius aside).
- Input: `sample_input` reads the InputMap (`move_*`, `dash`, held or pressed since the last tick); GDScript only
  handles `menu` (Esc) and the level-up keys, which send a `CommandPick`.
- Player names and the local player come from the session (`Game.player_name`, `Game.local_player`);
  `host_direct(port)`: LAN/dev hosting from the address panel (port 7777), the session panel shows this machine's
  first private IPv4 `host:port` where the code would be.

### Checks

Survivor's own part of the Godot checks (the rest: the `godot-game` skill): `validate` checks the constants the
scripts read (the cards, a view scene and a rest height per item kind) and that the arena has one MultiMesh
view per `MultiView` kind; `walk` adds to the shared walk the lobby (circle and hint), walking out, the match (enemies
drawn, the auto-attack firing) and a `CommandPick` the session accepts; `tour` plays the real game headless: menu → single
→ lobby → walk out → match with enemies (`uni tool survivor tour`: a whole match, a level-up, game over and back to
the lobby; `play_check`: minutes of play with frame times by enemy count).

### Feel

Camera: 62° pitch, closer in the lobby, look-ahead along the player's velocity. Start: the ring warms to orange and
pulses faster as a player nears its edge (the hint changes too); the match start bursts it outwards with a short
flash, shake and rumble. Damage: red screen edges (capped), low-HP pulse below 30 %, rumble, hit flash on the player.
XP bar flashes on pickup; level-up cards pop when picked (key, pad or click) and the panel lingers 0.35 s. Match over:
time, wave, level, best time (`user://settings.cfg`), countdown to the lobby (`over_hold_s`). Hints
and level-up key labels follow the last input device; pads get A/B on `ui_accept`/`ui_cancel` (none by default in
Godot 4.7). The host's code is copied to the clipboard on arrival; the Join panel prefills a code found on it.
`uni` lists in `.godot/extension_list.cfg` only the extensions whose library exists for this host.

### HUD baseline (every game)

Every game's HUD has the two shared panels, `SessionPanel` and `ControlsPanel`. The game passes the content; the
panel owns the look.
- **Session panel**, top-right. In the lobby (friendslop: the hub): "Lobby", the code (or LAN address) large with
  Copy (offered only while the mouse is free), the players, and a hint (waiting for a friend, or how to start).
  While playing: "Players", the code in one small line (friends can still join), the players with the game's status
  and an optional bar (survivor: level and HP). Hidden when solo and offline.
- **Controls list**, bottom-right, always shown: key → action for the current context (survivor adds the upgrade
  keys while a level-up is up; friendslop swaps grab for drop and throw while holding) and the device in use.

### Art direction

Stylized low-poly primitives with toon shading on a dark slate arena with a 2 m grid. Players warm and bright
(orange, gold, pink, violet per player) with a glowing floor ring; enemies cool per kind (steel-blue hex capsule
grunts, teal three-sided runners, violet brute cubes); glowing yellow projectiles and green gems (bloom); wooden
crates and red barrels. Cyan for the start circle, wall trim and codes. No assets: meshes are primitives, sounds
are synthesized at boot.
