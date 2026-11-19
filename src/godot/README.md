# `unified:godot`: the Godot host of a game built on `unified`

Everything that touches Godot for a game: the session node that runs the game's sim on its own thread (single
player, hosting or joining, through `unified:netcode`), the views that show its state, its events and commands as
GDScript classes, input sampling, the command line and the dev UI (`unified:devui`, reached only from `dev.odin`).
`unified:gdext` is the raw bindings underneath. Each game has a thin extension (`examples/<game>/simulation/extension`)
that installs its sim and its glue with `godot.init`; its scenes and scripts use the classes below. The editor's help
is the reference for every GDScript-facing class and member: each is documented where it is bound.

## A game's extension

The extension fills frames and samples input; its Godot calls go in GDScript or through `unified:godot` helpers, so it
never imports `unified:gdext` (`godot` names the entry point's types). The levels the session plays are the game's
(`sim.Game.levels`, embedded in the extension).

**Online play** goes through the `netcode.Lobby` the game passes to `godot.init`: `unified:godot` never imports a
platform SDK. The session opens the lobby with a `netcode.Lobby_Build` (the game's name, its build id
`sim.compat_of(game)`, level included, the project's stamped version, the player count), so a joiner on another
build is told before it joins.

**The editor loads the extension too**, so a game with problems is reported, never a panic that stops the load
(`install_problems` says what it checks).

### Input

`Glue.sample_input` runs on the main thread **once a frame**, and every tick that samples the local player takes the
newest sample, so one sample can feed several ticks: an `Input` is the controls' **state**, never a one-shot. The sim
derives presses from the tick before (`sim.buttons`); a one-shot value is a command. An `Input` holds no bools and
no floats: an axis is `dmath.axis_i8(x)`, a direction a `dmath.Dir2` / `Dir3`, a first-person look a `dmath.Aim`. A
game without an Input (`sim.No_Input`) has no `sample_input`: everything its players do is a command.

**Local players.** `sample_input(local, input)` runs once a frame for each local player (several people on one
machine: a couch, guests of a remote-play stream, who arrive as pads), and the action helpers read **the sampled
player's device**, so one body serves them all: `DEVICE_ANY` (every device, through Godot's Input singleton: the first
player's default, and how a game of one player plays), `DEVICE_KEYBOARD`, or a joypad's id. Godot's Input singleton
keeps no action state per device, so for a device the session follows the events of the actions the helpers asked
for (`_input`: a joypad's events for the players on that pad, the keyboard's and mouse's for the players on it; a press
latches; losing the focus releases the keyboard players' actions). Each local player is its own member of the session
(`src/netcode/README.md`, Local players): `UnifiedSession.add_local_player` joins one to the running session, its
commands name it (`send_command(command, local)`), its input values are `Unified.local_input(local)`
(`Unified.input` is local player 0's), and `Frame.local_players` (by local index, `{}` where none is in) and
`UnifiedSession.local_players` (the keys of those in, compacted; by index: `get_local_player_key(local)`) say who
they are; `local_players_changed` says when that changes, and `local_player_refused` when the session refuses one.

**Setup and Profile** (`src/sim/README.md`, Setup and Profile) are GDScript classes built from the game's types, as a
command's: a host passes a `UnifiedSetup` to `start_single`, `host_online` or `host_direct` (none: the game's default),
`session.setup` reads the running session's (a joiner's is the host's; `fill_frame` reads it as `Frame.setup`), and
`Unified.profile` is what the local player joins with. A save (`src/sim/README.md`, Saves) comes as a `UnifiedSetup`:
`session.save_changed` hands every player the newest one with the frame it shows (two saves verified between two
frames come as the second; one verified in a step that computed no new tick comes with the next frame), `to_json`
makes it the game's save file, and the static `UnifiedSetup.from_json` reads it back for the next session's start,
also on a later build (`json_problem` says why one does not read).

**Open to friends.** A running single-player session becomes a hosted one (`UnifiedSession.open_online`,
`open_direct`): the session thread opens the lobby or the socket and adds it to the running host
(`src/netcode/README.md`, Relay: open and closed), and `mode` and `join_code` change (`mode_changed`). `close_online`
lets nobody new into any hosted session, opened to friends or hosted from the start; the players in stay, and opening
again the same way shows the code again. A lobby that fails after opening closes again and the session plays on as
single player: only a session hosted from the start ends with its lobby.

**Input values** are what only scripts know (a camera rig's look direction): the plain struct `Glue.input_values`
names, whose fields scripts set on `Unified.input` (local player 0's; another's `Unified.local_input(local)`) and
`sample_input` reads (`input_values`). The session samples at
process priority −1000, before any other node's `_process`, and emits `UnifiedSession.input_wanted` just before: a
script sets its values there, whatever its node's priority, and this frame's sample takes them. Set in `_process`,
they reach the next frame's sample.

**A pause menu pauses single player**: `UnifiedSession.paused` stops the session thread's host (netcode's single-player
pause), the views hold their last pose, and the session goes on as if no time had passed. With other players it reads
false and the menu is an overlay: a game that pauses together sends a command (`src/sim/README.md`, Game time).

**Game input is off** while a dev UI text field has the keyboard and while `UnifiedSession.game_input` is false (a
pause menu): the action helpers read nothing and latched taps drop; `Unified.input` still flows. When it comes back,
and when the window gets the focus back, an action still held counts only once released (the key that closed a menu,
the click that focused the window never fire). An unfocused window still reads input: Godot releases what was held
when it lost the focus, and tool runs drive windows that never take it. A press on the dev UI never reaches the
actions (`src/devui/README.md`, How it works). The game's scripted player (`sim.Game.scripted_input`) replaces the
sample in `--scripted` runs.

### View space

The sim works in its own units and never converts; the views draw in Godot's (metres in 3D, pixels in 2D).
`Glue.is_2d` and `Glue.view_scale` say how they relate. Everything up to the hand-off is in sim units: `fill_frame`,
the event queue, the views' smoothing (whose defaults suit a sim in metres). The host maps a point once, on the main
thread, where it makes a Godot value from it: a scene view's position, a MultiMesh instance's origin (only the
origin: a mesh is drawn in view units), every `sim.Position` a script reads; and the inverse for one a script sets in
a command. Rotations, directions, lengths and input values are not mapped: a script scales a sim size with
`Unified.view_scale`. View space is `view_root`'s local space (the host warns once when `view_root` is not at the
world origin).

### Filling a frame

`fill_frame` runs on the session thread for every published tick and pushes what the main thread shows: scene views
(`push_view`, each standing for a **subject**: its identity, its key and what events reach it), MultiMesh instances
(`push_multi_view`) and session data (`push_data`). A Frame grows to what a fill pushes.

The host remembers every keyed item's pose, so a view or instance seen at tick − 1 interpolates from it and games
never pass previous poses. After a rollback the remembered pose is the old prediction, so the host sends an estimate
of the corrected one (`poses.odin`); a correction glides over the smoothing's `tau_s`, it never pops.

The host never guesses a teleport the sim can name: each thing has a **warp epoch** that moves on where it
teleports, pushed with the view (`View_Item.warp`): a body's is physics' (`physics.body_warp`, moved on by every
physics teleport), a thing that is no one body keeps a `u8` in its state and bumps it. A change snaps the view: no
interpolation and no correction crosses it. It is compared with the epoch the main thread last **showed**, not the
last fill's, because the hand-off drops frames the main thread never took. It is rollback-safe by construction: a
re-simulated teleport bumps the counter to the same value, an undone one puts the old value back and the view snaps
back. A long move with no bump still snaps past the smoothing's `teleport_dist`, the fallback.

**View policy.** How each kind is shown is one Odin literal in the Glue (`view_policy`, `multi_policy`), not
properties spread over the kinds' scenes: its smoothing (a bullet, a heavy crate and a remote player want different
ones) and, for a scene view, who poses its root. A script-posed kind's root is left alone and its script gets the
pose the host would have set (`Posed_By.Script`), so it can draw what the local player holds at render rate from the
camera. A MultiMesh kind keeps a track per instance only when its policy sets a smoothing: thousands of instances
cost nothing per instance by default.

**Appear on verified** (`Appear.Verified`): a kind whose views must never show a mispredicted spawn. The session
thread knows since which tick each key is in the current timeline: the first fill that showed it, reset when a
rollback re-simulates that tick, and confirmed by a fill of the newest verified tick (netcode's `verified_state`)
that has it. Without that verified fill a key would never appear under steady mispredictions, since every predicted
fill gets re-simulated before it is verified; it costs one more `fill_frame` per step that re-stepped verified ticks,
only while some kind asks for it. The main thread creates the view once the newest verified tick reaches that tick;
such a view is never cancelled.

### Data and classes

**Session data** (values that belong to no entity: a HUD's score, the wave) are the `Data_*` structs of `Glue.data`,
one value of each per tick. **Constants** (what `godot.init`'s `constants` proc returns, strings allowed) are copied
once at install. **Input values** are set by scripts. Session data is set from the newest predicted tick when its
bytes change (no interpolation), after the views and before the frame's events, and goes back to zero (one
`changed`) when a session ends; the objects live on, so connections survive. They are freed at Godot's shutdown
callback, while scripting still runs.

**Session data and input values are plain**, as the State is: no pointers and **no implicit padding** (a gap, even
the tail after a `bool`, is an explicit `_pad: [n]u8` field), because the host compares their bytes. `install`
refuses a type that isn't, naming the `_pad` to add; `godot.install_problems` reports the same without Godot, and a
game's own `the_extension_installs` test (the template's) calls it, so `uni test` catches it.

The host registers a class per such type at load, plus one per **nested struct** any of them or the event and command
unions hold (`Hud_Player` -> `DataHudPlayer`, a RefCounted value: each read is a new one, its fields settable, so a
command can take it), and a class per enum they use. The engine singleton `Unified` holds the data, the constants,
the input values and the session. Godot classes have no namespaces, so prefixes group them (`Data`, `Event`,
`Command`, `Enum`); a name that clashes with an existing class is an error and is not registered.

Every sim-facing field (events, commands, view and session data, constants, input values) converts by type, the same
everywhere:

- integers an `int`, f32 a `float`, bools a `bool`; an enum an `int` (its class names the members: `survivor.Phase`
  is `EnumPhase.LOBBY`, `EnumPhase.name(value)`); a bit_set an `Array[int]`;
- a handle and a `sim.Player` their key (an `int`, 0: none); a `sim.Entity` its index (an `int`, −1: none), the
  number its views are keyed by;
- a `sim.Position` a `Vector2` (`Glue.is_2d`) or `Vector3`, in view units; by shape, `[2]/[3]/[4]f32` a
  `Vector2/3/4` and `[2]/[3]/[4]i32` a `Vector2i/3i/4i`; `godot.Color` a `Color`, `godot.Quat` a `Quaternion`;
- other arrays and enumerated arrays a typed `Array` (an array of arrays untyped); a nested struct an object of its
  class (a struct only view data uses has no class: a `Dictionary`); a string (constants) a `String`.

`_` fields are left out. Godot's own math types are refused at install: data maps by shape, so a game never imports
`unified:gdext`.

**Events and commands** are classes too: one per kind of the event union (`extends UnifiedEvent`) and of the command
union (`extends UnifiedCommand`), named `Event` / `Command` + the type in PascalCase without its prefix
(`Event_Rock_Hit` -> `EventRockHit`, `Cmd_Drop` -> `CommandDrop`), with a typed property per field. The library's
`sim.Event_Player_Joined` / `Event_Player_Left` are `EventPlayerJoined` and `EventPlayerLeft`. Handlers dispatch by
class, never by `kind`. A script makes a command with its class and sends it with `UnifiedSession.send_command`; the
sim gets it exactly once.

## Godot side

**`UnifiedSession`** is one node per app. **Whoever starts a session, the game follows it**: a session starts from a
script (`start_single`, `host_online`, ...), from the session flags on the command line when the node enters the
tree, or from a tool script. A game's app layer reacts to `status_changed` and `mode`, not to its own buttons, so
`uni coop` and the flags work in every game. Nothing about the session answers once it is over. A client's LAN token
is kept under `user://`, one per running copy of the game (`token_claim`), so a restarted copy takes its token back.

The game's `View` and `MultiView` enums and the State's level enum are the classes `EnumView`, `EnumMultiView` and
`EnumLevel`, whatever the game named them; every enum class has `name(value)` and `names()` (a menu's options, in
value order).
A scene view's scene holds a **`UnifiedView`** marker as a direct child of its root, its kind set in the scene by the
member's lowercased name (which stays right when the enum is reordered); the root's class decides how it is posed. A
MultiMeshInstance3D / 2D holding a **`UnifiedMultiView`** marker shows one MultiView kind. Views and their data are
set before any other node's `_process` (the session runs at priority −1000), so a view's own `_process` sees the
frame's pose. A `view_root` that leaves the tree holds no views, so a play scene needs no teardown. Unset, it is
the session's parent: right for a session placed in the play scene (the template's); a session an autoload owns sets
`view_root = null` (no scene views) until its play scene hands over its root.

## Levels

The active level is state (`src/sim/README.md`, Levels), so the host reads it rather than being told: `install`
finds the State's `level` field (a `sim.Active_Level`, named so: `src/sim/README.md`, Levels), and each Frame
carries the level of its tick and of the newest verified tick. The level on screen (`UnifiedSession.level`) follows
the **verified** one, so a mispredicted change never shows and a rollback across a change costs the view nothing:

- **The scene.** With `level_root` set, the host loads the verified level's scene on a thread (the `res://` path its
  `.level` file names, so no index or naming convention is needed), emitting `level_changing`; once it is loaded it
  frees the old level's instance and every scene view, instances the new one under `level_root` and emits
  `level_changed`. Without `level_root` the game shows its level itself (a single-level game's play scene instances
  it), and `level` and the signals still follow the verified level.
