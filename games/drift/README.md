# drift: a co-op ship arena in 2D

A top-down co-op ship arena, unified's example of a 2D game: 1–4 players fly ships around a slowly turning station
and defend it from rocks that drift in from the edges in waves. Big rocks split, the smallest drop gems that repair
the station, and warp gates carry a ship across the arena. When the station's HP reaches 0 the match is over. A Godot
project (this folder is `res://`): the sim, its tests, the headless binary and the GDExtension in `simulation/`
(Odin), everything Godot in `game/`. `uni run drift` plays it.

Metres and seconds at `TICK_HZ`; the plane is XY in Godot's 2D axes (x right, y down), and the view draws
`Glue.view_scale` pixels per metre (the level is baked at the same scale). Physics is Box3D locked to the plane
(`src/physics/README.md`, 2D). Every rule number is a named constant in `simulation/drift/tuning.odin`; this README
names them.

## Controls

WASD / left stick to thrust (world directions), mouse / right stick to aim, LMB or Space / RT to fire, RMB or Shift /
LT or A to boost, Enter / X to start (and to restart when the station is lost), Esc / Start for the menu, F1 for the
dev UI.

**Couch co-op**: a pad that presses Start during play joins as another local player (one session, one connection,
each player its own member; up to the library's local players). The first player keeps the keyboard and mouse; each
pad player thrusts and aims with its own sticks (`sample_input` reads the sampled player's device), and the camera
frames every local ship.

## World

The arena is a level drawn in Godot's 2D editor (`game/levels/arena.tscn`, baked to `arena.level`,
`src/level/README.md`, 2D levels): static walls and obstacles, then markers: a `spawn` per slot (its `slot`), the
`station`, `gate`s (`pair`: the other gate) and `rock_spawn`s on the edges (`dir`: the drift direction).

- The station: a kinematic hexagon (`STATION_RADIUS`) at the station marker, with `STATION_HP`.
- Ships: dynamic circles (`SHIP_RADIUS`, `SHIP_DENSITY`, `SHIP_DAMPING`), made when a player becomes present, at
  their slot's spawn, nose up.
- Rocks: convex 8-gons, one of `ROCK_VARIANTS` shapes (`ROCK_SHAPES`) scaled by their size's radius (`ROCK_STATS`:
  radius, HP, station damage for small, medium and large), tagged with their handle's key.
- Bullets and gems are no bodies.

## Input and commands

- `Input`: a move stick and an aim direction (none keeps the heading), in world space, and fire and boost, both held.
- Players are session members: a ship is its player's data (`sim.Players`). One who leaves loses the body and keeps
  the rest (shots, gems, cooldowns) until the session forgets them; someone new starts with a zeroed ship.
- `Cmd_Start` (lobby → match; anyone may send it) and `Cmd_Restart` (over → lobby at once). Each is ignored outside
  its phase.

## Phases

- **lobby** (tick 0, and after every reset): ships fly, no rocks.
- **match** (after `Cmd_Start`): waves of rocks; the match is over when the station's HP is 0 (`Event_Match_Over`).
- **over**: the station stops turning and takes no hits. After `OVER_HOLD_TICKS`, or on `Cmd_Restart`, the world resets
  (`reset_world`) and the lobby begins again.
- With nobody present: a reset.

## Systems (`tick`, in this order)

1. `update_players`: a player who left loses their body; one who joined or came back gets one at their slot's spawn
   (`Event_Spawned`).
2. `apply_commands`: `Cmd_Start` and `Cmd_Restart`, in slot order.
3. `fly_ships`: thrust (`THRUST_ACCEL`), turning toward the aim (`TURN_GAIN`, `TURN_MAX`), boost (`BOOST_SPEED`,
   `BOOST_COOLDOWN_TICKS`) and fire (`FIRE_EVERY_TICKS`, `BULLET_SPEED`, `Event_Fired`).
4. `turn_station`: `STATION_SPIN`, 0 while over.
5. The physics step.
6. `move_bullets`: a bullet's ray (the level, rocks, the station) ends it on a hit; a rock hit costs it 1 HP and
   pushes it (`BULLET_PUSH`, `Event_Rock_Hit`); the station takes no damage from bullets. A bullet expires after
   `BULLET_LIFE_TICKS`.
7. `hit_station` (not while over): a rock that reaches the station is gone (`Event_Station_Hit`) and, during a match,
   costs the station its size's station damage.
