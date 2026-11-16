# drift: the 2D test game

Status: draft, pending #91; the concept signed off 2026-11-10.

A top-down co-op ship arena where the players defend a station. Code: `games/drift/`, laid out like
`games/survivor/`.

1–4 players fly small ships in an arena drawn in Godot's 2D editor. Rocks drift in from the edges in waves toward a
slowly turning station at the centre. The players shoot them (big rocks split, the smallest drop gems) and shove
them aside. When the station's HP reaches 0 the match is over, and everyone goes back to the lobby. drift exists to
prove `unified` for 2D games:

- 2D views: rotating, smoothed Node2D scene views, MultiMesh views with rotation, per-axis scale, color and custom
  data, physics bodies interpolated like plain state (the host remembers the poses).
- Typed scene data and commands.
- 2D physics locked to a plane (`src/physics/SPEC.md`, 2D).
- A level drawn in Godot's 2D editor (`src/level/SPEC.md`, 2D levels).
- Teleports (warp gates) against `teleport_dist`, mouse and stick aim in world units, and a Camera2D that follows the
  local ship.

Units: metres, seconds, 64 Hz (`DT = 1/64`). The plane is XY in Godot's 2D axes (x right, y down). The view is in
pixels, with `px_per_m` from the level (32).

## World (created before tick 0, in this order)

- The level (`game/levels/arena.level`): static walls and obstacles (`physics.create_static`), then markers in file
  order. The marker kinds are `spawn` (×4, one per slot), `station` (×1), `gate` (pairs: `pair` = the other
  gate), and `rock_spawn` (on the edges: `dir` = Vector2, the drift direction).
- The station: a kinematic hexagon (radius 2.5 m) at the station marker, turning at 0.25 rad/s, with 100 HP.
- Ships: dynamic circles (r 0.5 m, density 1, linear damping 0.6) locked to the plane, created when a player
  joins or comes back, at the `spawn` marker of the slot they hold.

## Input and commands

- Per tick, per slot: `move_x, move_y` (a stick, `dmath.stick`) and `aim` (a `dmath.Dir2`; none keeps the heading),
  in world space.
- `buttons: bit_set[Button]`: `Fire` (held), `Boost` (held; it fires when ready).
- Commands (`Cmd_Start`, `Cmd_Restart`, both empty): `start` (lobby → match, anyone may send it) and `restart`
  (over → lobby at once).

## Rules (each tick, in this order)

1. Players (src/sim/SPEC.md, Players): a player is a session member (a `sim.Player`), and a ship is their data
   in the State's `sim.Players` (`players`, remembering 2 × PLAYERS people). A player who joins (a
   zeroed ship) or comes back (their ship as they left it: shots, gems, cooldowns) gets a body at their slot's spawn
   marker (`spawned`). One who leaves loses the body, and keeps the rest until the session forgets them.
2. Ships: thrust force = `move × 40 N`. Turning sets the angular velocity toward the aim:
   `clamp(8 × cross(heading, aim), ±6 rad/s)`, or ±6 when the aim is behind (dot < 0). Boost: an impulse of
   `heading × 6 N·s`, with a 1.5 s cooldown.
3. Fire: every 0.125 s while held, a bullet from the nose with velocity `heading × 18 m/s + ship velocity`, which
   lives 0.875 s. Bullets are sim-only (not bodies). Each tick a ray from the bullet's position to the next
   position (`physics.ray_closest`: rocks, the station and walls) ends it on a hit; the station takes no damage
   from it. A rock hit costs it 1 HP and pushes it (an impulse of `dir × 0.6`).
4. Rocks: sizes large/medium/small (radius 1.6/1.0/0.6 m, HP 6/3/1). Each is a convex 8-gon from one of 4 fixed
   shape variants scaled to its size, locked to the plane. At 0 HP, a large or medium rock splits into 2 of the
   next size. They move apart at ±2.5 m/s perpendicular to the parent's velocity, with half the parent's spin.
   A small rock is destroyed, and every other one drops a gem.
5. Station hits (Box3D hit events): a rock that touches the station costs it 10/5/2 HP by size and is destroyed.
6. Gates: a ship whose centre comes within 0.8 m of a charged gate warps to its pair. It keeps its velocity, and
   both gates recharge for 2 s.
