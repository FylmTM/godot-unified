# holdout: a co-op first-person shooter defending a core

A first-person co-op shooter, unified's example of a game that aims in 3D and paths in 3D: 1–4 players defend a
core in the middle of a walled yard against `WAVES` waves from three gates, with a hitscan rifle (headshots), a
bouncing grenade, and revives for downed teammates. Enemies walk the yard's navigation mesh: down from the raised
deck the east gate opens onto, over the bridge across the trench. A Godot project (this folder is `res://`): the sim,
its tests, the headless binary and the GDExtension in `simulation/` (Odin), everything Godot in `game/`. `uni run
holdout` plays it (alone, or with friends online or on the LAN: Playing together); `uni coop holdout` plays a
host and a joiner.

Metres and seconds at `TICK_HZ`; the ground is the XZ plane, Y is up. Every rule number is a named constant in
`simulation/holdout/tuning.odin`; this README names them.

What it shows of unified:
- **Aim as input** (`dmath.Aim`): yaw and pitch in 4 bytes, decoded with no atan2. The camera rig keeps its own look
  at render rate, so a rollback never turns your view.
- **Shots that land where the shooter saw the target** (`sim.Seen`, `physics.world_cast_ray_closest_rewound`).
- **Navigation in 3D** (`unified:nav` on the level's baked navigation mesh, `src/level/README.md`): distance fields
  memoized in the World, steering, and moves along the surface.
- **Teammates on the verified timeline** (the player kind's policy in `Glue.views`, `remote = .Verified`;
  `src/godot/README.md`): a few ticks late, never corrected, their shots and hits arriving with their bodies.
- Kinematic Box3D enemies with a head shape of their own, a Box3D grenade in bullet mode, and swept bolts.

## Controls

Mouse / right stick to look, WASD / arrows / left stick to move, Space / pad A to jump, left mouse / right trigger to
fire, G / right mouse / pad RB to throw a grenade, E / pad X (held) to revive, R / Enter / Start to start the run in the
lobby, Tab / pad LB to cycle a few views of the yard and back, Esc to free the mouse (a click takes it again), F1 for
the dev UI.

## Playing together

The start panel (`game/start_panel.tscn`) comes up before a session and again when one ends, saying why: Play alone,
Host online (an EOS lobby, its code in the top right corner to share; Copy puts it on the clipboard), Join by code,
Host on the LAN (`LAN_PORT`, the address in the corner) and Join on the LAN (host:port). Leave, in the corner, ends the
session (a host's ends it for everyone); Esc frees the mouse to reach it. The panel follows the session's status, so the session flags and `uni coop`
start without it. Online play needs a build with the EOS IDs compiled in: `uni run` with `.env` set, or the zip `uni
release holdout` makes (`docs/EOS.md`).

## World

The yard is a level (`game/levels/yard.tscn`, baked to `yard.level` with `uni bake holdout --nav`): a 72 m square
inside walls, a sunken trench with a ramp at each end and a bridge across its middle, a deck 4 m up against the east
wall with two ramps down, crates and blocks for cover, and the core: a static box whose `unified_category` is
`CAT_CORE`. Every static body sits under the `NavigationRegion3D`, whose bake (static colliders, the agent's size) is
the navigation mesh the enemies walk. Markers: a `spawn` per slot (in scene order), the `gate`s the waves come in at
(north, east on the deck, west across the trench), and the `core`.

`world_create` builds the physics world from the level, the navigation mesh (`nav.build`) with a memo of `MAX_FIELDS`
fields, and the markers' positions; the core's goal is the mesh point nearest to it. Shape categories (`CAT_*`) tell
what a ray or an overlap struck: the level, the core, a player, an enemy's body or its head, a grenade.

The State holds the players (`sim.Players`), the enemies, bolts and grenades (`sim.Table`s of `MAX_ENEMIES`,
`MAX_BOLTS`, `MAX_GRENADES`), the core's health, the phase and wave, and the run's kills.

## Input

- `Input`: a stick in the player's own frame (strafe, forward), the buttons, `seen` (the host stamps how late the
  screen the player acted on was, `sim.Seen`: 0 for scripts) and `aim` (`dmath.Aim`).
- Players are session members: one who leaves loses their body; one who comes back gets a fresh body at their slot's
  spawn with `PLAYER_HP`.
- No commands: everything a player does is their input.

## Phases

- **Lobby**: no enemies; any present player's Ready press starts the **Countdown** (`START_DELAY_S`,
  `Event_Countdown`).
- **Wave** `1..WAVES` (`Event_Wave_Started`): each wave's bursts (`WAVE_PLANS`: a gate, a kind, a count, when the first
  comes and how often the rest) spawn one enemy at a time, the count scaled by the players present (`scaled_count`),
  never more than `ENEMY_CAP` alive. A wave is cleared when every burst has spawned and no enemy is left
  (`Event_Wave_Cleared`): a **Break** of `WAVE_BREAK_S`, then the next.