- **The views hold.** Views sync only from frames of the level on screen: while a change is predicted but not
  verified, or the new scene still loads, the views keep their last pose and session data and events flow on. A
  view keyed by a level's marker (`sim.Entity`) is never shown against another level's scene: a marker index names
  a marker of the level active at its tick, and every scene view is dropped at the swap.
- **The sim keeps ticking** through a load. A game that wants players to wait for everyone's scene keeps that as
  state (a ready command and a timeout); the host has no barrier.

## Events

`install` reads the game's event union by RTTI once: each kind's player (its first `sim.Player` field) and subject
(its first `sim.Handle(T)` or `sim.Entity` field), found by type, whatever the fields are named.

- **States.** Every event is **Emitted** exactly once, the first time any simulation of its tick produces it, then
  exactly once either **Confirmed** (its tick is verified) or **Cancelled** (a re-simulation no longer produces it).
  One first produced at verification is Emitted and Confirmed in the same frame. Effects go on EMITTED, what must be
  final on CONFIRMED, undoing an effect on CANCELLED. Two events are the same across re-simulations when tick, kind,
  subject and index among the tick's events of that kind and subject match.
- **Identity.** Each state arrives as a new object; its `id` is the same in an event's EMITTED and its CONFIRMED or
  CANCELLED, and never repeats in the process. A re-simulation may change an event's fields but not its id. Events
  still pending when a session ends get no final state.
