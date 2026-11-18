# drift

Status: draft, pending #327

A top-down co-op ship arena, unified's example of a 2D game: 1–4 players fly ships around a slowly turning station
and defend it from rocks that drift in from the edges in waves. Big rocks split, the smallest drop gems that repair
the station, and warp gates carry a ship across the arena. When the station's HP reaches 0 the match is over. Units:
metres and seconds at **64 Hz**; the plane is XY in Godot's 2D axes (x right, y down), and the view draws 32 pixels
per metre (`Glue.view_scale`; the level is baked at the same scale). Physics is Box3D locked to the plane
(`src/physics/SPEC.md`, 2D). Every rule number is a named constant in `simulation/drift/tuning.odin`; this spec names
them.

## World

The arena is a level drawn in Godot's 2D editor (`game/levels/arena.tscn`, baked to `arena.level`,
`src/level/SPEC.md`, 2D levels): static walls and obstacles, then markers: a `spawn` per slot, the `station`, `gate`s
(`pair`: the other gate) and `rock_spawn`s on the edges (`dir`: the drift direction).

- The station: a kinematic hexagon (`STATION_RADIUS`) at the station marker, with `STATION_HP`.
- Ships: dynamic circles (`SHIP_RADIUS`, `SHIP_DENSITY`, `SHIP_DAMPING`), made when a player becomes present, at
  their slot's spawn, nose up.
- Rocks: convex 8-gons, one of `ROCK_VARIANTS` shapes (`ROCK_SHAPES`) scaled by their size's radius (`ROCK_STATS`:
  radius, HP, station damage for small, medium and large), tagged with their handle's key.
- Bullets and gems are no bodies.

## Input and commands

- `Input`: `move_x, move_y` (a stick, `dmath.stick`) and `aim` (a `dmath.Dir2`; none keeps the heading), in world
  space, and `buttons`: `Fire` and `Boost`, both held.
- Players are session members: a ship is its player's data (`sim.Players`). One who leaves loses the body and keeps
  the rest (shots, gems, cooldowns) until the session forgets them; someone new starts with a zeroed ship.
- `Cmd_Start` and `Cmd_Restart`, both empty: `start` (lobby → match; anyone may send it) and `restart` (over → lobby
  at once). Each is ignored outside its phase.

## Phases

- **lobby** (tick 0, and after every reset): ships fly, no rocks.
- **match** (after `start`): waves of rocks; the match is over when the station's HP is 0 (`match_over`).
- **over**: the station stops turning and takes no hits. After `OVER_HOLD_TICKS`, or on `restart`, the world resets:
  rocks, bullets and gems go, the present ships return to their slots' spawns at rest, the gates are charged, the
  station is repaired, and the lobby begins again.
- With nobody present: a reset.

## Systems (`tick`, in this order)

1. `update_players`: a player who left loses their body; one who joined or came back gets one at their slot's spawn
   (`spawned`).
2. `apply_commands`: `start` and `restart`, in slot order.
3. `fly_ships`: the cooldowns count down. Thrust: an impulse of the stick × `THRUST_ACCEL` × mass × dt. Turning sets
   the angular velocity toward the aim: `TURN_GAIN × cross(heading, aim)` clamped to `TURN_MAX`, or `±TURN_MAX` when
   the aim is behind. Boost: `heading × BOOST_SPEED` (an impulse of that × mass), then `BOOST_COOLDOWN_TICKS`. Fire:
   every `FIRE_EVERY_TICKS` while held, a bullet from the nose with `heading × BULLET_SPEED` plus the ship's velocity
   (`fired`).
4. `turn_station`: `STATION_SPIN`, 0 while over.
5. The physics step.
6. `move_bullets`: a ray along each bullet's step (`physics.world_cast_ray_closest_2d`: the level, rocks, the
   station) ends it on a hit. A rock hit costs it 1 HP and pushes it (`BULLET_PUSH` along the bullet, `rock_hit`);
   the station takes no damage from bullets. A bullet expires after `BULLET_LIFE_TICKS`.
7. `hit_station` (not while over): a rock within the station's corner circle is gone (`station_hit`) and, during a
   match, costs the station its size's station damage.
8. `break_rocks`: a rock at 0 HP, large or medium, splits into two of the next size, `ROCK_SPLIT_GAP` radii either
   side of it across its velocity, moving apart at `ROCK_SPLIT_SPEED`, each with `ROCK_SPLIT_SPIN` of its spin, the
   second the other way and the next shape (`rock_split`). A small one is destroyed (`rock_destroyed`), and one in
   `GEM_DROP_EVERY` drops a gem at `GEM_THROW` of its velocity.