- **Over**: the last wave cleared (`Event_Victory`) or the core at 0 during a wave or a break
  (`Event_Core_Destroyed`). After `OVER_HOLD_S` the yard goes back to the lobby (`Event_Lobby`): enemies, bolts and
  grenades gone, the core whole, every present player up at their spawn.

## Systems (`tick`, in this order)

1. **Presence** (`update_presence`): a leaver's body goes; an arrival gets one at their slot's spawn.
2. **The run** (`run_phase`, `spawn_enemies`): the phases above.
3. **Players move** (`move_players`): a `physics.Character` each, the stick turned by the aim's yaw at `WALK_SPEED`,
   a jump on the press; downed, they lie still. Below `KILL_Y` a player goes down at once.
4. **Enemies choose** (`choose_targets`): a runner or a spitter looks for a player every `SIGHT_EVERY_TICKS`
   (time-sliced by its index, `sim.due`): the nearest one up within `AGGRO_RADIUS` that a ray from its head reaches
   past the level and the core. Between looks it keeps its target while that player is up. A brute never chases.
5. **Enemies walk** (`move_enemies`): toward their target player's point on the mesh, else the core's, along that
   goal's distance field (`nav.field`, memoized: a pure function of the mesh and the goal), steering at the funnel's
   next corner (`nav.steer`) and moving along the surface (`nav.move`) at their kind's speed (`ENEMY_SPECS`). They
   stop where they attack from: in reach of a player, at the core's side (`CORE_REACH`), or `SPIT_RANGE` away for a
   spitter. Enemies within `SEPARATION` on the same floor (`SAME_FLOOR`) push apart, at most `SEPARATION_SPEED`
   (`sim.Grid`). The kinematic body follows its feet with a target transform, so the step gives it the velocity a
   rewound shot reads.
6. **Physics step** (`physics.step`).
7. **The rifle** (`fire_rifles`): a player up holding Fire shoots every `FIRE_INTERVAL_TICKS`: a ray of `RIFLE_RANGE`
   from their eye along the aim, strayed by up to `SPREAD` (a keyed roll). It is cast on the world as the shooter's
   screen showed it: the eye moved back by the shooter's own velocity, moving bodies by theirs, over
   `sim.seen_rewind` of their input (at most `MAX_REWIND_S`). An enemy struck takes `RIFLE_DAMAGE`, `HEADSHOT_MULT`
   times that on its head shape (`Event_Shot`, `Event_Enemy_Hit`; at 0 HP `Event_Enemy_Died` and its body goes).
