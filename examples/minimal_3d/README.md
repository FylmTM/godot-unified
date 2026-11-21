# minimal_3d: the smallest 3D game on unified

1–4 players move capsules on a floor and throw balls straight up; a ball falls back and is gone when it lands. It
touches every part of the library a game uses, with as little game as possible: it is what `uni init` copies for a
new game, and the showcase of how to write one. A Godot project (this folder is `res://`): the sim, its tests, the
headless binary and the GDExtension in `simulation/` (Odin), everything Godot in `game/`. `uni run minimal_3d` plays
it. `GUIDE.md`, which every new game carries, is how to write gameplay that survives rollback: the patterns, and the
gotchas by symptom.

## Controls

Arrow keys / d-pad or left stick to move, Space or Enter / pad A to throw a ball, Esc to pause or resume the game for
everyone: Godot's `ui_*` actions, so the project has no InputMap of its own.

## What it shows

- **State and players.** A pointer-free `State`: the players in a `sim.Players` (per-player data by handle) and the
  balls in a `sim.Table`.
- **Commands and events.** Two commands (`Command_Throw_Ball`, `Command_Set_Paused`) and two game events
  (`Event_Ball_Thrown`, `Event_Paused`) next to the library's join and leave events.
- **Game time and the co-op pause.** A `sim.Clock` in the State: anyone pauses the game for everyone with a command,
  `tick` returns early while paused, and the throw cooldown (a `sim.Timer` on game time) waits the pause out.
- **Views and data.** A scene view per player, a MultiMesh view for the balls, and the HUD's session data
  (`Data_Hud`, read by an ordinary scene as `Unified.data.hud`). The window stretches its 2D (`canvas_items`,
  `expand`): the HUD is laid out at the project's size and scales with the window, as every example's UI is, while
  the 3D renders at the window's own resolution.
- **Co-op.** Players are handles, so someone who leaves and comes back gets their capsule and balls back in whatever
  slot is free.

## What a new game takes from where

A new game stays this shape: no menus or settings, one scene that starts a session. The other example games show the
rest; their menus, settings and HUD panels (`game/app/`, `game/ui/`, a copy in each) are theirs, not a template:

- **Playing together:** the session's flags and `uni coop`. Direct (LAN) works as is; online (EOS lobbies and P2P)
  once the game passes `eos.lobby({})` to `godot.init` and `lobbies` to `modes.run` (drift's extension, survivor's
  headless main). Hosting and joining from inside the game: the app layer's main menu (any other example's
  `game/ui/menu.tscn`, with `game/app/game.gd`, which owns the session).
- **A physics World on a level with markers:** friendslop (3D: characters, joints, sensors), drift (2D on a plane).
- **Level changes:** friendslop (`Game.levels`, a travel command, `physics.level_change`, the session's `level_root`).
- **Several local players on one machine:** drift (a pad joins with Start; the extension's `sample_input` reads each
  local player's device).
- **A Setup, a Profile and a save:** survivor (the difficulty and the host's record through the Setup, a role per
  player in the Profile, the record on the match-over panel).
- **Opening a running game to friends:** friendslop's pause menu (online when the build has online play, else on the
  LAN).
- **Pausing:** the co-op pause here (a `sim.Clock` and a command, as state); the single-player pause,
  `UnifiedSession.paused`, in the other games' pause menus.
- **Tables, handles, a view per entity, rule tests on `headless.Run`:** drift.
- **A benchmark row per level (`Game.benches` on a Setup each), MultiMesh views of every body by its shape, ragdolls,
  joints and cars:** playground.
- **A population, a benchmark with `bench_prepare`, keyed rolls, a tuning variant:** survivor, with dev commands,
  timing zones, debug draws, a `sim.Grid`, `sim.due` and a roll its HUD peeks.
- **How a view is shown:** friendslop (a script-posed view, `Glue.view_policy`: the held item at the hand), drift and
  friendslop (a teleported body's view snaps: `physics.body_warp`), survivor (a warp epoch of its own for a body made
  again).
- **Shown by no game** (the declaration's doc comment says how): `Appear.Verified` and `Glue.multi_policy`,
  `sim.Queue`, `sim.Bits`, dmath's trig, `Game.predict_input`, `Game.input_delay_min_ticks`.

## World

Metres, seconds, `TICK_HZ`. No level: an endless floor. The ground plane is the sim's x, y; the view's x, z. `State`
holds the players and up to `MAX_BALLS` balls. `PLAYERS` is the input slots; the session remembers twice as many
people (the library's 2 × `PLAYERS`). A ball keeps its thrower (`sim.Player`), who may have left.

## Input and commands

- `Input`: a stick. A player moves at up to `MOVE_SPEED` in its direction.
- `Command_Throw_Ball {speed}`: the sender throws a ball from their position, `HAND_HEIGHT` up, at `speed` straight up,
  at most `THROW_SPEED_MAX` (a faster throw is thrown at the cap), at most once per `THROW_COOLDOWN_S` (a throw
  sooner is dropped).
- `Command_Set_Paused {paused}`: pauses or resumes the game for everyone (a value, not a toggle: two players pausing at
  once agree).

## Systems (`tick`, in this order)

1. `place_new_players`: someone new starts at x = their slot; someone who comes back keeps their position (paused
   or not: people come and go during a pause).
2. `apply_pause`: each `Command_Set_Paused` that changes the pause sets it from the next tick (`Event_Paused`). While
   paused, `tick` stops here: the other commands of a paused tick are dropped.
3. `move_players`: the present players by their input.
4. `throw_balls`: each `Command_Throw_Ball` spawns a ball owned by its thrower; with `MAX_BALLS` in the air (two players
   throwing at once fill it) a throw is lost, costs no cooldown, and no event says so.
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
