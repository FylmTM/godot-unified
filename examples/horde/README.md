# horde: a co-op horde arena in 2D, at scale

A top-down co-op horde arena, unified's example of 2D at scale: 1–4 heroes hold out against thousands of enemies
with weapons that fire on their own (volleys of bolts, chain lightning, lobbed bombs), pick up the gems the dead drop
and choose an upgrade at each level. When every hero is down the arena resets. A Godot project (this folder is
`res://`): the sim, its tests, the headless binary and the GDExtension in `simulation/` (Odin), everything Godot in
`game/`. `uni run horde` plays it.

What it shows is how a 2D game draws thousands of things a tick and hundreds of events a second without a node per
thing:

- **The crowds are MultiMesh instances.** Enemies, their HP bars, bolts and gems are MultiMesh views: the host writes
  each kind's instances in one buffer per frame, and a shader per kind draws them from their custom data
  (`game/multi/`). No GDScript runs per enemy.
- **Effects are shader ring buffers driven by events.** Sparks and damage numbers are MultiMesh instances in a ring
  that the shader animates from their birth (`game/fx/`): an event writes a few instances once, and nothing touches
  them again. Lightning arcs are one node drawing every live arc.
- **Scene views only for the few.** Heroes, bombs in the air and blasts are scenes, the bombs and blasts pooled.

Sim units are metre-sized cells and seconds at `TICK_HZ`; the plane is XY in Godot's 2D axes (x right, y down), drawn
at `UNIT_PX` pixels per unit (`Glue.view_scale`, so view and event positions arrive in pixels). Every rule number is a
named constant in `simulation/horde/tuning.odin`; this README names them.

## Controls

WASD / arrows / left stick / d-pad to move; the weapons fire on their own. At a level-up, 1 2 3 / pad X Y B or a
click on a card picks an upgrade. Esc / Start for the menu, F1 for the dev UI.

## World

No level: a square arena `ARENA_HALF` from the centre each way, walled; heroes and enemies are kept inside it, and a
bolt that leaves it is gone. No physics: everything moves by its own rules. The State holds the heroes (the players'
data), up to `MAX_ENEMIES` enemies, `MAX_BOLTS` bolts, `MAX_BOMBS` bombs in the air, `MAX_BLASTS` blasts and
`MAX_GEMS` gems. The World is scratch only, rebuilt every tick: the enemies' neighbour grid (`GRID_CELL` cells), their
next velocities and one lightning strike's targets.

## Input and commands

- `Input`: a stick. A hero moves at up to its speed (`HERO_SPEED`, raised by `Upgrade.Move_Speed`).
- Heroes are session members' data: someone new starts at level 1 near the centre, `HERO_SPAWN_SPACING` apart by
  slot; someone who comes back keeps their hero, level and upgrades.
- `Command_Pick`: the oldest pending level-up takes the upgrade when it is one of the three that level offers
  (`upgrade_offers`), else the pick is ignored.
- `Command_Dev_Spawn`: the dev UI's spawn of a count of one kind on `SPAWN_RING` (a public build never applies it).

## Systems (`tick`, in this order)

1. **Heroes.** Newcomers are placed, picks and dev spawns apply, alive heroes move.
2. **Waves.** While the match runs, a burst every `SPAWN_EVERY_S`: `SPAWN_BASE` + `SPAWN_PER_WAVE` per wave (at most
   `SPAWN_CAP`) on `SPAWN_RING` around the centre plus up to `SPAWN_JITTER` each way, kinds from `SPAWN_KINDS`
   (`ENEMY_STATS`), no burst past `ENEMY_CAP` alive. A wave is `WAVE_S`; each adds `HP_PCT_PER_WAVE`% enemy HP.
3. **Steering.** The grid is rebuilt; each enemy seeks the nearest alive hero and pushes off its overlapping
   neighbours (`SEPARATION`), blended in by `ENEMY_STEER` and capped at `ENEMY_OVERSPEED` times its kind's speed. An
   enemy touching a hero whose `HERO_HURT_COOLDOWN_S` is over deals its kind's damage (`Event_Hero_Hurt`); at 0 HP the
   hero is down (`Event_Hero_Down`) for `HERO_RESPAWN_S`.
4. **Weapons.** Each alive hero's timers fire while a target is in range, else wait for one: a volley of `bolt_count`
   bolts `BOLT_SPREAD_TURNS` apart at the nearest enemy within `BOLT_RANGE` every `bolt_interval` (`Event_Bolt_Fired`);
   a lightning strike every `LIGHTNING_INTERVAL_S` from the nearest within `LIGHTNING_RANGE`, chaining to `chains`
   enemies each within `LIGHTNING_CHAIN_RANGE` of the last (an `Event_Arc` per link); a bomb every `BOMB_INTERVAL_S`
   at the nearest within `BOMB_RANGE`. Bolts fly at `BOLT_SPEED` for `BOLT_LIFE_S`, each hitting up to `bolt_pierce`
   enemies, never the same one twice in a row; a bomb lands after `BOMB_FLIGHT_S` and blasts every enemy within its
   radius (`Event_Bomb_Landed`), its blast shown for `BLAST_SHOW_S`. Every hit is an `Event_Enemy_Hit` with its damage
   and source (`BOLT_DAMAGE`, `LIGHTNING_DAMAGE`, `BLAST_DAMAGE`).
