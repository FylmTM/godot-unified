# minimal_3d: the smallest 3D game on unified

1–4 players move capsules on a floor and throw balls straight up; a ball falls back and is gone when it lands. It
touches every part of the library a game uses, with as little game as possible: it is what `uni init` copies for a
new game, and the showcase of how to write one. A Godot project (this folder is `res://`): the sim, its tests, the
headless binary and the GDExtension in `simulation/` (Odin), everything Godot in `game/`. `uni run minimal_3d` plays
it.

## Controls

Arrow keys / d-pad or left stick to move, Space or Enter / pad A to throw a ball, Esc to pause or resume the game for
everyone: Godot's `ui_*` actions, so the project has no InputMap of its own.

## What it shows

- **State and players.** A pointer-free `State`: the players in a `sim.Players` (per-player data by handle) and the
  balls in a `sim.Table`.
- **Commands and events.** Two commands (`Cmd_Throw_Ball`, `Cmd_Set_Paused`) and two game events
  (`Event_Ball_Thrown`, `Event_Paused`) next to the library's join and leave events.
- **Game time and the co-op pause.** A `sim.Clock` in the State: anyone pauses the game for everyone with a command,
  `tick` returns early while paused, and the throw cooldown (a `sim.Timer` on game time) waits the pause out.
- **Views and data.** A scene view per player, a MultiMesh view for the balls, and the HUD's session data
  (`Data_Hud`, read by an ordinary scene as `Unified.data.hud`).
- **Co-op.** Players are handles, so someone who leaves and comes back gets their capsule and balls back in whatever
  slot is free.

## What a new game takes from where

A new game stays this shape: no menus or settings, one scene that starts a session. The other games show the rest;
survivor's, drift's and friendslop's menus, settings and HUD panels (`game/app/`, `game/ui/`) are their own, not a
template:

- **Playing together:** the session's flags and `uni coop`. Direct (LAN) works as is; online (EOS lobbies and P2P)
  once the game passes `eos.lobby({})` to `godot.init` and `lobbies` to `modes.run` (drift's extension, survivor's
  headless main).
- **A physics World on a level with markers:** friendslop (3D: characters, joints, sensors), drift (2D on a plane).
- **Tables, handles, a view per entity, rule tests on `headless.Run`:** drift.
- **A population, a benchmark with `bench_prepare`, keyed rolls, a tuning variant:** survivor.

## World

Metres, seconds, `TICK_HZ`. No level: an endless floor. The ground plane is the sim's x, y; the view's x, z. `State`
holds the players and up to `MAX_BALLS` balls. `PLAYERS` is the input slots; the session remembers twice as many
people (the library's 2 × `PLAYERS`). A ball keeps its thrower (`sim.Player`), who may have left.

## Input and commands

- `Input`: a stick. A player moves at up to `MOVE_SPEED` in its direction.
- `Cmd_Throw_Ball {speed}`: the sender throws a ball from their position, `HAND_HEIGHT` up, at `speed` straight up,
  at most `THROW_SPEED_MAX` (a faster throw is thrown at the cap), at most once per `THROW_COOLDOWN_S` (a throw
  sooner is dropped).
- `Cmd_Set_Paused {paused}`: pauses or resumes the game for everyone (a value, not a toggle: two players pausing at
  once agree).

## Systems (`tick`, in this order)

1. `place_new_players`: someone new starts at x = their slot; someone who comes back keeps their position (paused
   or not: people come and go during a pause).
2. `apply_pause`: each `Cmd_Set_Paused` that changes the pause sets it from the next tick (`Event_Paused`). While
   paused, `tick` stops here: the other commands of a paused tick are dropped.
3. `move_players`: the present players by their input.
4. `throw_balls`: each `Cmd_Throw_Ball` spawns a ball owned by its thrower; with `MAX_BALLS` in the air a throw is
   lost, and no event says so.
5. `move_balls`: balls fall at `GRAVITY` and despawn on landing (`BALL_RADIUS`).

## Events

- `Event_Paused {player, paused}`: who paused or resumed.
- `Event_Ball_Thrown {player, speed}`: a throw, at the speed thrown. The thrower's view gets it (its `player`), and
  so does the session's `sim_event` signal.
- `sim.Event_Player_Joined` and `sim.Event_Player_Left`: the library's join and leave events (`main.gd` prints the
  confirmed ones).

## Scripted inputs

Every slot steers one of 8 directions, drawn again every `SCRIPT_PERIOD` ticks, and throws every
`SCRIPT_THROW_EVERY` ticks, each slot at its own tick; slot 0 pauses the game for `SCRIPT_PAUSE_TICKS` of every
`SCRIPT_PAUSE_EVERY` (`script.odin`).

## View contract (`simulation/extension`)

- **`player`** (`game/views/player.tscn`): a capsule per present player, coloured by the slot the player holds (its
  data: `color`). It squashes on its player's `EventBallThrown` on EMITTED (predicted, at once).
- **`ball`**: a MultiMesh instance per ball (the `Balls` node in `main.tscn`), coloured by its thrower's slot, or
  grey once the thrower has left.
- **`Data_Hud`** (`Unified.data.hud`): the players present, the balls in the air, the local player's colour and
  whether the game is paused (the HUD shows "Paused"; `main.gd` sends `CommandSetPaused` on Esc).
  `game/hud.tscn`, a Control in the main scene, redraws on its `changed` signal.