- **Where.** Each event, in each state, goes first to its subject's views: those pushed with a subject of its subject
  field's type and the same key (a `Handle(T)` reaches only views pushed with a `Handle(T)` of that table; an
  `Entity` the views pushed with that `Entity`, of any kind: the kinds that take Entity events share one index space,
  a level's marker index); else (no such view, or no such field) its player's views; then to the `sim_event`
  signal. `Glue.event_key` reroutes a game's special events.
- **When.** An event is delivered once the Frame of its tick is shown, so an event about a view spawned at its tick
  finds the view. A tick's events arrive in emission order; cancels and confirmations of several ticks in tick order.

## Replays

A replay is a session kind (`UnifiedSession.replay(folder)`, `--replay`), so a game follows it like any other: the
game's own views, HUD and dev UI show a recording, an F3 note or a freeze folder, with pause, step, speed, seek and
loop. It feeds the sim from the recording instead of the network: no input, no commands, every tick final, so events
arrive Emitted and Confirmed together, and the recording's checkpoints are checked as it passes them (a recording of
another build plays and says where it first computes differently). `local_player` is the player it follows,
whoever recorded it at first, so a camera that tracks the local player's view follows them. It shows the verified
timeline: what a client predicted is not in a recording.

Every live session of a dev UI build is written to `<user data>/recordings/<local time>/` when it ends (the newest
`RECORDINGS_KEPT` kept). A step back inside the sim's ring is a restore; further back, or forward past what was
played, the replay loads the nearest portable snapshot it kept of a tick it passed and steps to the target without
showing the ticks between. Such a jump starts a new epoch in the Frame: every view snaps, and the events of ticks
entered again going forward arrive again. A note starts some seconds before its tick and pauses on it.