8. `break_rocks`: a rock at 0 HP, large or medium, splits into two of the next size moving apart (`ROCK_SPLIT_GAP`,
   `ROCK_SPLIT_SPEED`, `ROCK_SPLIT_SPIN`, `Event_Rock_Split`). A small one is destroyed (`Event_Rock_Destroyed`), and
   one in `GEM_DROP_EVERY` drops a gem (`GEM_THROW`).
9. `warp_ships`: a ship within `GATE_RADIUS` of a charged gate comes out of its pair with its heading and velocity
   (`Event_Warped`); both gates and the ship wait `GATE_CHARGE_TICKS`.
10. `collect_gems`: gems drift and slow (`GEM_DRAG`); a ship within `GEM_PICK_RADIUS` picks one up (`Event_Gem_Picked`):
    +1 score, `GEM_REPAIR` station HP up to `STATION_HP`. A gem expires after `GEM_LIFE_TICKS`.
11. `spawn_waves` (match only): a wave every `WAVE_EVERY_TICKS` (`Event_Wave`) brings `WAVE_ROCKS` large rocks,
    `WAVE_ROCKS_MORE` more each wave, one every `ROCK_EVERY_TICKS`, from the `rock_spawn` markers in turn, at
    `ROCK_SPEED`, `ROCK_SPEED_PER_WAVE` faster each wave, along the marker's direction turned up to `ROCK_SPREAD_TURNS`,
    spinning up to `ROCK_SPIN_MAX`.
12. `advance_phase`.

## Events

`Event_Spawned`, `Event_Fired`, `Event_Boosted`, `Event_Warped`, `Event_Rock_Hit`, `Event_Rock_Split`,
`Event_Rock_Destroyed`, `Event_Station_Hit`, `Event_Gem_Picked`, `Event_Wave`, `Event_Match_Started` (who sent
`Cmd_Start`), `Event_Match_Over`, and the library's joins and leaves. Positions are in metres in the sim and in pixels
in GDScript, like the views.

## Scripted inputs

The game's scripted player (`script.odin`) is stateless: a hash of (seed, slot, `SCRIPT_PERIOD`-tick block) moves the
ship in one of 8 directions or not at all, aims it in one of 8, fires most of the time and boosts now and then. Slot 0
sends `Cmd_Start` and `Cmd_Restart` on a fixed beat (`SCRIPT_COMMAND_EVERY`), so scripted runs play whole matches; a
session and an offline run agree.

## View contract (`simulation/extension`)

- Scene views (each a Node2D with a UnifiedView marker):
  - `ship` (`Ship_View`), keyed by its player (`sim.player_key`), so the view survives a leave and comes back with
    the player in any slot; its colour and "P<n>" follow the slot they hold (`Unified.session.get_player_slot`).
    When the player leaves, the ship shrinks away while the view lingers (`_sim_despawned`; `_sim_revived` undoes
    it). A gate and the reset teleport the ship's body, which moves its warp epoch on (`physics.body_warp`): the view
    snaps across, never glides.
  - `station` (`Station_View`), key 0.
  - `gate` (`Gate_View`), keyed by the gate's index.
- MultiMesh views (MultiMeshInstance2D, `TRANSFORM_2D`, keyed by handle):
  - `rock_0..3`: a polygon mesh per shape variant at radius 1, scaled per axis by the rock's radius (squashed for a
    moment when hit), custom data `{size, hit flash}`.
  - `bullet`: a quad stretched along its velocity, tinted with the colour of its owner's slot (custom.x; -1, a pale
    grey, once the owner has left).
  - `gem`: a spin and a squash-and-stretch pulse, fading before it expires; custom.x its age in seconds.
- Session data `Data_Hud` (`Unified.data.hud`): each slot's shots and gems, the phase, wave, station HP, score,
  rocks, the match time and the times to the next wave and to the reset.
- Constants (`Unified.constants`, metres): the sizes, the station's full HP and spin (the menu's station), and the
  station's and rocks' shapes at radius 1, the ones the sim builds its bodies from.
- Events go to the ship's view by `player`, `Event_Station_Hit` to the station (`Glue.event_key`). Rock effects play
  when an event is emitted (a prediction shows them at once), the rest, like the HUD's banners, once confirmed; a shot a
  rollback cancels loses its muzzle flash and sound (the ship view, by the event's `id`).
- Input: the movement, fire and boost from the InputMap, and the aim the arena sets on every sample (`input_wanted`, the
  input value `aim`): the mouse's world position relative to the local ship, else the right stick. A Camera2D follows
  the local ship within the arena. The HUD sends `Cmd_Start` (`CommandStart`) in the lobby and `Cmd_Restart` when the
  match is over.
