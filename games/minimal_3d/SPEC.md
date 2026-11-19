# minimal_3d: the smallest 3D game on unified

Status: signed off 2026-11-15 (#9).

1–4 players move capsules on a floor and throw balls straight up; a ball falls back and is gone when it lands. It
touches every part of the library a game uses, with as little game as possible, and is what `uni init` copies. It
shows:

- **State and players.** A pointer-free `State`: the players in a `sim.Players` (per-player data by handle) and the
  balls in a `sim.Table`.
- **Commands and events.** One command (`Cmd_Throw_Ball`) and one game event (`Event_Ball_Thrown`) next to the
  library's join and leave events.
- **Views and data.** A scene view per player, a MultiMesh view for the balls, and the HUD's session data
  (`Data_Hud`, read by an ordinary scene as `Unified.data.hud`).
- **Co-op.** Players are handles, so someone who leaves and comes back gets their capsule and balls back in whatever
  slot is free.

## What a new game takes from where

A new game stays this shape: no menus or settings, one scene that starts a session. The other games show the rest;
survivor's, drift's and friendslop's menus, settings and HUD panels (`game/app/`, `game/ui/`) are their own, not a
template:

- **Playing together:** the session's flags and `uni coop`. Direct (LAN) works as is (`--host-port`, `--join`,
  `uni coop --lan`); online (EOS lobbies and P2P: `--host-online`, `--join-code`) once the game passes
  `eos.lobby({})` to `godot.init` and `lobbies` to `modes.run` (drift's extension, survivor's headless main).
- **A physics World on a level with markers:** friendslop (3D: characters, joints, sensors), drift (2D on a plane).
- **Tables, handles, a view per entity, rule tests on `headless.Run`:** drift.
- **A population, a benchmark with `bench_prepare`, keyed rolls, a tuning variant:** survivor.

## World

Metres, seconds, 64 Hz (`DT = 1/64`). No level: an endless floor. The ground plane is the sim's x, y; the view's x, z.
`State` holds the players and up to `MAX_BALLS` (64) balls. `PLAYERS` is 4 input slots; the session remembers 8
people (the library's 2 × `PLAYERS`).

- Per player (`Player_Data`): `position`. Someone new starts at x = their slot, y = 0; someone who comes back keeps
  theirs.
- Per ball: its ground position, height, vertical speed and thrower (`sim.Player`).

## Input and commands

- `Input {dx, dy}` (i8, −127..127, `dmath.axis_i8`): a stick. A player moves at up to 4 m/s in its direction (the
  stick's length is clamped to 1, `dmath.stick`).
- `Cmd_Throw_Ball {speed}`: the sender throws a ball from their position, 1.8 m up, at `speed` m/s up, at most
  `THROW_SPEED_MAX` (8; a faster throw is thrown at 8).

## Systems (`tick`, in this order)

1. `place_new_players`: each new player at x = their slot (`t.player_changes.joined`).
2. `move_players`: the present players by their input.
3. `throw_balls`: each `Cmd_Throw_Ball` spawns a ball owned by its thrower. With 64 balls in the air a throw is lost,
   and no event is emitted.
4. `move_balls`: balls fall at 9.8 m/s²; a ball whose centre is 0.2 m or less above the ground despawns.

## Events

- `Event_Ball_Thrown {player, speed}`: a throw, at the speed thrown. The thrower's view gets it (its `player`), and
  so does the session's `sim_event` signal.
- `sim.Event_Player_Joined` and `sim.Event_Player_Left`: the library's join and leave events.

## Scripted inputs

- Every slot steers one of 8 directions, drawn again every 16 ticks.
- Every slot throws every 32 ticks (each at its own tick), at 3 to 6 m/s.

## View contract (`simulation/extension`)

- **`player`** (`game/views/player.tscn`): a capsule per present player, coloured by the slot the player holds.
  - Data: `color`.
  - It squashes on its player's `EventBallThrown` (Emitted: predicted, at once).
- **`ball`**: a MultiMesh instance per ball (the `Balls` node in `main.tscn`). It is coloured by its thrower's slot,
  or grey once the thrower has left.
- **`Data_Hud`** (`Unified.data.hud`): `players` present, `balls` in the air, and `color` (a `godot.Color`, the local
  player's). `game/hud.tscn`, a Control in the main scene, redraws on its `changed` signal.