The dev UI's Timeline panel drives a replay, and the Inspector's `changes` root is the op log: what the shown tick
changed in the State against the tick before, a line per leaf field (`sim.state_changes`), computed on the main
thread from the two states the session thread copies while the Inspector shows (live, after a rollback, the
corrected tick before).

## The control socket

An agent plays and checks a running game the way a person does, from outside the process: `uni drive` starts the
game with `--control <file>`, and the game (`control.odin`) listens on 127.0.0.1 at a port the OS picks, written to
that file, so several games, and several copies of one game, run side by side. Each connection carries one request
and its reply, a JSON line each; `uni drive -h` lists the verbs.

- **Only where asked.** The socket exists in dev UI builds only (a `--no-devui` build has none) and opens only with
  the flag. It listens on loopback with no authentication: anything on the machine may drive a game that was started
  for it, which is the point.
- **A driven session is a session.** Nothing here writes state. Input goes through Godot's Input singleton, which the
  game's `sample_input` reads as it reads a player's keys, and a command goes through the session's queue as a
  script's `send_command`, so a driven session is recorded, replays, and plays online like any other. An input still
  reaches the sim after the session's input delay.
- **Exact steps.** A paused single-player session steps exactly the ticks asked (netcode's `host_advance`), each
  sampling the input held then. A press held for some ticks while paused asks for its steps one frame later, once
  the main thread's sample holds the press. A running session moves on its own clock between requests: ticks there
  are counted on the shown Frame.
- **The main thread.** The socket is polled at the end of the session's `_process`, after this frame's views and
  events, so a reply sees what the frame shows; a request that waits (a pause, a step, a timed press, a wait, a
  screenshot of the next drawn frame, a click's three frames of mouse events) keeps its connection until it is
  answered or times out. While the socket is open the session thread copies the newest state for every Frame (as
  for the Inspector), so a state query never waits for one.
- **What it reads.** State, session data and constants as JSON by RTTI (`sim.value_json`: a table by its live items,
  a player by its key, sim units); the event states the session delivered, kept in a ring with a serial per state;
  the visible controls with a text or a press, the dev UI's left out; a GDScript expression (Godot's `Expression`) on
  the current scene for anything else.

## The view index

`uni bake <game>` scans the game's scenes for `UnifiedView` markers and writes `res://unified_index.tres` (each kind
name to its scene's path), committed next to the game; every build of the game's library refreshes it, and the godot
suite's `bake` step fails when the committed one is stale. Games keep their scenes wherever they like (a level scene
outside `game/levels/` by its committed `.level`: `src/level/README.md`, Baking). At the first session the host checks
that every `View` member has a scene and every indexed kind is a member.

