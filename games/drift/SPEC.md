# drift: the 2D test game

The concept was signed off by the developer on 2026-11-10: a top-down co-op ship arena where the players defend a
station. The details below were decided autonomously and are pending review. Code: `games/drift/`, laid out like
`games/survivor/`.

1–4 players fly small ships in an arena drawn in Godot's 2D editor. Rocks drift in from the edges in waves toward a
slowly turning station at the centre. The players shoot them (big rocks split, the smallest drop gems) and shove
them aside. When the station's HP reaches 0 the match is over, and everyone goes back to the lobby. drift exists to
prove `unified` for 2D games:

- 2D views: rotating, smoothed `SimView2D`s, `SimBulkView2D`s with rotation, per-axis scale, color and custom data.
- Typed scene data and commands.
- 2D physics locked to a plane (`src/physics/SPEC.md`, 2D).
- A level drawn in Godot's 2D editor (`src/level/SPEC.md`, 2D levels).
- Teleports (warp gates) against `teleport_dist`, mouse and stick aim in world units, and a Camera2D that follows the
  local ship.

Units: metres, seconds, 64 Hz (`DT = 1/64`). The plane is XY in Godot's 2D axes (x right, y down). The view is in
pixels, with `px_per_m` from the level (32).

## World (created before tick 0, in this order)

- The level (`game/levels/arena.level`): static walls and obstacles (`physics.create_static`), then markers in file
  order. The marker kinds are `spawn` (×4, one per slot), `station` (×1), `gate` (pairs: `pair` = the other gate),
  and `rock_spawn` (on the edges: `dir` = Vector2, the drift direction).
- The station: a kinematic hexagon (radius 2.5 m) at the station marker, turning at 0.25 rad/s, with 100 HP.
- Ships: dynamic circles (r 0.5 m, density 1, linear damping 0.6) locked to the plane, created when a slot
  becomes present, at its `spawn` marker.

## Input and commands

- Per tick: `move_x, move_y` and `aim_x, aim_y`: i8 −127..127 in world space. Aim is a direction; zero keeps
  the heading.
- `buttons`: bit 0 = fire (held), bit 1 = boost (held; it fires when ready).
- Commands: `start` (lobby → match, anyone may send it) and `restart` (over → lobby at once).

## Rules (each tick, in this order)

1. Presence: a slot that becomes present gets its ship at its spawn marker. One that stops being present loses it.
2. Ships: thrust force = `move × 40 N`. Turning sets the angular velocity toward the aim:
   `clamp(8 × cross(heading, aim), ±6 rad/s)`, or ±6 when the aim is behind (dot < 0). Boost: an impulse of
   `heading × 6 N·s`, with a 1.5 s cooldown.
3. Fire: every 0.125 s while held, a bullet from the nose with velocity `heading × 18 m/s + ship velocity`, which
   lives 0.875 s. Bullets are sim-only (not bodies). Each tick a ray from the bullet's position to the next
   position (`physics.ray_closest`, rocks and walls) ends it on a hit. A rock hit costs it 1 HP and pushes it
   (an impulse of `dir × 0.6`).
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
     rocks, bullets and gems are cleared, ships go back to their spawns, the station is repaired, and the phase is
     lobby.
   - With nobody present: reset.

Events: `joined`, `left`, `fired`, `boosted`, `warped`, `rock_hit`, `rock_split`, `rock_destroyed`, `station_hit`,
`gem_picked`, `wave`, `match_started`, `match_over` (value = seconds survived).

## View (`simulation/extension`, `game/`)

- Scene views:
  - `ship`: SimView2D, Ship_View `{boost_ready, thrust}`.
  - `station`: a plain Node2D, Station_View `{hp_frac}`.
  - `gate`: SimView2D, Gate_View `{charge}`.
- Bulk views (MultiMeshInstance2D, TRANSFORM_2D):
  - `rock_0..3`: one polygon mesh per shape variant, scaled per size, with rotation and a hit flash in custom data.
  - `bullet`: a quad stretched along its velocity (per-axis scale), tinted with the owner's color.
  - `gem`: a pulse that squashes and stretches.
- Event positions arrive in pixels like the views (`Glue.event_pos`, the level's scale).
- Camera2D follows the local ship, within the arena's limits. Aim comes from the mouse (the world position
  relative to the ship) or the right stick.
- HUD: phase, wave, station HP, score, time, the next wave in, and the players.

## Tests (`simulation/tests`)

The standard end-to-end suite with a reference run (scripted input: orbit the station, aim at the nearest rock,
fire, and `start` at tick 32). The plane invariants hold exactly for every ship and rock over a whole match. A
split inside a rollback window, a warp, and the station destroyed then reset are each covered. The determinism
lint runs by layout.
