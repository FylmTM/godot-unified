# horde: a heavy 2D horde arena, and the render experiment's baseline

A top-down co-op horde arena: 1–4 heroes hold out against thousands of enemies with weapons that fire on their own
(fans of bolts, chain lightning, lobbed bombs), pick up the gems the dead drop and choose an upgrade at each level.
When every hero is down the arena resets. `uni run horde` plays it.

It exists to compare ways of drawing one unified game in Godot. Its sim (`simulation/horde`) is shared: four examples
render the same State, each its own way, with the same effects, so frame times, memory, Godot objects made and the
code itself can be compared:

| Example                                   | How it draws                                                                                    |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------- |
| horde (this one)                          | The naive way on purpose: a scene per hero, enemy, bolt, gem, bomb and blast, drawn in GDScript `_draw` every frame; a node made per damage number and arc; particles drawn one `draw_circle` each |
| [horde_tuned](../horde_tuned/)            | Nodes done well: MultiMesh views and shaders for the crowds, scene views for the few, effects pooled and animated by shaders |
| [horde_hybrid](../horde_hybrid/)          | Immediate mode: the world drawn in Odin from the State every frame (`godot.Draw`), the HUD in GDScript Controls |
| [horde_odin](../horde_odin/)              | Everything in Odin: the world, the effects and the UI (an immediate UI, or Controls made from Odin) |

Every one carries the same measurement probe (`game/probe.gd`): run an example with `-- --scripted --bench 2000
--heroes 4 --measure <file.json>` (`--unlocked` lifts vsync and the frame cap) and it plays the held population with
four scripted heroes, samples every frame and writes the results.

Sim units are metre-sized cells and seconds at `TICK_HZ` (64: the library's rates are powers of two); the plane is
XY in Godot's 2D axes (x right, y down), drawn at `UNIT_PX` pixels per unit. Every rule number is a named constant
in `simulation/horde/tuning.odin`.

## Controls

Arrows (or a pad's d-pad) move the local hero; the weapons fire on their own. At a level-up, click a card or press
1–3. F1 for the dev UI.

## World

No level: a square arena `ARENA_HALF` from the centre each way, walled. The State holds the heroes (the players'
data), up to `MAX_ENEMIES` enemies, `MAX_BOLTS` bolts, `MAX_BOMBS` bombs in the air, `MAX_BLASTS` blasts and
`MAX_GEMS` gems; the World is scratch only: the enemies' neighbour grid (`GRID_CELL` cells) and the lightning
strike's list.

## Input and commands

- `Input`: a stick. A hero moves at up to its speed (`HERO_SPEED`, raised by `Upgrade.Move_Speed`).
- `Command_Pick {upgrade}`: the oldest pending level-up takes `upgrade` when it is one of the three that level offers
  (`upgrade_offers`: keyed rolls on the player and the level, so a HUD shows the same offer the sim checks).
- `Command_Dev_Spawn {count, kind}`: the dev UI's spawn on the ring.

## Systems (`tick`, in this order)

1. **Heroes.** A newcomer starts at level 1 near the centre (`HERO_SPAWN_SPACING` by slot); a returning hero keeps
   their progress. Picks and dev spawns apply; heroes move, kept inside the walls.
2. **Waves.** While the match runs, a burst every `SPAWN_EVERY_S`: `SPAWN_BASE` + `SPAWN_PER_WAVE` per wave (at most
   `SPAWN_CAP`) on `SPAWN_RING` around the centre plus `SPAWN_JITTER`, kinds from `SPAWN_KINDS`, no burst past
   `ENEMY_CAP` alive. A wave is `WAVE_S`; each adds `HP_PCT_PER_WAVE`% enemy HP.
3. **Steering.** The grid is rebuilt; each enemy seeks the nearest alive hero and pushes off its neighbours
   (`SEPARATION`), blended by `ENEMY_STEER` and capped at `ENEMY_OVERSPEED` times its kind's speed. An enemy touching
   a hero whose `HERO_HURT_COOLDOWN_S` is over deals its kind's damage (`Event_Hero_Hurt`); at 0 HP the hero is down
   (`Event_Hero_Down`) for `HERO_RESPAWN_S`.
4. **Weapons.** Each alive hero's timers: a fan of `bolt_count` bolts at the nearest enemy within `BOLT_RANGE`
   (`Event_Bolt_Fired`), a lightning strike from the nearest within `LIGHTNING_RANGE` chaining `chains` enemies
   within `LIGHTNING_CHAIN_RANGE` (an `Event_Arc` per link), a bomb at the nearest within `BOMB_RANGE`. Bolts fly at
   `BOLT_SPEED` for `BOLT_LIFE_S`, piercing `bolt_pierce` enemies; a bomb lands after `BOMB_FLIGHT_S` and blasts
   every enemy within its radius (`Event_Bomb_Landed`, a blast shown `BLAST_SHOW_S`). Every hit is an
   `Event_Enemy_Hit` (its damage and source: a damage number).
5. **Deaths.** An enemy at 0 HP dies (`Event_Enemy_Died`) and drops a gem of its kind's XP.
6. **Gems.** A gem within `GEM_MAGNET` of an alive hero flies to the nearest at `GEM_SPEED`, and within `GEM_PICKUP`
   it is theirs (`Event_Gem_Collected`); enough XP (`XP_BASE` + `XP_PER_LEVEL` per level) is a level-up and a
   pending pick (`Event_Level_Up`).
7. **Phase.** Downed heroes stand up; when every present hero is down the match is over (`Event_Match_Over`) and
   after `OVER_HOLD_S` the arena resets.

The bench (`bench_prepare`: `uni bench`, Godot's `--bench N`) holds a population of N: the waves refill to it, its
heroes take no damage and start with every weapon high, so the screen is as busy as it gets.

## Scripted inputs

Each scripted hero walks one of 8 directions per `SCRIPT_PERIOD` block (some blocks standing still) and sends a pick
at the start of every block, both from (seed, slot, tick) alone.

## View contract (`simulation/extension`)

The naive one: scene views of every hero, enemy, bolt, gem, bomb and blast (`View_*`), no MultiMesh (one unused
kind: the enum can't be empty), and `Data_Hud` for the HUD. Effects come from the session's `sim_event` signal.