## How it works

- **Threads.** A session (single player is a host with no remote links) runs netcode's `host_step` / `client_step`
  on its own thread (macOS: the real-time time-constraint class; Windows: two above normal priority; Linux: as it
  is; while a session runs the process opts out of background throttling: the platform files). The netcode hooks run
  there: `sample` takes the main thread's newest Input; `frame` feeds the re-simulated and new ticks' events to the
  tracker, calls `fill_frame` and publishes the Frame; `verified` confirms or cancels events. Godot is only called
  from the main thread. The thread counts how late each of its sleeps wakes (`wake.odin`; `take_sync_stats`), and
  `uni bench`'s wake row measures the same sleeps on the session thread's class with every core idle and busy: what a
  platform's thread class is chosen from.
- **The hand-off.** Lock-free where it is hot: a triple buffer of Frames (newest wins); an SPSC event queue (full:
  the event is dropped, never blocking the sim, counted and warned once); a small queue of its own for what must
  never be lost (statuses, the join code, desync reports, the result); a command queue; the input sample under a
  short mutex.
- **Main thread.** `UnifiedSession._process` runs before every other node: `input_wanted`, `sample_input`, take the
  newest Frame, spawn and pose the scene views (ticks P − 1 and P pushed into each view's track, sampled at
  alpha = (now − P's due time) / tick), write each MultiMesh's buffer and bounds in one `set_buffer`, set the session
  data, route the events of the ticks the Frame shows, then statuses, then the dev UI. The screen runs one tick
  behind the newest prediction and never extrapolates: an input reaches the screen after the next tick sample, the
  input delay, and one tick of interpolation.
- **View logic** (`handoff.odin`, `track.odin`, `view_set.odin`, `event_tracker.odin`, `poses.odin`: no Godot calls,
  tested without Godot). A rollback that re-publishes a tick with a different pose puts the difference into an error
  offset that decays (`Smoothing`). A key missing from a frame lingers (an exit animation, or a rollback that brings
  it back: it is revived, not respawned). Re-simulations of ticks at or below the verified one are ignored, since
  they are final.
- **Data.** A view's data is set after the view entered the tree (setters may use `@onready` nodes), then only for
  fields whose bytes changed; a root without a property for a field is an error (once per kind and field).
- **Remote links** go through a live netsim (`netcode.netsim_live`) the dev UI's Conditions panel impairs.
- **The dev UI** (`dev.odin`, the only file that reaches `unified:devui`) graphs the frame, the sim and the net, and
  feeds its panels. Dev UI builds also record the session as it is verified (a portable snapshot of the first saved
  verified tick, then every verified tick's inputs, and this machine's checksum of each checksum tick), so an F3
  note carries what `uni headless <game> -- replay` replays and checks, naming the first tick it computes
  differently.
- **Other players on the verified timeline** (dev UI builds, `verified_players.odin`; off unless switched on in the
  Conditions panel or by `--verified-players`): remote players posed from final ticks only, a few ticks late, to
  compare with the prediction.
- **Debug draws and zones** (dev UI builds; `src/sim/README.md`, Debug draws and zones). The session's sim gets a
  Dev timed on the netcode's clock. The groups shown (the dev UI's draw toggles, `UnifiedSession.debug_draw`,
  `--draw`) go to the session thread as one mask, applied to the sim before each step, so only shown groups are kept;
  the frame hook copies the shown tick's draws and the zones' totals into the Frame. The main thread draws them in
  view space under `view_root` on every fresh frame (`debug_draw.odin`: 3D, one line mesh over everything and
  billboard texts; 2D, a canvas item on top), so `uni tool --shots` captures them, and the zones are the `sim`
  group's stacked graph. They show the tick the views interpolate toward, as predicted.
- **The watchdog** (dev UI builds, `watchdog.odin`). A thread beside the session's watches its step counter by its
  own polls, never the wall clock, so a suspended laptop or a debugger's pause is not a freeze. A step stuck for
  `watchdog_polls` polls writes `<user data>/feedback/freeze-<time>/`: where it froze (the tick, `fill_frame` or the
  tick, the zone stack), the recording plus the inputs the client stepped after the last verified tick, so the
  folder replays headless into the frozen tick, which a deterministic sim reproduces under a debugger (on Windows a
  minidump too); then the process aborts.
- **Leave, then host or join.** `leave` asks the session to end; it says goodbye on its thread, for at most
  `GOODBYE_US` (a host waiting for peers that don't answer). A start during the goodbye waits and starts as soon as
  the old session is gone (the goodbye cut to `HURRY_US`); a `leave` before that cancels it.
- **Quitting** (`quit.odin`). Godot reports a sound's playback still held by the AudioServer at exit as a leak, so the
  session's quits (`UnifiedSession.quit`, and the one at the end of a `--quit-at-end` run) stop every audio player in
  the tree and quit once their playbacks are freed (at most `QUIT_AUDIO_WAIT`); meanwhile the session's frame does
  nothing else. An app stops its own sound sources first (the games' `Sfx.close`), or a sound started meanwhile is
  stopped too.
- **Editor.** Classes register at SCENE level and nothing runs in the editor; the class reference loads at EDITOR
  level. `deinitialize` stops the session thread, calls the lobby's optional `shutdown`, then `gd.shutdown`
  unregisters every class.
- **Command-line flags** (after `--`; `parse_command_line`): the game and its tool scripts read their own flags from
  the same command line, so other flags pass through; a bad value of one of ours, or a near miss of a name, prints an
  error and quits (exit 2). A build without the dev UI ignores the dev flags with a warning; the session flags
  (starting, hosting and joining, `--ticks`, `--quit-at-end`) work in every build, so `uni release` smoke-tests the
  public build with them.

## Library tooling

`uni` mirrors `src/godot/tools/` into every game as `res://addons/unified/` (git-ignored there). None of it knows a
game's menus: a game drives its own UI from its own tool scripts (`game/tools/`), which extend these.

- `level_export.gd`: `uni bake`'s level exporter.
- `tool.gd` (`UnifiedTool`): the base of every script `uni tool` runs, with its helpers `log_capture.gd` and
  `frame_log.gd`.
- `validate.gd` (`UnifiedValidate`): the godot suite's `validate` step; a game adds `_check_contract()` in
  `game/tools/validate.gd`.
- `coop.gd` (`UnifiedCoop`): `uni coop`'s host and joiner; a game adds its play in `game/tools/coop.gd`.