5. **Deaths.** An enemy at 0 HP dies (`Event_Enemy_Died`) and drops a gem worth its kind's XP.
6. **Gems.** A gem within `GEM_MAGNET` of an alive hero flies to the nearest at `GEM_SPEED`; within `GEM_PICKUP` it
   is theirs (`Event_Gem_Collected`). `XP_BASE` + `XP_PER_LEVEL` per level is a level-up and a pending pick
   (`Event_Level_Up`), one a tick.
7. **Phase.** Downed heroes whose respawn ran out stand up where they fell, at full HP. When every present hero is
   down the match is over (`Event_Match_Over`: its length, wave and kills); after `OVER_HOLD_S` the arena empties and
   every present hero starts again at level 1.

The upgrades (`Upgrade`): one more bolt per volley, one more pierce, volleys `BOLT_INTERVAL_LEVELUP_TICKS` sooner
(down to `BOLT_INTERVAL_MIN_TICKS`), one more chain (up to `CHAIN_MAX`), blasts `BLAST_RADIUS_LEVELUP` wider,
`HERO_SPEED_LEVELUP` faster, `HERO_HP_LEVELUP` more HP, healed as much. The systems are grouped into timing zones
(`Zone`: the dev UI's graph and `uni bench`'s zone row).

## Scripted inputs and the bench

Each scripted hero walks one of 8 directions per `SCRIPT_PERIOD` block, standing still one block in
`SCRIPT_IDLE_ONE_IN`, and sends a pick at the start of every block, all from (seed, slot, tick) alone, so a Godot
scripted session sends what the offline binary does. The benchmark (`bench_prepare`) holds a population: the waves
refill to it, its heroes take no damage and start with every weapon high, so every system and every event path runs
at full load.

## View contract (`simulation/extension`)

- Scene views: `hero` (keyed by its player; its slot, alive, hurt and HP share; a respawn bumps its warp), `bomb`
  (posed along its flight; its progress) and `blast` (its radius in pixels and progress). Bombs and blasts are pooled
  (their markers' `pool`): their scripts reset what they own in `_sim_reused` and take null data in the pool.
- MultiMesh views: `enemy`, `bar` (one per damaged enemy, keyed like it), `bolt`, `gem`; what each one's custom data
  means is on `MultiView`.
- Session data `Data_Hud` (`Unified.data.hud`): the phase, time, wave, enemies, kills, the time until the reset, and
  each slot's hero with its oldest pending level-up's offers.
- Constants (`Unified.constants`): the arena's and the heroes' and enemies' sizes, and a level-up card per upgrade.
- Events: effects, sounds, shake and rumble on EMITTED (`game/arena/arena.gd`); banners, notices and the record on
  CONFIRMED (`game/ui/hud.gd`). Enemies and gems are MultiMesh instances, so their events reach no view: only the
  session's `sim_event`.
- Input: the stick from the InputMap's move actions; the HUD sends the pick (`CommandPick`) on a key, pad button or
  click.

The Godot side's app layer (`game/app/`, the menus and panels in `game/ui/`) is the one every example shares
(`.claude/skills/godot-examples/SKILL.md`); horde's own are its sounds, its settings (the furthest wave reached is
this player's record, kept in the settings file), its heroes' colours and the menu's backdrop, a crowd of its own
drawn by the enemy shader.

## Decisions a reader could get wrong

- **Effects are never undone.** A hit, a death or a blast predicted and then cancelled by a rollback has already
  shown its sparks and number, and they stay: the ring buffers keep no record of which event wrote what, and at this
  density a wrong spark goes unseen. What must be right (banners, the record) waits for CONFIRMED.
- **The ring buffers overwrite their oldest.** A burst past a buffer's size reuses the oldest instances, which have
  long faded by then; no effect allocates while the match runs.
- **A level-up's offers name no tick.** `upgrade_offers` rolls from the player and the level only, so the HUD shows
  the offers the sim will check from whatever state it last saw, and a pick sent a few ticks later is still valid.
- **Deaths wait for the weapons.** A hit only lowers HP; deaths happen in one pass after every weapon has fired, so
  a blast or a chain hitting several enemies sees each where it was. An enemy already at 0 HP takes no more hits that
  tick: the next weapon's damage numbers never show on the dead.
- **`TICK_HZ` is 64.** The library's tick rate is a power of two (`sim.Game.tick_hz`), the nearest to 60.
- **The menu's crowd is not the sim.** No session runs on the main menu; its backdrop animates a MultiMesh of its own
  with the match's enemy shader and the sim's sizes.