7. Gems: a ship within 1 m picks one up: +2 station HP (capped at 100) and +1 team score. A gem expires after 10 s.
8. Phases:
   - **lobby** (tick 0, and after a reset): no rocks.
   - **match** (after `start`): wave `k = 0, 1, ...` every 20 s spawns `3 + 2k` large rocks, spread over the
     wave, from the `rock_spawn` markers in turn. Each rock's velocity is `dir × (2 + 0.2k)`, its spin comes from the
     state RNG, and so does its variant.
   - **over** (the station's HP is 0): the station stops turning. After 5 s, or on `restart`, the world resets:
     rocks, bullets and gems are cleared, the present ships go back to their slots' spawns, the station is repaired, and the phase is
     lobby.
   - With nobody present: reset.

Events (one struct each, `Event` in `state.odin`; positions in metres, z = 0; `player` is a `sim.Player`, and a
rock event's subject is the rock's handle):

- The library's `player_joined {player, slot, returning}` and `player_left {player, slot}`.
- `spawned {position, player}` (the slot's spawn), `fired {position, player}` (the muzzle),
  `boosted {position, player}`, `warped {position, player, from_gate, to_gate}` (where the ship came out).
- `rock_hit {rock, position, player, size}` (the hit point; `player` fired the bullet), `rock_split {rock, position,
  size}` and `rock_destroyed {rock, position, size}` (the rock that is gone), `station_hit {position, damage, size}`
  (`damage`: what the rock costs the station during a match).
- `gem_picked {position, player}`, `wave {wave}` (1..), `match_started {player}` (who sent `start`),
  `match_over {seconds_survived}`.

Random numbers: the waves draw from the state's stream (`rng`), in order; nothing else is random.

## View (`simulation/extension`, `game/`)

- Scene views (`View`, each scene a Node2D with a UnifiedView marker, in the view index; a key is unique within its
  kind):
  - `ship`: Ship_View `{boost_ready, thrust}`; key: its player's key (`sim.player_key`), so the view survives a
    leave and comes back with the player in any slot; its colour and "P<n>" follow the slot they hold
    (`Game.player_slot`). When the player leaves, the ship shrinks away while the view lingers (`_sim_despawned`;
    `_sim_revived` undoes it).
  - `station`: Station_View `{hp_frac}`; key 0.
  - `gate`: Gate_View `{charge}`; key: the gate's index.
- MultiMesh views (`MultiView`: MultiMeshInstance2D, TRANSFORM_2D, a UnifiedMultiView marker each; keys are the
  handles; rotations are 2D quaternions):
  - `rock_0..3`: one polygon mesh per shape variant, scaled per size, with the body's rotation and a hit flash in
    custom data.
  - `bullet`: a quad stretched along its velocity (per-axis scale), tinted with the colour of its owner's slot
    (custom.x; -1, a pale grey, once the owner has left). A bullet is owned by its player, not the slot.
  - `gem`: a spin and a pulse that squashes and stretches.
- Session data `Data_Hud` (`Unified.data.hud`, pushed every frame): `tick`, `players` by slot (`player`: their key,
  `present`, `shots`, `gems`), `phase` (`EnumPhase`), `wave`, `station_hp`, `station_max`, `score`, `matches`,
  `rocks`, `time_s` (the match time; over: survived), `next_wave_s`, `reset_in_s`.
- Constants `Data_Constants` (`Unified.constants`, metres): `ship_radius`, `station_radius`, `gate_radius`,
  `station_hp`, `over_hold_s`, `wave_every_s`, and `rock_shapes` (per variant the 8 corners at radius 1, Vector2s:
  the rock meshes).
- Enums in GDScript: `EnumPhase` (the HUD's phase) and `EnumRockSize` (the rock events' `size`).
- Event positions arrive in pixels like the views (`Glue.event_pos`, the level's scale).
- Events go to the ship's view by `player` (the routing by subject) and `station_hit` to the station
  (`Glue.event_key`). The arena plays rock effects when an event is emitted (a prediction shows them at once), and
  everything else, like the HUD's banners, once it is confirmed. A shot a rollback cancels (a remote ship's
  predicted trigger) loses its muzzle flash and sound (the ship view, by the event's `id`).
- Camera2D follows the local ship, within the arena's limits. Aim comes from the mouse (the world position
  relative to the ship) or the right stick: the arena sets the input value `aim`, which `sample_input` reads with
  the movement, fire and boost actions.
- HUD (`game/ui/hud.gd`, reading `Unified.data.hud`): phase, wave, station HP, score, time, the next wave in, and the
  players by slot.

## Tests (`simulation/tests`)

The standard end-to-end suite with a reference run (scripted input: orbit the station, aim at the nearest rock,
fire, and `start` at tick 32). The plane invariants hold exactly for every ship and rock over a whole match. A
split inside a rollback window, a warp, and the station destroyed then reset are each covered, and so are
owners following the person: a bullet stays its player's while they are away, someone new takes their slot with a
zeroed ship, and they come back in another slot with their ship as they left it (`presence_churn` runs the same
churn on scripted play under rollback). The determinism
lint runs by layout.