8. **Grenades** (`throw_grenades`, `burn_fuses`): a Grenade press throws one when `GRENADE_COOLDOWN_S` has run out: a
   dynamic sphere in bullet mode that bounces (`GRENADE_RESTITUTION`) and passes through players, thrown out of the
   rewound eye at `GRENADE_SPEED` plus the thrower's velocity (`Event_Grenade_Thrown`). It explodes when its `FUSE_S`
   runs out or an enemy's capsule is within `TOUCH_RADIUS` (`Event_Explosion`): every enemy within `BLAST_RADIUS` in
   the open from it (a ray the level and the core don't block) takes `BLAST_DAMAGE`, down to a third at the edge, and
   loose bodies are pushed away.
9. **Bolts** (`fly_bolts`): each flies `BOLT_SPEED` for at most `BOLT_LIFE_S`, swept against the level, the core and
   the players; a player up or the core takes its damage, and it is gone.
10. **Enemies attack** (`enemy_attacks`): every `attack_s` of its kind, a runner hits its target player in reach, a
    spitter fires a bolt (`Event_Bolt_Fired`) at its target in sight within `SPIT_REACH` (or the core), and an enemy
    at the core's side with no player target hits the core (`core_damage`, `Event_Core_Hit`). A player at 0 HP goes
    down (`Event_Player_Hurt`, `Event_Player_Downed`).
11. **Revives** (`revive_players`): a player up holding Use within `REVIVE_RANGE` of a downed teammate (the nearest)
    brings them closer to getting up; `REVIVE_S` of it gets them up with `REVIVE_HP` (`Event_Player_Revived`). A
    downed player no one revives this tick loses the progress.
12. **Respawns** (`respawn_players`): a downed player whose `RESPAWN_S` ran out gets up at their spawn with `PLAYER_HP`
    (`Event_Player_Respawned`). Alone, that is the only way up.
13. **The end** (`end_run`): the core at 0 ends the run.

## Events

Every event above goes to the `sim_event` signal; a view gets those whose subject it shows: a player's shot, hurt and
throw go to their player view, an enemy's hit to its enemy view. A death (its enemy is gone) and a revive (two
players) go to the signal only (`event_key`). The library's joins and leaves too.

## Scripted inputs

A scripted player (`script.odin`) wanders on a half-tilted stick drawn every `SCRIPT_PERIOD` ticks, faces one of
the gates (`SCRIPT_GATE_YAWS`, one per `SCRIPT_LOOK_PERIOD`) sweeping its aim across it, fires three ticks in four,
throws a grenade every `SCRIPT_THROW_EVERY` ticks, holds Use now and then, and slot 0 presses Ready every
`SCRIPT_READY_EVERY` ticks so runs start. A pure function of the seed, the slot and the tick, so any tick can be asked
for in any order. Four of them play every rule within a few minutes, a run lost and the lobby again included
(`simulation/tests/holdout_test.odin`).

## View contract (`simulation/extension`)

- **Views**: `player` (posed at the feet, turned by the aim's yaw; data `Player_View`: colour, the aim's pitch, HP,
  downed, revive progress), on the verified timeline when it shows a teammate; `enemy` (at the feet, facing where it
  walks; data `Enemy_View`: kind and health), sized from the sim's own spec (`Unified.constants.enemy_sizes`), so a
  shot that looks like a headshot is one.
- **MultiViews**: `bolt`, `grenade`.
- **Session data**: `Data_Hud` (`Unified.data.hud`): the phase and wave, the core's health, the enemies left, the
  kills, and the local player's health, grenade cooldown, rifle readiness and downed timers.
- **Constants** (`Unified.constants`): the player's and enemies' sizes, the pitch limit, the fire interval, the blast
  radius, the core's health and the wave count.

The Godot side (`game/`): `main.tscn` holds the session, the level and view roots, the rig, the effects, the HUD and the start panel.
`rig.gd` is the first-person camera: it keeps yaw and pitch in turns and hands them over on `input_wanted`, sits at
the local player's view at eye height, and kicks the viewmodel on a shot the sim will fire. `player.gd` draws a
shot's tracer: your own at once (EMITTED), a teammate's when their late body fires it (CONFIRMED). `effects.gd` plays
the blasts, hits and deaths from the signal, and `hud.gd` reads `Unified.data.hud`, with the run's result from
CONFIRMED events only.

## Tests and the benchmark

`simulation/tests`: the reference run, the standard scenarios (rollback every tick, players coming and going, bad
networks, a late joiner, the replays), a scripted run that plays every rule, and a test per rule on a sync-tested run.
`uni bench holdout` holds the last wave at `ENEMY_CAP` enemies with four firing players (`bench_prepare`).
