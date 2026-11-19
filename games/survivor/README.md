# survivor: a co-op horde survival game at scale

A top-down co-op survival game, unified's example of a game at scale: 1–4 players hold out in an arena against waves
of up to `MAX_ENEMIES` enemies, with projectiles, Box3D crates and barrels, explosions, gems, a level-up pick, death
and respawn, joining and leaving, a lobby and match resets. A Godot project (this folder is `res://`): the sim, its
tests, the headless binary and the GDExtension in `simulation/` (Odin), everything Godot in `game/`. `uni run
survivor` plays it.

Metres and seconds at `TICK_HZ`; the ground is the XZ plane, Y is up. Every rule number is a named constant in
`simulation/survivor/tuning.odin`; this README names them.

## Controls

WASD / arrows / left stick to move, Space / pad A to dash, 1 2 3 / pad X Y B to pick a level-up, Esc / Start for
the menu, F1 for the dev UI.

## World

The arena is a level (`game/levels/arena.tscn`, baked to `arena.level`, `src/level/README.md`): the ground, four
walls (their `unified_category` is `CAT_WALL`) and eight pillars (`CAT_PILLAR`), all static boxes. Enemies are no
physics bodies, so the World also keeps what they move around: the pillars' boxes on the ground plane, and how far the
walls' inner faces are from the centre.