9. `warp_ships`: the gates recharge; a ship whose centre is within `GATE_RADIUS` of a charged gate comes out of its
   pair with its heading and velocity (`warped`); both gates and the ship wait `GATE_CHARGE_TICKS`.
10. `collect_gems`: gems drift and slow (`GEM_DRAG`); the first present ship in slot order within `GEM_PICK_RADIUS`
    picks one up (`gem_picked`): +1 score, `GEM_REPAIR` station HP up to `STATION_HP`. A gem expires after
    `GEM_LIFE_TICKS`.
11. `spawn_waves` (match only): wave `k = 0, 1, ...` every `WAVE_EVERY_TICKS` (`wave`) brings `WAVE_ROCKS +
    WAVE_ROCKS_MORE · k` large rocks, one every `ROCK_EVERY_TICKS`, from the `rock_spawn` markers in turn, at
    `ROCK_SPEED + ROCK_SPEED_PER_WAVE · k` along the marker's direction turned up to `ROCK_SPREAD`. The turn, the spin
    (up to `ROCK_SPIN_MAX`) and the shape are keyed rolls (`sim.roll_f32`, `sim.roll_below`).
12. `advance_phase`.

## Events

Positions are on the plane in metres (pixels in GDScript, like the views); `player` is a `sim.Player`, and a rock
event's subject is the rock's handle.

- `spawned {position, player}` (the slot's spawn), `fired {position, player}` (the muzzle), `boosted {position,
  player}`, `warped {position, player, from_gate, to_gate}` (where the ship came out).
- `rock_hit {rock, position, player, size}` (the hit point; `player` fired the bullet), `rock_split {rock, position,
  size}` and `rock_destroyed {rock, position, size}` (the rock is gone), `station_hit {position, damage, size}`
  (`damage`: what it costs during a match).
- `gem_picked {position, player}`, `wave {wave}` (1..), `match_started {player}` (who sent `start`),
  `match_over {duration_s}`, and the library's joins and leaves.

## Scripted inputs

The game's scripted player (`script.odin`) is stateless: a hash of (seed, slot, 16-tick block) moves the ship in one
of 8 directions (4 blocks in 5; else no move), aims it in one of 8, fires in 3 blocks in 4 and boosts in 1 in 6.
Slot 0 sends `start` at tick 32 and `restart` at tick 160 of every 256, so scripted runs play whole matches; a
session and an offline run agree.

## View contract (`simulation/extension`)

- Scene views (each a Node2D with a UnifiedView marker):
  - `ship`: `Ship_View {boost_ready, thrust}`, keyed by its player (`sim.player_key`), so the view survives a leave
    and comes back with the player in any slot; its colour and "P<n>" follow the slot they hold
    (`Unified.session.get_player_slot`). When the player leaves, the ship shrinks away while the view lingers (`_sim_despawned`;
    `_sim_revived` undoes it).
  - `station`: `Station_View {hp_frac}`, key 0.
  - `gate`: `Gate_View {charge}`, keyed by the gate's index.
- MultiMesh views (MultiMeshInstance2D, `TRANSFORM_2D`, keyed by handle):
  - `rock_0..3`: a polygon mesh per shape variant at radius 1, scaled per axis by the rock's radius (squashed for a
    moment when hit), custom data `{size, hit flash}`.
  - `bullet`: a quad stretched along its velocity, tinted with the colour of its owner's slot (custom.x; -1, a pale
    grey, once the owner has left).
  - `gem`: a spin and a squash-and-stretch pulse, fading before it expires; custom.x its age in seconds.
- Session data `Data_Hud` (`Unified.data.hud`): `players` by slot (`shots`, `gems`), `phase` (`EnumPhase`), `wave`,
  `station_hp`, `score`, `rocks`, `time_s` (the match time; over: survived), `next_wave_s`, `reset_in_s`.
- Constants (`Unified.constants`, metres): `ship_radius`, `station_radius`, `gate_radius`, `station_hp` (full),
  `station_spin` (the menu's station), `station_shape` (the hexagon's 6 corners at radius 1, the station view) and
  `rock_shapes` (per variant the 8 corners at radius 1, the rock meshes).
- Events go to the ship's view by `player`, `station_hit` to the station (`Glue.event_key`). Rock effects play when
  an event is emitted (a prediction shows them at once), the rest, like the HUD's banners, once confirmed; a shot a
  rollback cancels loses its muzzle flash and sound (the ship view, by the event's `id`).
- Input: the movement, fire and boost from the InputMap, and the aim the arena sets on every sample
  (`input_wanted`, the input value `aim`): the mouse's world position relative to the local ship, else the right stick. A Camera2D follows the local
  ship within the arena. The HUD sends `start` (`CommandStart`) in the lobby and `restart` when the match is over.
