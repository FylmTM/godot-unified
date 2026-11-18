# survivor

Status: draft, pending #327

A top-down co-op survival game, unified's example of a game at scale: 1–4 players hold out in an arena against waves
of up to **1200 enemies**, with projectiles, Box3D crates and barrels, explosions, gems, a level-up pick, death and
respawn, joining and leaving, a lobby and match resets. Units: metres and seconds at **64 Hz**; the ground is the XZ
plane, Y is up. Every rule number is a named constant in `simulation/survivor/tuning.odin`; this spec names them.

## World

The arena is a level (`game/levels/arena.tscn`, baked to `arena.level`, `src/level/SPEC.md`): the ground, four walls
(their `unified_category` is `CAT_WALL`) and eight pillars (`CAT_PILLAR`), all static boxes. Enemies are no physics
bodies, so the World also keeps what they move around: the pillars' boxes on the ground plane, and how far the walls'
inner faces are from the centre.

The level also places the crates and barrels and the players' start spots. Its `item` markers are the view scenes
themselves (`game/views/crate.tscn`, `barrel.tscn`; `prop_view.gd` declares the kind, each scene sets its `kind`):
each is a dynamic body tagged with its index (the markers' scene order, at most `MAX_ITEMS`), created where the
marker rests; the play scene removes the markers, the items' views draw them, and the menu backdrop shows the level
as it is. Its `spawn` markers, one per slot in scene order (asserted), are the start spots: players are dynamic
capsules with rotation locked, created at their slot's spot when they become present.

## Input and commands

- `Input`: `move_x, move_z` (a stick, `dmath.stick`) and `buttons` (`Dash`, on the press).
- Players are session members: a player who leaves loses their body and keeps their progress (level, XP, upgrades,
  pending level-ups); someone new starts fresh; both get a body at their slot's start spot with full HP. Everything
  per player is by player, not slot.
- `Cmd_Pick {upgrade}`: one pending level-up goes to `Fire_Rate`, `Damage` or `Move_Speed` (the HUD's card order). A
  pick with nothing pending is ignored.

## Phases

- **lobby** (tick 0, and after every reset): no enemies; the start circle (`START_RADIUS`) at the centre. The match
  starts on the tick an alive player's centre leaves it (`match_started`).
- **match**: waves (Tuning). When every present player is dead at once: **over** (`match_over`, its length). When
  nobody is present: a reset.
- **over**: dead players don't respawn; after `OVER_HOLD_S` the world resets: every dynamic body is destroyed, every
  known player's progress starts fresh, items (in index order) and present players (in slot order, `player_respawned`)
  are recreated, enemies, projectiles and gems go, back to the lobby.

## Tuning

The pace of a match is state (`State.tuning`, a copy of a `TUNINGS` preset), so every peer shares it. A burst of
`min(base + per_wave · wave, cap) · (100 + extra · (present − 1)) / 100` enemies every `spawn_every_ticks`, never past
`enemy_cap`; enemy HP `· (100 + hp_pct · wave) / 100`; the next level at `xp_first + (level − 1) · xp_step` XP.
`play` is the game (`GAME`), `stress` the dense spawner the headless modes, the end-to-end suite and the bench run
(`GAME_STRESS`), `bench` an endless match holding a fixed population (`bench_prepare`). The long suite checks `play`
with the bot (`simulation/tests/bot.odin`) over 8 seeds: each first level-up in 10–45 s, on average a survival past 120 s and wave 3.5.

## Systems (`tick`, in this order)

1. `update_players`: leaves, joins and returns; respawns (`PLAYER_RESPAWN_TICKS`, not while over); the stick times
   the player's speed, times `DASH_SPEEDUP` while dashing; y velocity kept from physics.
2. `pick_upgrades`: each pick, in order.
3. `spawn_waves` (match only): each enemy at `SPAWN_RING` in one of 8 directions plus up to `SPAWN_JITTER` on each
   axis, its kind from `SPAWN_KINDS`: keyed rolls (`sim.roll_below`, `sim.roll_f32`) by its place in the burst.
4. `steer_enemies`: from the old positions, each seeks the nearest alive player (lowest slot on ties) plus separation
   from the enemies in its 3×3 grid cells; blended (`ENEMY_STEER`), capped (`ENEMY_OVERSPEED`). Then each moves,
   pushed out of every pillar along its shallower axis and kept inside the walls. Every `CLIMB_CHECK_TICKS` an
   enemy standing where an item could be under it casts a ray down: on a crate or barrel above `CLIMB_HEIGHT` it is
   slowed (`CLIMB_SLOWDOWN`).
5. `hurt_players`: an enemy touching an alive player deals its damage, then waits `CONTACT_COOLDOWN_TICKS`.
6. `fire`: each alive player, when its cooldown is up, shoots at the nearest enemy within `FIRE_RANGE`.
7. `move_projectiles`: a projectile hits the lowest-index enemy it reaches (on the grid), else whatever its path
   crosses (a ray against the level, crates and barrels; a barrel takes the damage), else moves on; it expires.
8. `explode_barrels`: due barrels come back; a barrel at HP ≤ 0 explodes, in item order: an impulse on the bodies
   within `BLAST_RADIUS`, damage to the enemies within it and to the players within `BLAST_PLAYER_RADIUS`
   (`barrel_exploded`); it comes back after `BARREL_RESPAWN_TICKS`.
9. `kill_enemies`: an enemy at HP ≤ 0 dies (`enemy_died`) and drops a gem worth its XP (gems full: the nearest
   player gets it).
10. `collect_gems`: within `GEM_REACH` of an alive player, the lowest slot first (`gem_collected`).
11. `level_up`: XP past the threshold becomes levels and pending level-ups (`level_up`).
12. The physics step, then the players' positions read back.
13. `advance_phase`.

## Events

`player_died`, `player_respawned`, `match_started` (`position`, `player`); `match_over` (`duration_s`); `level_up`
(`position`, `level`, `player`); `enemy_died` (`enemy` handle, `position`, `enemy_kind`); `gem_collected` (`gem`
handle, `position`, `xp`, `player`); `barrel_exploded` (`entity`: the item's index, its view's key; `position`); and
the library's joins and leaves. Positions are the body's centre for players and barrels, the ground for enemies and
gems.

## Scripted inputs

The game's scripted player (`script.odin`) is stateless: a hash of (seed, slot, 24-tick block) picks one of 8
directions or none, a dash, and a pick at each block's start, so any tick can be asked for in any order and a session
and an offline run agree. The balance test's bot is not the scripted player: it reads the state, which a session
samples at another tick, and lives with the tests.

## View contract (`simulation/extension`)

- Scene views: `player` (keyed by `sim.player_key`, its data `hp` and `dashing`), `crate` and `barrel` (keyed by the
  item's index, posed with their physics rotation). A destroyed barrel's view goes; the one that comes back is new.
- MultiMesh views: `grunt`, `runner`, `brute` (in `Enemy_Kind`'s order), `projectile`, `gem`, keyed by handle, on the
  ground plane facing their velocity; custom data r = hit flash, g = age in seconds.
- Session data `Data_Hud` (`Unified.data.hud`): phase, match time, wave (1-based in a match), enemies alive, the
  seconds until the reset (over), and per slot alive, hp, hp_max, xp, xp_next, level, pending level-ups, respawn
  seconds.
- Constants (`Unified.constants`): `start_radius`, `blast_radius`, the three level-up cards.
- Events: effects, sounds, shake and rumble on EMITTED (a prediction too; a cancelled one is left as it played);
  banners and the best time on CONFIRMED.
- Input: the stick and the dash from the InputMap; the HUD sends the pick (`CommandPick`) on a key, pad button or
  click.