The level also places the crates and barrels and the players' start spots. Its `item` markers are the view scenes
themselves (`game/views/crate.tscn`, `barrel.tscn`; `prop_view.gd` declares the kind, each scene sets its `kind`):
each is a dynamic body tagged with its index (the markers' scene order, at most `MAX_ITEMS`), created where the
marker rests; the play scene removes the markers, the items' views draw them, and the menu backdrop shows the level
as it is. Its `spawn` markers, one per slot in scene order, are the start spots: players are dynamic capsules with
rotation locked, created at their slot's spot when they become present.

## Input and commands

- `Input`: a stick and the dash (on the press).
- Players are session members: a player who leaves loses their body and keeps their progress (level, XP, upgrades,
  pending level-ups); someone new starts fresh; both get a body at their slot's start spot with full HP
  (`PLAYER_HP`). Everything per player is by player, not slot.
- `Cmd_Pick`: the oldest pending level-up goes to the fire rate, damage or move speed (`FIRE_LEVELUP_TICKS`,
  `DAMAGE_LEVELUP`, `SPEED_LEVELUP`) when it is one of that level's two offers, a keyed roll of the player and the
  level (`upgrade_offers`) that the HUD peeks to show only those cards. A pick with nothing pending, or not
  offered, is ignored.
- Dev commands (the dev UI's Commands panel; a public build never applies them): `Cmd_Dev_Give_Xp` (XP for a
  player), `Cmd_Dev_Skip_Wave` (the next wave), `Cmd_Dev_Spawn` (enemies of a kind on `SPAWN_RING`), applied first in
  the tick (`apply_dev_commands`).

## Phases

- **lobby** (tick 0, and after every reset): no enemies; the start circle (`START_RADIUS`) at the centre. The match
  starts on the tick an alive player's centre leaves it (`match_started`).
- **match**: waves (Tuning). When every present player is dead at once: **over** (`match_over`, its length). When
  nobody is present: a reset.
- **over**: dead players don't respawn; after `OVER_HOLD_S` the world resets (`reset_world`): every known player's
  progress starts fresh, the items and present players are rebuilt, enemies, projectiles and gems go, back to the
  lobby.

## Tuning

The pace of a match is state (`State.tuning`, a copy of a `TUNINGS` preset), so every peer shares it: the burst size
grows with the wave up to a cap and with each present player past the first, a burst comes every
`spawn_every_ticks`, never past `enemy_cap`; enemy HP grows by a percentage per wave; each level needs `xp_step` more
XP than the last (`xp_next`). `play` is the game (`GAME`), `stress` the dense spawner the headless modes, the
end-to-end suite and the bench run (`GAME_STRESS`), `bench` an endless match holding a fixed population
(`bench_prepare`).

## Setup, roles and the save

- **The session's Setup** (`Setup`): a difficulty and the host's best wave. `init` scales the `play` tuning on Hard
  (`HARD_SPAWN_PCT`, `HARD_HP_PCT_PER_WAVE`) and starts `State.best_wave` from the Setup; a match that ends past it
  raises it, and `Event_Match_Over` carries the waves reached and the record.
- **The save** is the game's own settings file: whoever hosts (single player too) writes the record at that
  difficulty when the match-over event is confirmed, and the next hosted session's Setup carries it back into the sim.
- **A player's role** (`Profile`): Gunner fires sooner (`ROLE_FIRE_TICKS`), Bruiser hits harder (`ROLE_DAMAGE`),
  Runner moves faster (`ROLE_SPEED`). A new player starts in it from their first tick; a reset keeps it. The scripted
  players take a role per slot, so the reference run covers each.

## Systems (`tick`, in this order)

1. `update_players`: leaves, joins and returns; respawns after `PLAYER_RESPAWN_TICKS`; movement at the player's
   speed, `DASH_SPEEDUP` times it while dashing (`DASH_TICKS`, then `DASH_COOLDOWN_TICKS`).
2. `pick_upgrades`: each pick, in order, if it is one of the oldest pending level-up's two offers (`upgrade_offers`).
3. `spawn_waves` (match only): a burst on `SPAWN_RING`, its kinds from `SPAWN_KINDS` (`ENEMY_STATS`), by keyed rolls.
4. `steer_enemies`: each seeks the nearest alive player, kept apart from its neighbours (`SEPARATION`), moves, and
   is pushed out of the pillars and kept inside the walls (the neighbours from a `sim.Grid` of `GRID_CELL` cells); one
   standing on a crate or barrel is slowed, checked for each enemy every `CLIMB_CHECK_TICKS` (`sim.due`)
   (`CLIMB_SLOWDOWN`).
5. `hurt_players`: an enemy touching an alive player deals its damage, then waits `CONTACT_COOLDOWN_TICKS`.
6. `fire`: each alive player, every fire interval (`FIRE_INTERVAL_TICKS`, down to `FIRE_INTERVAL_MIN_TICKS`), shoots
   at the nearest enemy within `FIRE_RANGE` (the interval runs on while the player is dead).
7. `move_projectiles`: a projectile hits an enemy, else the level or an item (a barrel takes the damage), else moves
   on; it expires after `PROJECTILE_LIFE_TICKS`.
8. `explode_barrels`: due barrels come back; a barrel at HP ≤ 0 explodes (`barrel_exploded`): an impulse within
   `BLAST_RADIUS`, damage to the enemies within it and to the players within `BLAST_PLAYER_RADIUS`; it comes back
   after `BARREL_RESPAWN_TICKS`.
9. `kill_enemies`: an enemy at HP ≤ 0 dies (`enemy_died`) and drops a gem worth its XP.
10. `collect_gems`: within `GEM_REACH` of an alive player (`gem_collected`).
11. `level_up`: XP past the threshold becomes levels and pending level-ups (`level_up`).
12. The physics step, then the players' positions read back (`read_back`).
13. `advance_phase`.

The systems are grouped into timing zones (`Zone`: `uni bench`'s zone row). Its debug draws: the steering draws who
each enemy chases and the enemies climbing an item, and `physics.debug_draw` the physics shapes, contacts and sleep
state; none of it is state.

## Events

`player_died`, `player_respawned`, `match_started`, `match_over`, `level_up`, `enemy_died`, `gem_collected`,
`barrel_exploded` (its subject the item, by index, so it reaches the barrel's view), and the library's joins and
leaves.

## Scripted inputs

The game's scripted player (`script.odin`) is stateless: a hash of (seed, slot, `SCRIPT_PERIOD`-tick block) picks a
direction or none, a dash, and a pick at each block's start, so any tick can be asked for in any order and a session
and an offline run agree. The balance test's bot is not the scripted player: it reads the state, which a session
samples at another tick, and lives with the tests (`simulation/tests/bot.odin`).

## View contract (`simulation/extension`)

- Scene views: `player` (keyed by `sim.player_key`, its data `hp` and `dashing`), `crate` and `barrel` (keyed by the
  item's index, posed with their physics rotation). A destroyed barrel's view goes; the one that comes back is new.
- MultiMesh views: `grunt`, `runner`, `brute` (in `Enemy_Kind`'s order), `projectile`, `gem`, keyed by handle, on the
  ground plane facing their velocity; custom data r = hit flash, g = age in seconds.
- Session data `Data_Hud` (`Unified.data.hud`): the phase, the match time and wave, enemies alive, the time until the
  reset, and each slot's player (with their oldest pending level-up's offers).
- Constants (`Unified.constants`): `start_radius`, `blast_radius`, the three level-up cards.
- Events: effects, sounds, shake and rumble on EMITTED (a prediction too; a cancelled one is left as it played);
  banners and the best time on CONFIRMED.
- Input: the stick and the dash from the InputMap; the HUD sends the pick (`CommandPick`) on a key, pad button or
  click.
