# minimal_3d: the smallest 3D game on unified

The developer built it by hand in the #9 sitting (2026-11-15), as the showcase of how to write a game with `unified`
and the base of the `uni init` template. It touches every part of the library a game uses, with as little game as
possible. Code: `games/minimal_3d/`.

1–4 players move capsules on a floor and throw balls straight up; a ball falls back and is gone when it lands. What
it shows:

- **State and players.** A pointer-free `State`: the players in a `sim.Players` (per-player data by handle) and the
  balls in a `sim.Table`.
- **Commands and events.** One command (`Cmd_Ball_Drop`) and one game event (`Event_Ball_Dropped`) next to the
  library's join and leave events.
- **Views and data.** A scene view per player, a MultiMesh view for the balls, and the HUD's session data
  (`Data_Hud`, read by an ordinary scene as `Unified.data.hud`).
- **Co-op.** Players are handles, so someone who leaves and comes back (LAN or EOS) gets their capsule and balls
  back in whatever slot is free.

Units: metres, seconds, 64 Hz (`DT = 1/64`). The ground plane is the sim's x, y; the view's x, z.

## Players

- `PLAYERS` 4 input slots; the session remembers 8 people (the library's 2 × `PLAYERS`).
- Per player (`Player_Data`): `position`. Someone new starts at x = their slot, y = 0; someone who comes back keeps
  theirs.
- Input per tick: `dx`, `dy` (i8, −127..127); a player moves at up to 4 m/s on each axis.

## Commands and events

- `Cmd_Ball_Drop {speed}`: the sender throws a ball from their position, 1.8 m up, at `speed` m/s up.
- `Event_Ball_Dropped {player, speed}`: a throw. The thrower's view gets it (its `player`), and so does the
  session's `sim_event` signal.
- `sim.Event_Player_Joined` and `sim.Event_Player_Left`: the library's join and leave events.

## Rules (each tick, in this order)

1. Joins: place each new player (`t.player_changes.joined`).
2. Move the present players by their input.
3. Apply the commands: each `Cmd_Ball_Drop` spawns a ball owned by its thrower (`sim.Player`). With 64 balls in the
   air a throw is lost, and no event is emitted.
4. Balls fall at 9.8 m/s²; a ball whose centre is 0.2 m or less above the ground despawns.

## Views (`simulation/extension/frame.odin`)

- **`player`** (`game/views/player.tscn`): a capsule per present player, keyed by `sim.player_key`, coloured by the
  slot the player holds.
  - Data: `color`.
  - It squashes on its player's `EventBallDropped` (Emitted: predicted, at once).
- **`ball`**: a MultiMesh instance per ball (the `Balls` node in `main.tscn`). It is coloured by its thrower's slot,
  or grey once the thrower has left.

## Session data

- **`Data_Hud`** (`Unified.data.hud`): `players` present, `balls` in the air, and `color` (a `gd.Color`, the local
  player's). `game/hud.tscn`, a Control in the main scene, redraws on its `changed` signal.

## Scripted runs (headless, tests)

- Every slot steers a random direction that changes every 16 ticks.
- Every slot throws every 32 ticks, at 3 to 6 m/s.
- Tests (`simulation/tests/`):
  - rollback on every tick re-simulates the same;
  - players leave, a newcomer takes the slot and the first comes back elsewhere (`presence_churn`);
  - the same seed gives the same run;
  - the determinism lint.
